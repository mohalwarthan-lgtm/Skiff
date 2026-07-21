import 'dart:convert';

import 'package:http/http.dart' as http;

import 'db.dart';

/// One-time AniList library import. Public GraphQL - just a username, no
/// login. Shelves map: CURRENT/REPEATING/PAUSED -> Watching,
/// PLANNING -> Plan, COMPLETED -> Completed, DROPPED skipped.
class Anilist {
  /// Community anime-id cross-reference: AniList -> (imdb, kitsu).
  /// Fetched once per import (~13 MB), held in memory only.
  static Future<Map<int, (String?, int?)>> _mapping() async {
    final res = await http.get(Uri.parse(
        'https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json'));
    if (res.statusCode >= 300) throw 'mapping unavailable';
    final list = jsonDecode(res.body) as List;
    final out = <int, (String?, int?)>{};
    for (final m in list) {
      if (m is! Map) continue;
      final al = (m['anilist_id'] as num?)?.toInt();
      if (al == null) continue;
      final imdb = m['imdb_id'];
      out[al] = (
        imdb is String && imdb.startsWith('tt') ? imdb : null,
        (m['kitsu_id'] as num?)?.toInt(),
      );
    }
    return out;
  }

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
    // Translate into the ids the rest of the app speaks (imdb first,
    // kitsu second) so imports are the SAME entity as your catalogs.
    Map<int, (String?, int?)> idMap = const {};
    var unmapped = 0;
    try {
      idMap = await _mapping();
    } catch (_) {/* fall back to anilist ids */}
    var n = 0, skipped = 0, healed = 0;
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
        final alId = (m['id'] as num?)?.toInt() ?? 0;
        final mp = idMap[alId];
        // Kitsu FIRST: it's the id language this app's anime catalogs and
        // search speak (and it matches AniList's per-season granularity).
        // Imdb only as a fallback, anilist as a last resort.
        final id = mp?.$2 != null
            ? 'kitsu:${mp!.$2}'
            : (mp?.$1 ?? 'anilist:$alId');
        if (id == 'anilist:$alId' && idMap.isNotEmpty) unmapped++;
        final type = '${m['format']}' == 'MOVIE' ? 'movie' : 'series';
        // Heal earlier imports: collapse this entry's duplicates under
        // other id dialects (anilist-keyed, imdb-keyed) into the one
        // corrected identity - preserving any shelf you had put it on.
        for (final gid in [
          'anilist:$alId',
          if (mp?.$1 != null && mp!.$1 != id) mp.$1!,
        ]) {
          final gkey = '$type|$gid';
          final g = Db.items.get(gkey) as Map?;
          if (g == null) continue;
          if (Db.itemStatus(type, id) == null && g['status'] != null) {
            Db.setStatus(type, id, g['status'], name: g['name']);
            Db.touchItem(type, id, poster: g['poster']);
          }
          await Db.items.delete(gkey);
          healed++;
          for (final k in Db.progress.keys
              .cast<String>()
              .where((k) => k.contains('|$gid|'))
              .toList()) {
            await Db.progress.delete(k);
          }
        }
        final isNew = Db.itemStatus(type, id) == null;
        if (isNew) {
          Db.setStatus(type, id, shelf,
              name: m['title']?['english'] ?? m['title']?['romaji']);
          Db.touchItem(type, id, poster: m['coverImage']?['large']);
          n++;
        }
        // Episodes-watched count, applied as real ticks once the show's
        // episode list is known (library hydration). Completed shows are
        // stamped -1 = "every released episode", so Trakt receives the
        // full history too.
        final prog = (e['progress'] as num?)?.toInt() ?? 0;
        if (type == 'series') {
          final stamp = shelf == 'completed' ? -1 : prog;
          if (stamp != 0) {
            final k = '$type|$id';
            final rec = Map.of(Db.items.get(k) as Map);
            rec['alProgress'] = stamp;
            await Db.items.put(k, rec);
          }
        } else if (shelf == 'completed') {
          // Movies: the watched flag itself is the history entry.
          Db.markWatched(type, id, id, true);
        }
      }
    }
    return 'Imported $n titles'
        '${healed > 0 ? ', removed $healed old duplicates' : ''}'
        '${unmapped > 0 ? ', $unmapped without an id match' : ''}'
        ' from AniList — episode progress fills in as the library loads their metadata'
        '${skipped > 0 ? ' ($skipped dropped/other skipped)' : ''}.';
  }
}
