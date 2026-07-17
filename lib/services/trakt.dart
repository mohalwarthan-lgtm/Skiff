import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import 'db.dart';

/// Trakt.tv: device-code login, scrobbling, and two-way sync.
/// Local -> Trakt: shelf changes push to watchlist/history immediately.
/// Trakt -> local: watched history + watchlist pulled on start and periodically.
class Trakt {
  static const _api = 'https://api.trakt.tv';

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

  /// Movies: videoId "tt0111161". Episodes: "tt0944947:3:9".
  static Map<String, dynamic> _scrobbleBody(
      String itemType, String videoId, double progressPct) {
    if (itemType == 'series') {
      final parts = videoId.split(':');
      if (parts.length >= 3) {
        return {
          'show': {'ids': {'imdb': parts[0]}},
          'episode': {
            'season': int.tryParse(parts[1]) ?? 0,
            'number': int.tryParse(parts[2]) ?? 0,
          },
          'progress': progressPct,
        };
      }
    }
    return {
      'movie': {'ids': {'imdb': videoId.split(':').first}},
      'progress': progressPct,
    };
  }

  /// action: start | pause | stop. Fire-and-forget safe: throws only strings.
  static Future<void> scrobble(
      String action, String itemType, String videoId, double pct) async {
    if (!connected) return;
    final c = client()!;
    await http.post(Uri.parse('$_api/scrobble/$action'),
        headers: _headers(c.$1, Db.setting('trakt_access')),
        body: jsonEncode(_scrobbleBody(itemType, videoId, pct)));
  }

  // ---------- Push (local -> Trakt) ----------

  static Future<void> _syncPost(String path, Map body) async {
    if (!connected) return;
    try {
      await ensureFresh();
      final c = client()!;
      await http.post(Uri.parse('$_api/sync/$path'),
          headers: _headers(c.$1, Db.setting('trakt_access')),
          body: jsonEncode(body));
    } catch (_) {/* best-effort */}
  }

  static Map _watchlistBody(String type, String id) => {
        type == 'series' ? 'shows' : 'movies': [
          {'ids': {'imdb': id}}
        ]
      };

  static Map _historyBody(String type, String videoId) {
    if (type == 'series') {
      final p = videoId.split(':');
      if (p.length >= 3) {
        return {
          'shows': [
            {
              'ids': {'imdb': p[0]},
              'seasons': [
                {
                  'number': int.tryParse(p[1]) ?? 0,
                  'episodes': [
                    {'number': int.tryParse(p[2]) ?? 0}
                  ]
                }
              ]
            }
          ]
        };
      }
    }
    return {
      'movies': [
        {'ids': {'imdb': videoId.split(':').first}}
      ]
    };
  }

  static void pushStatus(String type, String id, String status) {
    if (status == 'plan') {
      _syncPost('watchlist', _watchlistBody(type, id));
    } else {
      _syncPost('watchlist/remove', _watchlistBody(type, id));
      if (status == 'completed' && type == 'movie') {
        _syncPost('history', _historyBody(type, id));
      }
    }
  }

  static void pushWatched(String type, String videoId, bool watched) {
    _syncPost(watched ? 'history' : 'history/remove', _historyBody(type, videoId));
  }

  // ---------- Pull (Trakt -> local) ----------

  static Future<Map<String, dynamic>> _get(String path) async {
    final c = client()!;
    final res = await http.get(Uri.parse('$_api$path'),
        headers: _headers(c.$1, Db.setting('trakt_access')));
    if (res.statusCode != 200) throw 'Trakt $path: HTTP ${res.statusCode}';
    return {'data': jsonDecode(res.body)};
  }

  static Future<String> pullAll() async {
    await ensureFresh();
    final movies = (await _get('/sync/watched/movies'))['data'] as List;
    final shows = (await _get('/sync/watched/shows'))['data'] as List;
    final watchlist = (await _get('/sync/watchlist'))['data'] as List;

    var nM = 0, nS = 0, nW = 0;
    for (final e in movies) {
      final imdb = e['movie']?['ids']?['imdb'];
      if (imdb == null) continue;
      Db.setStatus('movie', imdb, 'completed', name: e['movie']?['title']);
      Db.markWatched('movie', imdb, imdb, true);
      nM++;
    }
    for (final e in shows) {
      final imdb = e['show']?['ids']?['imdb'];
      if (imdb == null) continue;
      // Don't clobber an explicit local shelf choice.
      if (Db.itemStatus('series', imdb) == null) {
        Db.setStatus('series', imdb, 'watching', name: e['show']?['title']);
      }
      for (final season in (e['seasons'] as List? ?? [])) {
        for (final ep in (season['episodes'] as List? ?? [])) {
          Db.markWatched('series', imdb,
              '$imdb:${season['number']}:${ep['number']}', true);
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
    return 'Synced $nM movies, $nS shows, $nW watchlist items.';
  }
}
