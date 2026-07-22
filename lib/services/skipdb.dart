import 'dart:convert';

import 'package:http/http.dart' as http;

import 'db.dart';
import 'trakt.dart';

/// Community intro timestamps (SkipDB open-data dump), loaded once per
/// session and answered from memory. No entry -> no button; graceful by
/// nature.
class SkipDb {
  static Map<String, List<Map>>? _byKey; // 'tt|season|episode' -> segments
  static bool _loading = false;

  static Future<void> _ensure() async {
    if (_byKey != null || _loading) return;
    _loading = true;
    try {
      final res = await http
          .get(Uri.parse(
              'https://github.com/SkipDB-TV/skipdb/releases/latest/download/skipdb-dump.json'))
          .timeout(const Duration(seconds: 40));
      if (res.statusCode < 300) {
        final data = jsonDecode(res.body);
        final segs =
            (data is Map ? data['segments'] : data) as List? ?? const [];
        final out = <String, List<Map>>{};
        for (final s in segs) {
          if (s is! Map) continue;
          if ('${s['status']}' == 'rejected') continue;
          final k = '${s['imdb_id']}|${s['season']}|${s['episode']}';
          (out[k] ??= []).add(s);
        }
        _byKey = out;
      }
    } catch (_) {}
    _loading = false;
  }

  static Future<(int, int)?> intro(
          String type, String itemId, String videoId) async =>
      await _segment(const {'intro'}, type, itemId, videoId) ??
      await _aniskip('op', videoId);

  /// Outro/credits start-end - lets Up Next fire exactly when the
  /// episode is really over, not at a guessed percentage.
  static Future<(int, int)?> outro(
          String type, String itemId, String videoId) async =>
      await _segment(
              const {'outro', 'credits', 'ending'}, type, itemId, videoId) ??
      await _aniskip('ed', videoId);

  // ---------- Aniskip: the anime crowd database (OP/ED, MAL-keyed) ----
  static final _malCache = <String, String?>{};

  /// kitsu series id -> MAL id, via Kitsu's own mapping API (cached).
  static Future<String?> _malFor(String kitsuId) async {
    if (_malCache.containsKey(kitsuId)) return _malCache[kitsuId];
    String? mal = Db.setting('mal|$kitsuId');
    if (mal == null) {
      try {
        final res = await http
            .get(Uri.parse(
                'https://kitsu.io/api/edge/anime/$kitsuId/mappings'))
            .timeout(const Duration(seconds: 10));
        if (res.statusCode < 300) {
          for (final m in (jsonDecode(res.body)['data'] as List? ?? [])) {
            if ('${m['attributes']?['externalSite']}' ==
                'myanimelist/anime') {
              mal = '${m['attributes']?['externalId']}';
              break;
            }
          }
        }
      } catch (_) {}
      if (mal != null) await Db.setSetting('mal|$kitsuId', mal);
    }
    _malCache[kitsuId] = mal;
    return mal;
  }

  /// Aniskip op/ed window for a kitsu-keyed episode. Both Kitsu and
  /// Aniskip number per-entry, so no season translation is needed.
  static Future<(int, int)?> _aniskip(String kind, String videoId) async {
    final p = videoId.split(':');
    if (p.length < 3 || p.first != 'kitsu') return null;
    final mal = await _malFor(p[1]);
    final ep = int.tryParse(p[2]);
    if (mal == null || ep == null) return null;
    try {
      final res = await http
          .get(Uri.parse('https://api.aniskip.com/v2/skip-times/$mal/$ep'
              '?types[]=$kind&episodeLength=0'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode >= 300) return null;
      final data = jsonDecode(res.body);
      for (final r in (data['results'] as List? ?? [])) {
        if ('${r['skipType']}' == kind) {
          final iv = r['interval'] as Map? ?? const {};
          final a = (((iv['startTime'] ?? 0) as num) * 1000).toInt();
          final b = (((iv['endTime'] ?? 0) as num) * 1000).toInt();
          if (b > a) return (a, b);
        }
      }
    } catch (_) {}
    return null;
  }

  /// (startMs, endMs) of the requested segment kind, or null.
  static Future<(int, int)?> _segment(Set<String> kinds, String type,
      String itemId, String videoId) async {
    if (type != 'series') return null;
    try {
      final r = await Trakt.resolveVideo(type, itemId, videoId);
      if (r == null || r.$2 == null || r.$3 == null) return null;
      final t = await Trakt.toTraktNumbering(
          r.$1, type, itemId, r.$2!, r.$3!);
      final imdb = r.$1;
      final se = t.$1, ep = t.$2;
      await _ensure();
      final list = _byKey?['$imdb|$se|$ep']
          ?.where((x) => kinds.contains('${x['segment_type']}'))
          .toList();
      if (list == null || list.isEmpty) return null;
      list.sort((a, b) =>
          ((b['score'] ?? 0) as num).compareTo((a['score'] ?? 0) as num));
      final s = list.first;
      final a = ((s['start_ms'] ?? 0) as num).toInt();
      final b = ((s['end_ms'] ?? 0) as num).toInt();
      return b > a ? (a, b) : null;
    } catch (_) {
      return null;
    }
  }
}
