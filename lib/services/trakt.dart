import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config.dart';
import 'db.dart';

/// Trakt.tv: device-code login, scrobbling, and two-way sync.
/// Local -> Trakt: shelf changes push to watchlist/history immediately.
/// Trakt -> local: watched history + watchlist pulled on start and periodically.
class Trakt {
  static const _api = 'https://api.trakt.tv';

  /// Live sync status for the UI ("Syncing...", "Synced 19:42", ...).
  static final syncStatus = ValueNotifier<String>('');

  static String _clock() {
    final n = DateTime.now();
    final h = n.hour.toString().padLeft(2, '0');
    final m = n.minute.toString().padLeft(2, '0');
    return '${h}:${m}';
  }

  static (String, String)? client() {
    if (Config.hasBundledTrakt) {
      return (Config.traktClientId, Config.traktClientSecret);
    }
    final id = Db.setting('trakt_client_id');
    final secret = Db.setting('trakt_client_secret');
    if (id == null || secret == null) return null;
    return (id, secret);
  }

  static bool get connected =>
      client() != null && (Db.setting('trakt_access') ?? '').isNotEmpty;

  static Map<String, String> _headers(String clientId, [String? access]) => {
        'Content-Type': 'application/json',
        'trakt-api-version': '2',
        'trakt-api-key': clientId,
        if (access != null) 'Authorization': 'Bearer $access',
      };

  // ---------- Device auth ----------

  static Future<Map<String, dynamic>> deviceCode() async {
    final c = client();
    if (c == null) throw 'No Trakt credentials configured.';
    final res = await http.post(Uri.parse('$_api/oauth/device/code'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'client_id': c.$1}));
    if (res.statusCode != 200) throw 'Trakt: HTTP ${res.statusCode}';
    return jsonDecode(res.body);
  }

  /// One poll. true = authorized, false = still waiting.
  static Future<bool> pollToken(String deviceCode) async {
    final c = client()!;
    final res = await http.post(Uri.parse('$_api/oauth/device/token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'code': deviceCode,
          'client_id': c.$1,
          'client_secret': c.$2,
        }));
    switch (res.statusCode) {
      case 200:
        _saveTokens(jsonDecode(res.body));
        return true;
      case 400:
      case 429:
        return false; // pending / slow down
      case 404:
        throw 'Invalid device code.';
      case 410:
      case 418:
        throw 'The code expired or was denied — start over.';
      default:
        throw 'Trakt: unexpected status ${res.statusCode}';
    }
  }

  static void _saveTokens(Map t) {
    Db.setSetting('trakt_access', t['access_token']);
    Db.setSetting('trakt_refresh', t['refresh_token']);
    final expiresAt = (t['created_at'] as int) + (t['expires_in'] as int);
    Db.setSetting('trakt_expires_at', expiresAt.toString());
  }

  static void disconnect() {
    Db.deleteSetting('trakt_access');
    Db.deleteSetting('trakt_refresh');
    Db.deleteSetting('trakt_expires_at');
  }

  /// Refresh the token if it expires within a day.
  static Future<void> ensureFresh() async {
    if (!connected) throw 'Trakt is not connected';
    final expiresAt = int.tryParse(Db.setting('trakt_expires_at') ?? '') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (expiresAt > now + 86400) return;
    final c = client()!;
    final res = await http.post(Uri.parse('$_api/oauth/token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'refresh_token': Db.setting('trakt_refresh'),
          'client_id': c.$1,
          'client_secret': c.$2,
          'redirect_uri': 'urn:ietf:wg:oauth:2.0:oob',
          'grant_type': 'refresh_token',
        }));
    if (res.statusCode == 200) _saveTokens(jsonDecode(res.body));
  }

  // ---------- Scrobbling ----------

  /// Trakt's episode numbering can disagree with the metadata add-on's
  /// (anime especially: TVDB-style 3 seasons vs Trakt's one long season,
  /// like Re:Zero). We fetch Trakt's own episode table once per show
  /// (cached a week) and translate by absolute position when the direct
  /// (season, episode) doesn't exist on Trakt's side.
  static Future<List?> _traktSeasons(String imdb) async {
    final key = 'traktseasons|' + imdb;
    final cached = Db.meta.get(key);
    if (cached is Map) {
      final at = (cached['at'] ?? 0) as num;
      if (Db.now() - at < 7 * 24 * 3600) return cached['seasons'] as List?;
    }
    try {
      final c = client()!;
      final res = await http.get(
          Uri.parse('$_api/shows/$imdb/seasons?extended=episodes'),
          headers: _headers(c.$1));
      if (res.statusCode >= 300) {
        return cached is Map ? cached['seasons'] as List? : null;
      }
      final list = jsonDecode(res.body) as List;
      final slim = [
        for (final se in list)
          if (((se['number'] ?? 0) as num) > 0)
            {
              'number': (se['number'] as num).toInt(),
              'episodes': ([
                for (final e in (se['episodes'] as List? ?? []))
                  ((e['number'] ?? 0) as num).toInt()
              ]..sort()),
            }
      ];
      await Db.meta.put(key, {'at': Db.now(), 'seasons': slim});
      return slim;
    } catch (_) {
      return cached is Map ? cached['seasons'] as List? : null;
    }
  }

  static List<(int, int)> _flatEpisodes(List seasons) => [
        for (final se in seasons)
          for (final e in (se['episodes'] as List))
            ((se['number'] as num).toInt(), (e as num).toInt())
      ];

  static bool _traktHas(List seasons, int se, int ep) => seasons.any((s0) =>
      (s0['number'] as num).toInt() == se &&
      (s0['episodes'] as List).contains(ep));

  /// Ordered (season, episode, videoId) from the local metadata cache.
  static List<(int, int, String)> _localEpisodes(String type, String itemId) {
    final meta = Db.cachedMeta(type, itemId);
    final rows = <(int, int, String)>[];
    for (final v in (meta?['videos'] as List? ?? [])) {
      if (v is Map) {
        final se = (v['season'] as num?)?.toInt() ?? 0;
        final ep = (v['episode'] as num?)?.toInt() ?? 0;
        if (se > 0) rows.add((se, ep, '${v['id']}'));
      }
    }
    rows.sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
    return rows;
  }

  /// Local numbering -> Trakt numbering.
  static Future<(int, int)> toTraktNumbering(
      String imdb, String type, String itemId, int se, int ep) async {
    final tr = await _traktSeasons(imdb);
    if (tr == null || tr.isEmpty || _traktHas(tr, se, ep)) return (se, ep);
    final locals = _localEpisodes(type, itemId);
    final idx = locals.indexWhere((r) => r.$1 == se && r.$2 == ep);
    if (idx < 0) return (se, ep);
    final flat = _flatEpisodes(tr);
    return idx < flat.length ? flat[idx] : (se, ep);
  }

  /// Trakt numbering -> local (season, episode, videoId).
  static Future<(int, int, String)?> fromTraktNumbering(
      String imdb, String type, String itemId, int se, int ep) async {
    final locals = _localEpisodes(type, itemId);
    for (final r in locals) {
      if (r.$1 == se && r.$2 == ep) return r;
    }
    final tr = await _traktSeasons(imdb);
    if (tr == null) return null;
    final idx =
        _flatEpisodes(tr).indexWhere((t) => t.$1 == se && t.$2 == ep);
    if (idx >= 0 && idx < locals.length) return locals[idx];
    return null;
  }

  /// Resolve ANY Stremio video id to Trakt-usable identifiers.
  /// "tt0944947:3:9" parses directly; prefixed ids like "kitsu:7169:5"
  /// are translated through the cached metadata (imdb_id + the episode's
  /// season/episode fields). Returns null when no imdb mapping exists.
  /// For progress pulled FROM Trakt: find the local item that maps to this
  /// imdb id (it may live under a kitsu-style id) so the position lands on
  /// the row the app actually uses. Falls back to imdb-keyed ids.
  static Future<(String, String)> _localTarget(
      String type, String imdb, int? season, int? episode) async {
    (String, String)? viaImdbItem;
    for (final it in Db.items.values.cast<Map>()) {
      if (it['type'] != type) continue;
      final itemId = it['id'] as String;
      String? itImdb = itemId.startsWith('tt') ? itemId : null;
      final meta = Db.cachedMeta(type, itemId);
      itImdb ??= (meta?['imdb_id'] ?? meta?['imdbId']) as String?;
      if (itImdb != imdb) continue;
      (String, String) result;
      if (type == 'movie') {
        result = (itemId, itemId);
      } else if (season != null && episode != null) {
        final hit = await fromTraktNumbering(
            imdb, type, itemId, season, episode);
        result =
            hit != null ? (itemId, hit.$3) : (itemId, '$itemId:$season:$episode');
      } else {
        result = (itemId, '$itemId:$season:$episode');
      }
      // Prefer the add-on-keyed item; an imdb-keyed duplicate left over
      // from older syncs must not shadow the item the UI actually shows.
      if (itemId != imdb) return result;
      viaImdbItem = result;
    }
    if (viaImdbItem != null) return viaImdbItem;
    return type == 'movie'
        ? (imdb, imdb)
        : (imdb, '$imdb:$season:$episode');
  }

  static (String, int?, int?)? resolveVideo(
      String type, String itemId, String videoId) {
    final p = videoId.split(':');
    // Fully imdb-shaped episode id: parse directly.
    if (p.first.startsWith('tt') && p.length >= 3) {
      return (p[0], int.tryParse(p[1]), int.tryParse(p[2]));
    }
    // Otherwise anchor on the item we KNOW this video belongs to. Handles
    // mixed setups (imdb-keyed item + kitsu-keyed episodes) cleanly.
    String? imdb = itemId.startsWith('tt') ? itemId : null;
    final meta = Db.cachedMeta(type, itemId);
    if (imdb == null) {
      final rawImdb = meta?['imdb_id'] ?? meta?['imdbId'] ?? meta?['imdbid'];
      if (rawImdb is String && rawImdb.startsWith('tt')) imdb = rawImdb;
    }
    if (imdb == null) return null;
    if (type != 'series') return (imdb, null, null);
    int? se, ep;
    for (final v in (meta?['videos'] as List? ?? [])) {
      if (v is Map && v['id'] == videoId) {
        se = (v['season'] as num?)?.toInt();
        ep = (v['episode'] as num?)?.toInt();
        break;
      }
    }
    ep ??= int.tryParse(p.last);
    se ??= 1;
    if (ep == null) return null;
    return (imdb, se, ep);
  }

  /// Movies: videoId "tt0111161". Episodes: "tt0944947:3:9".
  static Future<Map<String, dynamic>> _scrobbleBody(
      String itemType, String itemId, String videoId, double progressPct) async {
    final r = resolveVideo(itemType, itemId, videoId);
    if (r == null) return const {};
    if (itemType == 'series' && r.$2 != null && r.$3 != null) {
      final t = await toTraktNumbering(r.$1, itemType, itemId, r.$2!, r.$3!);
      return {
        'show': {'ids': {'imdb': r.$1}},
        'episode': {'season': t.$1, 'number': t.$2},
        'progress': progressPct,
      };
    }
    return {
      'movie': {'ids': {'imdb': r.$1}},
      'progress': progressPct,
    };
  }

  /// action: start | pause | stop. Fire-and-forget safe: throws only strings.
  static Future<void> scrobble(
      String action, String itemType, String itemId, String videoId, double pct) async {
    if (!connected) return;
    final body = await _scrobbleBody(itemType, itemId, videoId, pct);
    if (body.isEmpty) {
      syncStatus.value = 'Scrobble skipped — no Trakt mapping ($videoId)';
      return;
    }
    // Trakt rejects pause/stop under 1% - and sending them would only
    // clobber a real saved position with nothing.
    if (action != 'start' && pct < 1) return;
    await ensureFresh();
    final c = client()!;
    final res = await http.post(Uri.parse('$_api/scrobble/$action'),
        headers: _headers(c.$1, Db.setting('trakt_access')),
        body: jsonEncode(body));
    if (res.statusCode >= 300) {
      final why = res.body.replaceAll('\n', ' ');
      syncStatus.value =
          'Scrobble $action failed (HTTP ${res.statusCode}): '
          '${why.length > 90 ? why.substring(0, 90) : why}';
    } else if (action != 'start') {
      syncStatus.value = 'Progress sent to Trakt ' + _clock();
    }
  }

  // ---------- Push (local -> Trakt) ----------

  static Future<void> _syncPost(String path, Map body) async {
    if (!connected) return;
    try {
      await ensureFresh();
      final c = client()!;
      final res = await http.post(Uri.parse('$_api/sync/$path'),
          headers: _headers(c.$1, Db.setting('trakt_access')),
          body: jsonEncode(body));
      syncStatus.value = res.statusCode < 300
          ? 'Change pushed at ' + _clock()
          : 'Push failed (HTTP ' + res.statusCode.toString() + ')';
    } catch (e) {
      syncStatus.value = 'Push failed - will retry on next sync';
    }
  }

  static Map _watchlistBody(String type, String id) => {
        type == 'series' ? 'shows' : 'movies': [
          {'ids': {'imdb': id}}
        ]
      };

  static Future<Map> _historyBody(
      String type, String itemId, String videoId) async {
    final r = resolveVideo(type, itemId, videoId);
    if (r == null) return const {};
    if (type == 'series' && r.$2 != null && r.$3 != null) {
      final t = await toTraktNumbering(r.$1, type, itemId, r.$2!, r.$3!);
      return {
        'shows': [
          {
            'ids': {'imdb': r.$1},
            'seasons': [
              {
                'number': t.$1,
                'episodes': [
                  {'number': t.$2}
                ]
              }
            ]
          }
        ]
      };
    }
    return {
      'movies': [
        {'ids': {'imdb': r.$1}}
      ]
    };
  }

  /// Shelf changes: 'plan' lands on the Trakt watchlist; any other shelf
  /// takes it off the watchlist.
  static void pushStatus(String type, String id, String status) {
    if (status == 'plan') {
      _syncPost('watchlist', _watchlistBody(type, id));
    } else {
      _syncPost('watchlist/remove', _watchlistBody(type, id));
    }
  }

  /// Removing a title locally removes it from Trakt too - watchlist,
  /// watch history, AND paused playback progress (the "Continue Watching"
  /// row on Trakt) - so nothing can resurrect it.
  static void pushRemoval(String type, String id) {
    _syncPost('watchlist/remove', _watchlistBody(type, id));
    _syncPost('history/remove', _watchlistBody(type, id));
    clearPlayback(id);
  }

  /// Delete every Trakt playback-progress entry for the given imdb id.
  /// This is what feeds Trakt's "Continue Watching" row.
  static Future<void> clearPlayback(String imdbId) async {
    if (!connected) return;
    try {
      await ensureFresh();
      final c = client()!;
      final h = _headers(c.$1, Db.setting('trakt_access'));
      final res = await http.get(Uri.parse('$_api/sync/playback'), headers: h);
      if (res.statusCode >= 300) return;
      final list = jsonDecode(res.body) as List;
      for (final e in list) {
        final media = (e['movie'] ?? e['show']) as Map?;
        if (media?['ids']?['imdb'] == imdbId) {
          await http.delete(Uri.parse('$_api/sync/playback/${e['id']}'),
              headers: h);
        }
      }
    } catch (_) {/* best effort */}
  }

  /// Make Trakt mirror this library exactly: any title on Trakt (watchlist,
  /// watched history, or paused playback) that is NOT in the local library
  /// gets removed from Trakt. Returns a summary.
  static Future<String> mirrorLocal() async {
    if (!connected) return 'Not connected';
    syncStatus.value = 'Mirroring library to Trakt…';
    await ensureFresh();
    final c = client()!;
    final h = _headers(c.$1, Db.setting('trakt_access'));
    final keep = {
      for (final it in Db.items.values.cast<Map>()) it['id'] as String
    };
    // Items may live under kitsu-style ids locally; keep their imdb ids too.
    for (final it in Db.items.values.cast<Map>()) {
      final meta = Db.cachedMeta(it['type'], it['id']);
      final imdb = meta?['imdb_id'] ?? meta?['imdbId'];
      if (imdb is String && imdb.startsWith('tt')) keep.add(imdb);
    }
    var removed = 0;

    Future<List> getList(String path) async {
      final res = await http.get(Uri.parse('$_api/$path'), headers: h);
      if (res.statusCode >= 300) return const [];
      final body = jsonDecode(res.body);
      return body is List ? body : const [];
    }

    // 1) Paused playback entries ("Continue Watching" on Trakt).
    for (final e in await getList('sync/playback')) {
      final media = (e['movie'] ?? e['show']) as Map?;
      final imdb = media?['ids']?['imdb'];
      if (imdb != null && !keep.contains(imdb)) {
        await http.delete(Uri.parse('$_api/sync/playback/${e['id']}'),
            headers: h);
        removed++;
      }
    }

    // 2) Watched history: whole titles not in the library.
    final movieIds = <Map>[];
    for (final e in await getList('sync/watched/movies')) {
      final imdb = e['movie']?['ids']?['imdb'];
      if (imdb != null && !keep.contains(imdb)) {
        movieIds.add({'ids': {'imdb': imdb}});
      }
    }
    final showIds = <Map>[];
    for (final e in await getList('sync/watched/shows')) {
      final imdb = e['show']?['ids']?['imdb'];
      if (imdb != null && !keep.contains(imdb)) {
        showIds.add({'ids': {'imdb': imdb}});
      }
    }
    if (movieIds.isNotEmpty || showIds.isNotEmpty) {
      await _syncPost('history/remove', {
        if (movieIds.isNotEmpty) 'movies': movieIds,
        if (showIds.isNotEmpty) 'shows': showIds,
      });
      removed += movieIds.length + showIds.length;
    }

    // 3) Watchlist entries not in the library.
    final wlMovies = <Map>[];
    final wlShows = <Map>[];
    for (final e in await getList('sync/watchlist')) {
      final media = (e['movie'] ?? e['show']) as Map?;
      final imdb = media?['ids']?['imdb'];
      if (imdb != null && !keep.contains(imdb)) {
        (e['movie'] != null ? wlMovies : wlShows)
            .add({'ids': {'imdb': imdb}});
      }
    }
    if (wlMovies.isNotEmpty || wlShows.isNotEmpty) {
      await _syncPost('watchlist/remove', {
        if (wlMovies.isNotEmpty) 'movies': wlMovies,
        if (wlShows.isNotEmpty) 'shows': wlShows,
      });
      removed += wlMovies.length + wlShows.length;
    }

    syncStatus.value = 'Trakt mirrored at ' + _clock();
    return 'Removed $removed Trakt entries that are not in your library.';
  }

  static Future<void> pushWatched(
      String type, String itemId, String videoId, bool watched) async {
    final body = await _historyBody(type, itemId, videoId);
    if (body.isEmpty) return; // no imdb mapping
    _syncPost(watched ? 'history' : 'history/remove', body);
  }

  // ---------- Pull (Trakt -> local) ----------

  static Future<Map<String, dynamic>> _get(String path) async {
    final c = client()!;
    final res = await http.get(Uri.parse('$_api$path'),
        headers: _headers(c.$1, Db.setting('trakt_access')));
    if (res.statusCode != 200) throw 'Trakt $path: HTTP ${res.statusCode}';
    return {'data': jsonDecode(res.body)};
  }

  /// Push the entire local library up to Trakt: 'plan' items to the
  /// watchlist, watched episodes/movies to history. Runs before a pull so a
  /// manual sync reflects local changes made offline. Batched to be polite.
  static Future<String> pushLibrary() async {
    if (!connected) return 'Not connected';
    syncStatus.value = 'Pushing library…';
    await ensureFresh();

    final planShows = <Map>[];
    final planMovies = <Map>[];
    for (final it in Db.items.values.cast<Map>()) {
      if (it['status'] == 'plan') {
        final entry = {'ids': {'imdb': it['id']}};
        (it['type'] == 'series' ? planShows : planMovies).add(entry);
      }
    }
    if (planShows.isNotEmpty || planMovies.isNotEmpty) {
      await _syncPost('watchlist', {
        if (planShows.isNotEmpty) 'shows': planShows,
        if (planMovies.isNotEmpty) 'movies': planMovies,
      });
    }

    // Watched history: group episodes under their show, movies flat.
    final movieHist = <Map>[];
    final showMap = <String, Map<int, List<int>>>{};
    for (final p in Db.progress.values.cast<Map>()) {
      if (p['watched'] != true) continue;
      final vid = p['videoId'] as String;
      final itemId = p['itemId'] as String? ?? vid;
      final r =
          resolveVideo(p['type'] as String? ?? 'movie', itemId, vid);
      if (r == null) continue; // no imdb mapping
      if (p['type'] == 'series' && r.$2 != null && r.$3 != null) {
        final t = await toTraktNumbering(
            r.$1, 'series', itemId, r.$2!, r.$3!);
        showMap
            .putIfAbsent(r.$1, () => {})
            .putIfAbsent(t.$1, () => [])
            .add(t.$2);
      } else if (p['type'] != 'series') {
        movieHist.add({'ids': {'imdb': r.$1}});
      }
    }
    final showHist = [
      for (final e in showMap.entries)
        {
          'ids': {'imdb': e.key},
          'seasons': [
            for (final s in e.value.entries)
              {
                'number': s.key,
                'episodes': [for (final n in s.value) {'number': n}]
              }
          ]
        }
    ];
    if (movieHist.isNotEmpty || showHist.isNotEmpty) {
      await _syncPost('history', {
        if (movieHist.isNotEmpty) 'movies': movieHist,
        if (showHist.isNotEmpty) 'shows': showHist,
      });
    }

    syncStatus.value = 'Library pushed at ' + _clock();
    return 'Pushed ${planShows.length + planMovies.length} watchlist, '
        '${movieHist.length} movies, ${showHist.length} shows.';
  }

  static Future<String> pullAll() async {
    syncStatus.value = 'Syncing…';
    await ensureFresh();
    final movies = (await _get('/sync/watched/movies'))['data'] as List;
    final shows = (await _get('/sync/watched/shows?extended=full'))['data'] as List;
    final watchlist = (await _get('/sync/watchlist'))['data'] as List;

    var nM = 0, nS = 0, nW = 0;
    for (final e in movies) {
      final imdb = e['movie']?['ids']?['imdb'];
      if (imdb == null) continue;
      Db.setStatus('movie', imdb, 'completed', name: e['movie']?['title']);
      Db.markWatched('movie', imdb, imdb, true);
      nM++;
    }
    var nEp = 0, nSe = 0;
    for (final e in shows) {
      final imdb = e['show']?['ids']?['imdb'];
      if (imdb == null) continue;
      // Map onto the item the app actually uses (kitsu ids, local
      // numbering) so episode ticks show up in the UI.
      final probe = await _localTarget('series', imdb, null, null);
      final localId = probe.$1;
      // Remove the ghost imdb-keyed duplicate created by older versions.
      if (localId != imdb) Db.items.delete('series|' + imdb);
      if (Db.itemStatus('series', localId) == null) {
        Db.setStatus('series', localId, 'watching',
            name: e['show']?['title']);
      }
      // Trakt omits season data on this endpoint - fetch the per-show
      // watched progress instead (per-episode completed flags).
      var seasonsList = e['seasons'] as List? ?? const [];
      if (seasonsList.isEmpty) {
        // Skip the fetch when this show's history hasn't changed since
        // the last sync - keeps large libraries cheap.
        final fingerprint =
            '${e['last_watched_at'] ?? ''}|${e['plays'] ?? ''}';
        final ckey = 'traktprog5|' + imdb;
        if (Db.meta.get(ckey) == fingerprint) {
          nS++;
          continue;
        }
        try {
          final prog = await _get('/shows/$imdb/progress/watched');
          for (final season
              in ((prog['data'] as Map?)?['seasons'] as List? ??
                  const [])) {
            nSe++;
            final seNum = (season['number'] as num?)?.toInt();
            for (final ep in (season['episodes'] as List? ?? const [])) {
              if (ep['completed'] != true) continue;
              final t = await _localTarget(
                  'series', imdb, seNum, (ep['number'] as num?)?.toInt());
              Db.markWatched('series', t.$1, t.$2, true);
              nEp++;
            }
          }
          // Every aired episode watched -> Completed. Only promotes from
          // Watching; a new season airing never demotes automatically.
          final airedN =
              ((prog['data'] as Map?)?['aired'] as num?)?.toInt() ?? 0;
          final doneN =
              ((prog['data'] as Map?)?['completed'] as num?)?.toInt() ?? 0;
          final st = Db.itemStatus('series', localId);
          final showStatus = '${e['show']?['status'] ?? ''}';
          final ended = showStatus == 'ended' || showStatus == 'canceled';
          // Nothing scheduled to watch next = finished, even if the
          // network calls the show "returning".
          final nextEp = (prog['data'] as Map?)?['next_episode'];
          // A next episode blocks completion only if it belongs to a
          // season already started (= next week's episode of a show
          // being followed). Announced future seasons - dated or stub -
          // don't count as something left to watch.
          var blocking = false;
          if (!ended && nextEp is Map && nextEp['first_aired'] != null) {
            final nSeason = (nextEp['season'] as num?)?.toInt();
            for (final season in ((prog['data'] as Map?)?['seasons']
                    as List? ??
                const [])) {
              if ((season['number'] as num?)?.toInt() != nSeason) continue;
              final eps = season['episodes'] as List? ?? const [];
              blocking =
                  eps.any((ep) => ep is Map && ep['completed'] == true);
              break;
            }
          }
          final finished = ended || !blocking;
          if (airedN > 0 && doneN >= airedN) {
            if (finished && (st == null || st == 'watching')) {
              Db.setStatus('series', localId, 'completed',
                  name: e['show']?['title']);
            } else if (!finished && st == 'completed') {
              // Caught up on an airing show = Watching, not Completed.
              Db.setStatus('series', localId, 'watching',
                  name: e['show']?['title']);
            }
          }
          // Only mark done if the episode map existed - otherwise retry
          // next sync, after hydration has cached this show's metadata.
          if (Db.cachedMeta('series', localId) != null) {
            await Db.meta.put(ckey, fingerprint);
          }
          nS++;
          continue;
        } catch (_) {/* fall back to inline data below */}
      }
      for (final season in seasonsList) {
        nSe++;
        final seNum = (season['number'] as num?)?.toInt();
        for (final ep in (season['episodes'] as List? ?? [])) {
          final t = await _localTarget(
              'series', imdb, seNum, (ep['number'] as num?)?.toInt());
          Db.markWatched('series', t.$1, t.$2, true);
          nEp++;
        }
      }
      nS++;
    }
    for (final e in watchlist) {
      final kind = e['type'];
      final ourType = kind == 'show' ? 'series' : (kind == 'movie' ? 'movie' : null);
      if (ourType == null) continue;
      final imdb = e[kind]?['ids']?['imdb'];
      if (imdb == null) continue;
      if (Db.itemStatus(ourType, imdb) == null) {
        Db.setStatus(ourType, imdb, 'plan', name: e[kind]?['title']);
        nW++;
      }
    }
    // Carry over partial positions watched elsewhere (Trakt playback).
    var nPos = 0, nSeen = 0;
    final pcts = <String>[];
    try {
      final c2 = client()!;
      final h2 = _headers(c2.$1, Db.setting('trakt_access'));
      // Trakt returns partial results on the bare endpoint - request
      // each type explicitly and combine.
      final list = <dynamic>[];
      for (final t in ['episodes', 'movies']) {
        final r = await http.get(
            Uri.parse('$_api/sync/playback/$t?limit=200'),
            headers: h2);
        if (r.statusCode < 300) {
          final b = jsonDecode(r.body);
          if (b is List) list.addAll(b);
        }
      }
      {
        for (final e in list) {
          nSeen++;
          final pct = (e['progress'] as num?)?.toDouble() ?? 0;
          if (pcts.length < 6) pcts.add(pct.toStringAsFixed(1));
          if (pct <= 0 || pct >= 99) continue;
          final pausedAt = DateTime.tryParse('${e['paused_at'] ?? ''}');
          final at = pausedAt == null
              ? null
              : pausedAt.millisecondsSinceEpoch ~/ 1000;
          if (e['movie'] != null) {
            final imdb = e['movie']?['ids']?['imdb'];
            if (imdb == null) continue;
            final t = await _localTarget('movie', imdb, null, null);
            Db.mergePct('movie', t.$1, t.$2, pct, at: at);
            nPos++;
          } else if (e['show'] != null && e['episode'] != null) {
            final imdb = e['show']?['ids']?['imdb'];
            if (imdb == null) continue;
            final se = (e['episode']?['season'] as num?)?.toInt();
            final ep = (e['episode']?['number'] as num?)?.toInt();
            final t = await _localTarget('series', imdb, se, ep);
            Db.mergePct('series', t.$1, t.$2, pct, at: at);
            nPos++;
          }
        }
      }
    } catch (_) {/* progress carry-over is best effort */}

    syncStatus.value = 'Synced at ' + _clock() +
        ' · ${shows.length} shows/$nSe seasons/$nEp episodes' +
        ' · playback $nSeen seen/$nPos merged'
        '${pcts.isEmpty ? '' : ' [${pcts.join('%, ')}%]'}';
    return 'Synced $nM movies, $nS shows, $nW watchlist items.';
  }
}
