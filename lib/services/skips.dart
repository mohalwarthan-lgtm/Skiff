import 'dart:convert';

import 'package:http/http.dart' as http;

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

  static Future<(int, int)?> intro(String type, String videoId) async {
    if (type != 'series') return null;
    final p = videoId.split(':');
    if (p.length >= 3 && (p[0] == 'kitsu' || p[0] == 'mal')) {
      return _aniskip('op', p);
    }
    if (p.length >= 3 && p[0].startsWith('tt')) return _introdb(p);
    lastLookup = 'no source for $videoId';
    return null;
  }

  /// Credits/ending window - lets Up Next fire when the episode really
  /// ends. Anime only for now: IntroDB serves intros through its public
  /// endpoint; its segment endpoints aren't wired here.
  static Future<(int, int)?> outro(String type, String videoId) async {
    if (type != 'series') return null;
    final p = videoId.split(':');
    if (p.length >= 3 && (p[0] == 'kitsu' || p[0] == 'mal')) {
      return _aniskip('ed', p);
    }
    return null;
  }

  // ---------------- IntroDB (everything that isn't anime) ----------------

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
