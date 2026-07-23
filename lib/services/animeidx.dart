import 'dart:convert';

import 'package:http/http.dart' as http;

import 'db.dart';

/// Anime identity index: AniDB/MAL <-> TVDB/IMDb, from the anime-lists
/// mapping project (the same data Sonarr/Jellyfin/Shoko rely on).
///
/// Membership IS the anime test: if an entry exists for an imdb id, the
/// title is anime. Each entry is ONE cour and carries the TVDB season it
/// corresponds to, so (imdb, season) -> MAL id needs no arithmetic.
///
/// Downloaded once, kept as a compact index (imdb -> season -> mal), and
/// re-fetched only when a lookup misses and the copy is a day old - so a
/// newly added show starts working the day after it lands upstream.
class AnimeIndex {
  static const _url = 'https://raw.githubusercontent.com/Fribb/'
      'anime-lists/master/anime-list-full.json';
  static const _ambiguous = '-'; // several cours claim one TVDB season

  static Map<String, Map<String, String>>? _mem;
  static bool _busy = false;

  static Map<String, Map<String, String>> _index() {
    if (_mem != null) return _mem!;
    final raw = Db.meta.get('animeidx');
    final out = <String, Map<String, String>>{};
    if (raw is Map) {
      for (final e in raw.entries) {
        final inner = e.value;
        if (inner is! Map) continue;
        out['${e.key}'] = {
          for (final s in inner.entries) '${s.key}': '${s.value}'
        };
      }
    }
    return _mem = out;
  }

  static int get _ageHours {
    final at = int.tryParse(Db.setting('animeidx_at') ?? '') ?? 0;
    if (at == 0) return 1 << 20;
    return DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(at))
        .inHours;
  }

  static Future<bool> _refresh() async {
    if (_busy) return false;
    _busy = true;
    try {
      final res =
          await http.get(Uri.parse(_url)).timeout(const Duration(seconds: 90));
      if (res.statusCode >= 300) return false;
      final list = jsonDecode(res.body);
      if (list is! List) return false;
      final out = <String, Map<String, String>>{};
      for (final e in list) {
        if (e is! Map) continue;
        final mal = e['mal_id'];
        if (mal == null) continue;
        // season is {'tvdb': n, 'tmdb': n} in this dataset
        final seasonRaw = e['season'];
        final season = seasonRaw is Map ? seasonRaw['tvdb'] : seasonRaw;
        if (season == null) continue;
        // imdb_id is an ARRAY here - a plain string compare never matches
        final rawIds = e['imdb_id'];
        final ids = rawIds is List ? rawIds : (rawIds == null ? [] : [rawIds]);
        for (final raw in ids) {
          final imdb = '$raw';
          if (!imdb.startsWith('tt')) continue;
          final byS = out.putIfAbsent(imdb, () => <String, String>{});
          final key = '$season';
          final prev = byS[key];
          if (prev == null) {
            byS[key] = '$mal';
          } else if (prev != '$mal') {
            byS[key] = _ambiguous; // no button beats a wrong button
          }
        }
      }
      if (out.isEmpty) return false;
      await Db.meta.put('animeidx', out);
      Db.setSetting(
          'animeidx_at', DateTime.now().millisecondsSinceEpoch.toString());
      _mem = out;
      return true;
    } catch (_) {
      return false;
    } finally {
      _busy = false;
    }
  }

  /// MAL id for a TVDB-numbered episode, or null when unknown/ambiguous.
  static Future<String?> malFor(String imdb, int season) async {
    final hit = _index()[imdb]?['$season'];
    if (hit != null) return hit == _ambiguous ? null : hit;
    // A miss is worth one refresh a day; remember it so a title the
    // project genuinely doesn't have can't trigger repeated downloads.
    final missAt = int.tryParse(Db.setting('animeidx_miss|$imdb') ?? '') ?? 0;
    final missDays = missAt == 0
        ? 999
        : DateTime.now()
            .difference(DateTime.fromMillisecondsSinceEpoch(missAt))
            .inDays;
    if (_ageHours < 24 || missDays < 3) return null;
    Db.setSetting(
        'animeidx_miss|$imdb', DateTime.now().millisecondsSinceEpoch.toString());
    if (!await _refresh()) return null;
    final again = _index()[imdb]?['$season'];
    return (again == null || again == _ambiguous) ? null : again;
  }

  /// True when the mapping project knows this imdb id at all.
  static bool isAnime(String imdb) => _index().containsKey(imdb);
}
