import 'dart:convert';

import 'package:http/http.dart' as http;

import 'animeidx.dart';
import 'db.dart';

/// Skip-segment lookups. Each database is asked in its OWN identity, so
/// there is no mapping table and no season translation anywhere:
///
///   anime  (kitsu: / mal: ids) -> Aniskip,  per-cour episode numbering
///   the rest (tt ids)          -> IntroDB,  imdb_id + season + episode
///
/// Anything else simply has no source, and no button appears.
class Skips {
  /// Last lookup identity - shown by the player's diagnostic line.
  static String lastLookup = '';

  static Future<(int, int)?> intro(
      String type, String itemId, String videoId) async {
    if (type != 'series') return null;
    final p = videoId.split(':');
    if (p.length >= 3 && (p[0] == 'kitsu' || p[0] == 'mal')) {
      return _aniskip('op', p);
    }
    if (p.length < 3 || !p[0].startsWith('tt')) {
      lastLookup = 'no source for $videoId';
      return null;
    }
    // Anime first: if the mapping knows this title, Aniskip is far
    // richer than IntroDB. Otherwise it's ordinary TV -> IntroDB.
    final mal = await _malForImdb(type, itemId, p[0], p[1]);
    if (mal != null) {
      return _aniskip('op', [
        'mal',
        mal,
        p[2],
      ]);
    }
    final segs = await _segments(p[0], p[1], p[2]);
    if (segs['intro'] != null) {
      lastLookup = 'introdb seg ${p[0]} s${p[1]} e${p[2]}';
      return segs['intro'];
    }
    return _introdb(p); // legacy intro-only route
  }

  /// Credits/ending window - lets Up Next fire when the episode really
  /// ends. Anime only for now: IntroDB serves intros through its public
  /// endpoint; its segment endpoints aren't wired here.
  static Future<(int, int)?> outro(
      String type, String itemId, String videoId) async {
    if (type != 'series') return null;
    final p = videoId.split(':');
    if (p.length >= 3 && (p[0] == 'kitsu' || p[0] == 'mal')) {
      return _aniskip('ed', p);
    }
    if (p.length < 3 || !p[0].startsWith('tt')) return null;
    final mal = await _malForImdb(type, itemId, p[0], p[1]);
    if (mal != null) return _aniskip('ed', ['mal', mal, p[2]]);
    return (await _segments(p[0], p[1], p[2]))['outro'];
  }

  /// Two tiers, cheapest first:
  ///  1. a MAL id captured during the AniList pull (single-cour shows -
  ///     covers brand-new seasonal anime the moment you add it there);
  ///  2. the anime mapping index, which is season-aware.
  static Future<String?> _malForImdb(
      String type, String itemId, String imdb, String seasonStr) async {
    final season = int.tryParse(seasonStr) ?? 0;
    final own = Db.item(type, itemId)?['mal'];
    if (own != null && season == 1) {
      lastLookup = 'anilist mal $own';
      return '$own';
    }
    return AnimeIndex.malFor(imdb, season);
  }

  // ---------------- IntroDB (everything that isn't anime) ----------------

  /// One /segments call per episode, reused for intro and outro.
  static final _segCache = <String, Map<String, (int, int)>>{};

  static int? _ms(Object? v) => v is num ? v.toInt() : null;

  static int? _sec(Object? v) {
    if (v is num) return (v * 1000).round();
    if (v is String) {
      if (v.contains(':')) {
        var total = 0;
        for (final part in v.split(':')) {
          total = total * 60 + (int.tryParse(part.trim()) ?? 0);
        }
        return total * 1000;
      }
      final d = double.tryParse(v);
      return d == null ? null : (d * 1000).round();
    }
    return null;
  }

  static Future<Map<String, (int, int)>> _segments(
      String imdb, String se, String ep) async {
    final key = '$imdb|$se|$ep';
    final cached = _segCache[key];
    if (cached != null) return cached;
    final out = <String, (int, int)>{};
    try {
      final res = await http
          .get(Uri.parse('https://api.introdb.app/segments'
              '?imdb_id=$imdb&season=$se&episode=$ep'))
          .timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        final list = body is List
            ? body
            : (body is Map
                ? (body['segments'] ?? body['results'] ?? body['data'])
                : null);
        if (list is List) {
          for (final e in list) {
            if (e is! Map) continue;
            final kind = '${e['segment_type'] ?? e['type'] ?? ''}'.toLowerCase();
            final a = _ms(e['start_ms']) ?? _sec(e['start_sec'] ?? e['start']);
            final b = _ms(e['end_ms']) ?? _sec(e['end_sec'] ?? e['end']);
            if (a == null || b == null || b <= a) continue;
            if (kind.contains('intro')) {
              out['intro'] ??= (a, b);
            } else if (kind.contains('outro') ||
                kind.contains('credit') ||
                kind.contains('ending')) {
              out['outro'] ??= (a, b);
            }
          }
        }
      }
    } catch (_) {}
    _segCache[key] = out;
    return out;
  }

  static Future<(int, int)?> _introdb(List<String> p) async {
    final imdb = p[0], se = p[1], ep = p[2];
    lastLookup = 'introdb $imdb s$se e$ep';
    try {
      final res = await http
          .get(Uri.parse('https://api.introdb.app/intro'
              '?imdb_id=$imdb&season=$se&episode=$ep'))
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null; // 404 = not marked yet
      final d = jsonDecode(res.body);
      final a = (d['start_ms'] as num?)?.toInt();
      final b = (d['end_ms'] as num?)?.toInt();
      if (a == null || b == null || b <= a) return null;
      return (a, b);
    } catch (_) {
      return null;
    }
  }

  // ---------------------- Aniskip (anime) -------------------------------

  /// kitsu series id -> MAL id, via Kitsu's own mapping API. Cached
  /// permanently: one request per show, ever.
  static Future<String?> _malForKitsu(String kitsuId) async {
    final cached = Db.setting('mal|$kitsuId');
    if (cached != null) return cached == '-' ? null : cached;
    String? mal;
    try {
      final res = await http
          .get(Uri.parse('https://kitsu.io/api/edge/anime/$kitsuId/mappings'))
          .timeout(const Duration(seconds: 12));
      if (res.statusCode < 300) {
        for (final m in (jsonDecode(res.body)['data'] as List? ?? [])) {
          if ('${m['attributes']?['externalSite']}' == 'myanimelist/anime') {
            mal = '${m['attributes']?['externalId']}';
            break;
          }
        }
      }
    } catch (_) {}
    Db.setSetting('mal|$kitsuId', mal ?? '-');
    return mal;
  }

  static Future<(int, int)?> _aniskip(String kind, List<String> p) async {
    final mal = p[0] == 'mal' ? p[1] : await _malForKitsu(p[1]);
    final ep = int.tryParse(p[2]);
    lastLookup = 'aniskip mal ${mal ?? '–'} e${ep ?? '–'}';
    if (mal == null || ep == null) return null;
    try {
      final res = await http
          .get(Uri.parse('https://api.aniskip.com/v2/skip-times/$mal/$ep'
              '?types[]=$kind&episodeLength=0'))
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      for (final r in (jsonDecode(res.body)['results'] as List? ?? [])) {
        if ('${r['skipType']}' != kind) continue;
        final iv = r['interval'] as Map? ?? const {};
        final a = (((iv['startTime'] ?? 0) as num) * 1000).toInt();
        final b = (((iv['endTime'] ?? 0) as num) * 1000).toInt();
        if (b > a) return (a, b);
      }
    } catch (_) {}
    return null;
  }
}
