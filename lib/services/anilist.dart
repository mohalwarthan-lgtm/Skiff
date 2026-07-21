import 'dart:convert';

import 'package:http/http.dart' as http;

import 'db.dart';

/// One-time AniList library import. Public GraphQL - just a username, no
/// login. Shelves map: CURRENT/REPEATING/PAUSED -> Watching,
/// PLANNING -> Plan, COMPLETED -> Completed, DROPPED skipped.
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
    var n = 0, skipped = 0;
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
        final id = 'anilist:${m['id']}';
        final type = '${m['format']}' == 'MOVIE' ? 'movie' : 'series';
        final isNew = Db.itemStatus(type, id) == null;
        if (isNew) {
          Db.setStatus(type, id, shelf,
              name: m['title']?['english'] ?? m['title']?['romaji']);
          Db.touchItem(type, id, poster: m['coverImage']?['large']);
          n++;
        }
        // Episodes-watched count: applied as real ticks once the show's
        // episode list is known (library hydration).
        final prog = (e['progress'] as num?)?.toInt() ?? 0;
        if (type == 'series' && prog > 0) {
          final k = '$type|$id';
          final rec = Map.of(Db.items.get(k) as Map);
          rec['alProgress'] = prog;
          await Db.items.put(k, rec);
        }
      }
    }
    return 'Imported $n titles from AniList — episode progress fills in as the library loads their metadata'
        '${skipped > 0 ? ' ($skipped dropped/other skipped)' : ''}.';
  }
}
