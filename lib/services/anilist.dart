import 'dart:convert';

import 'package:http/http.dart' as http;

import 'addons.dart';
import 'db.dart';

/// AniList library import that speaks YOUR add-ons' language.
///
/// Every title is resolved by searching your own metadata extension and
/// adopting whatever id it returns - so an imported show is, by
/// construction, the exact same entity Home and search serve. Several
/// AniList entries (per-season/cour) collapsing into one extension entity
/// is expected and handled: shelves merge, episode counts sum.
class Anilist {
  static String _norm(Object? x) =>
      '$x'.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  static bool _isAnimeId(String id) =>
      id.startsWith('kitsu:') ||
      id.startsWith('mal:') ||
      id.startsWith('anilist:');

  static bool _near(String a, String b) =>
      a.isNotEmpty && b.isNotEmpty && (a.contains(b) || b.contains(a));

  /// Find this AniList entry among the extension's own search results.
  /// Rules, in order of authority: the result MUST be anime-keyed
  /// (kitsu/mal) - a live-action namesake on an imdb id is never
  /// accepted; names are verified against BOTH the romaji and english
  /// titles; and if the first query finds nothing acceptable, the
  /// alternate title is queried too (e.g. Ao Haru Ride / Blue Spring
  /// Ride). Slow titles are given time - only a truly hung request
  /// (30s) is abandoned.
  static Future<Map?> _resolve(Map e, String wantType) async {
    final rn = _norm(e['nameR']), en = _norm(e['nameE']);
    Map? best;
    var bestScore = 0;
    Future<void> tryQuery(String q) async {
      if (q.trim().isEmpty) return;
      final groups = await Addons.searchGrouped(q)
          .timeout(const Duration(seconds: 30));
      for (final g in groups) {
        for (final it in (g['items'] as List? ?? [])) {
          if (it is! Map || '${it['type']}' != wantType) continue;
          // "Is this anime?" - answered by the METADATA, not the id
          // dialect (with imdb-mode search, anime is tt-keyed too):
          // anime-keyed id OR an Animation/Anime genre both count.
          final gs = (it['genres'] as List? ?? [])
              .map((g) => '$g'.toLowerCase())
              .toList();
          final animeSig = _isAnimeId('${it['id']}') ||
              gs.any((g) => g.contains('anime')) ||
              gs.contains('animation');
          final nm = _norm(it['name']);
          var sc = animeSig ? 100 : 0;
          if (nm.isNotEmpty && (nm == rn || nm == en)) {
            sc += 60;
          } else if (_near(nm, rn) || _near(nm, en)) {
            sc += 25;
          }
          if (sc > bestScore) {
            bestScore = sc;
            best = it.cast<String, dynamic>();
          }
        }
      }
    }
    await tryQuery('${e['name']}');
    if (bestScore < 160) {
      final alt = e['name'] == e['nameR'] ? e['nameE'] : e['nameR'];
      if ('$alt' != '${e['name']}') await tryQuery('$alt');
    }
    // Accept: any anime-signalled candidate (>=100), or an exact-name
    // match without genre info (60). A merely-similar name on a
    // non-anime result (25) is never accepted.
    return bestScore >= 60 ? best : null;
  }

  static Future<String> import(String username,
      {void Function(String)? onProgress}) async {
    const q = r'''
query ($name: String) {
  MediaListCollection(userName: $name, type: ANIME) {
    lists { entries { status progress media {
      id format
      title { romaji english }
      coverImage { large }
    } } }
  }
}''';
    final res = await http.post(Uri.parse('https://graphql.anilist.co'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(
            {'query': q, 'variables': {'name': username.trim()}}));
    if (res.statusCode >= 300) {
      throw 'AniList: HTTP ${res.statusCode} - is the username right and '
          'the list public?';
    }
    final data = jsonDecode(res.body);
    final lists = data?['data']?['MediaListCollection']?['lists'] as List?;
    if (lists == null) throw 'AniList: no lists found for "$username".';

    // ---- 1. Flatten AniList entries we care about ----
    final entries = <Map>[];
    var skipped = 0;
    for (final l in lists) {
      for (final e in (l['entries'] as List? ?? [])) {
        final shelf = switch ('${e['status']}') {
          'CURRENT' || 'REPEATING' || 'PAUSED' => 'watching',
          'PLANNING' => 'plan',
          'COMPLETED' => 'completed',
          _ => null,
        };
        if (shelf == null) {
          skipped++;
          continue;
        }
        final m = e['media'] as Map? ?? const {};
        entries.add({
          'shelf': shelf,
          'progress': (e['progress'] as num?)?.toInt() ?? 0,
          'completed': shelf == 'completed',
          'name': m['title']?['english'] ?? m['title']?['romaji'] ?? '',
          'nameR': m['title']?['romaji'] ?? '',
          'nameE': m['title']?['english'] ?? '',
          'movie': '${m['format']}' == 'MOVIE',
          'poster': m['coverImage']?['large'],
        });
      }
    }

    // ---- 2. Resolve each via YOUR extension's search; collapse by the
    //         id the extension answers with ----
    final byId = <String, Map>{}; // resolved key -> aggregate
    var unmatched = 0;
    final unmatchedNames = <String>[];
    for (var i = 0; i < entries.length; i += 4) {
      onProgress?.call(
          'Matching ${i + 1}–${(i + 4).clamp(0, entries.length)}'
          ' of ${entries.length} with your extension…');
      await Future.wait([
        for (final e in entries.skip(i).take(4))
          () async {
            final wantType = e['movie'] == true ? 'movie' : 'series';
            Map? hit;
            try {
              hit = await _resolve(e, wantType);
            } catch (_) {}
            if (hit == null) {
              unmatched++;
              if (unmatchedNames.length < 3) {
                unmatchedNames.add('${e['name']}');
              }
              return;
            }
            final key = '$wantType|${hit['id']}';
            final agg = byId.putIfAbsent(
                key,
                () => {
                      'type': wantType,
                      'id': '${hit!['id']}',
                      'name': hit['name'] ?? e['name'],
                      'poster': hit['poster'] ?? e['poster'],
                      'progressSum': 0,
                      'anyWatching': false,
                      'anyPlan': false,
                      'allCompleted': true,
                    });
            agg['progressSum'] =
                (agg['progressSum'] as int) + (e['progress'] as int);
            if (e['shelf'] == 'watching') agg['anyWatching'] = true;
            if (e['shelf'] == 'plan') agg['anyPlan'] = true;
            if (e['completed'] != true) agg['allCompleted'] = false;
          }()
      ]);
    }

    // ---- 3. Write items + progress stamps ----
    var added = 0, merged = 0;
    for (final agg in byId.values) {
      final type = agg['type'] as String, id = agg['id'] as String;
      final allDone = agg['allCompleted'] == true;
      final shelf = agg['anyWatching'] == true
          ? 'watching'
          : allDone
              ? 'completed'
              // mixed completed+plan means mid-franchise -> watching
              : (agg['anyPlan'] == true && agg['progressSum'] == 0
                  ? 'plan'
                  : 'watching');
      if (Db.itemStatus(type, id) == null) {
        Db.setStatus(type, id, shelf, name: agg['name']);
        Db.touchItem(type, id, poster: agg['poster']);
        added++;
      } else {
        merged++; // already yours - shelf respected, progress still lands
      }
      if (type == 'movie') {
        if (allDone) Db.markWatched(type, id, id, true);
        continue;
      }
      final stamp = allDone ? -1 : (agg['progressSum'] as int);
      if (stamp != 0) {
        final k = '$type|$id';
        final rec = Map.of(Db.items.get(k) as Map);
        rec['alProgress'] = stamp;
        await Db.items.put(k, rec);
      }
    }
    return 'Imported $added titles via your extension'
        '${merged > 0 ? ', $merged merged into existing entries' : ''}'
        '${unmatched > 0 ? ', $unmatched not found by your add-ons'
            ' (e.g. ${unmatchedNames.join(', ')})' : ''}'
        '${skipped > 0 ? ', $skipped dropped skipped' : ''}'
        ' — episode ticks fill in as the library catalogues.';
  }
}
