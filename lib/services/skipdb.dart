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
          String type, String itemId, String videoId) =>
      _segment(const {'intro'}, type, itemId, videoId);

  /// Outro/credits start-end - lets Up Next fire exactly when the
  /// episode is really over, not at a guessed percentage.
  static Future<(int, int)?> outro(
          String type, String itemId, String videoId) =>
      _segment(const {'outro', 'credits', 'ending'}, type, itemId, videoId);

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
