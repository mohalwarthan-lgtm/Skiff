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
  static Future<String> import(String username) async {
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
          'movie': '${m['format']}' == 'MOVIE',
          'poster': m['coverImage']?['large'],
        });
      }
    }

    // ---- 2. Resolve each via YOUR extension's search; collapse by the
    //         id the extension answers with ----
    final byId = <String, Map>{}; // resolved key -> aggregate
    var unmatched = 0;
    for (var i = 0; i < entries.length; i += 4) {
      await Future.wait([
        for (final e in entries.skip(i).take(4))
          () async {
            final wantType = e['movie'] == true ? 'movie' : 'series';
            Map? hit;
            try {
              final groups = await Addons.searchGrouped('${e['name']}');
              for (final g in groups) {
                for (final it in (g['items'] as List? ?? [])) {
                  if (it is Map && '${it['type']}' == wantType) {
                    hit = it;
                    break;
                  }
                }
                if (hit != null) break;
              }
            } catch (_) {}
            if (hit == null) {
              unmatched++;
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
        '${unmatched > 0 ? ', $unmatched not found by your add-ons' : ''}'
        '${skipped > 0 ? ', $skipped dropped skipped' : ''}'
        ' — episode ticks fill in as the library catalogues.';
  }
}
