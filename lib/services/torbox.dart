import 'dart:convert';
import 'package:http/http.dart' as http;
import 'db.dart';

/// TorBox handles torrents server-side, so Skiff never runs a torrent engine.
/// When an addon returns a raw infoHash (P2P-only source), we ask TorBox to
/// fetch it and hand back an ordinary HTTPS link — which then streams and
/// downloads exactly like any debrid/usenet stream.
///
/// Requires the user's TorBox API key (Settings). Endpoint shapes follow the
/// public TorBox API docs; if TorBox revises them, this is the only file
/// to touch.
class TorBox {
  static const _api = 'https://api.torbox.app/v1/api';

  static String? get apiKey {
    final k = Db.setting('torbox_api_key');
    return (k == null || k.isEmpty) ? null : k;
  }

  static Map<String, String> get _auth => {'Authorization': 'Bearer $apiKey'};

  /// Resolve an infoHash (+ optional file index) to a direct HTTPS URL.
  /// Cached torrents resolve in seconds; uncached ones are queued on TorBox
  /// and we wait up to [timeout] for them to become ready.
  static Future<String> resolve(String infoHash, int? fileIdx,
      {Duration timeout = const Duration(minutes: 3)}) async {
    if (apiKey == null) {
      throw 'This stream is torrent-only with no resolver available. '
          'Pick one of the AIOStreams entries instead - your debrid services '
          'are configured there and those streams play directly.';
    }

    // 1) Ask TorBox to add the torrent (idempotent if it already exists).
    final create = await http.post(
      Uri.parse('$_api/torrents/createtorrent'),
      headers: _auth,
      body: {'magnet': 'magnet:?xt=urn:btih:$infoHash', 'seed': '1', 'allow_zip': 'false'},
    );
    if (create.statusCode >= 400) {
      throw 'TorBox rejected the torrent (HTTP ${create.statusCode}).';
    }

    // 2) Poll the torrent list until our hash is downloaded.
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final listRes = await http.get(
          Uri.parse('$_api/torrents/mylist?bypass_cache=true'),
          headers: _auth);
      if (listRes.statusCode == 200) {
        final data = jsonDecode(listRes.body)['data'];
        final torrents = (data is List) ? data : <dynamic>[];
        final match = torrents.cast<Map?>().firstWhere(
              (t) =>
                  (t?['hash'] as String?)?.toLowerCase() ==
                  infoHash.toLowerCase(),
              orElse: () => null,
            );
        if (match != null && match['download_finished'] == true) {
          // 3) Request a download link for the wanted file.
          final files = (match['files'] as List?) ?? [];
          final fileId = _pickFile(files, fileIdx);
          final dl = await http.get(
              Uri.parse(
                  '$_api/torrents/requestdl?token=$apiKey&torrent_id=${match['id']}&file_id=$fileId'),
              headers: _auth);
          if (dl.statusCode == 200) {
            final url = jsonDecode(dl.body)['data'];
            if (url is String && url.isNotEmpty) return url;
          }
          throw 'TorBox did not return a download link (HTTP ${dl.statusCode}).';
        }
      }
      await Future.delayed(const Duration(seconds: 5));
    }
    throw 'TorBox is still fetching this torrent — try again in a few minutes.';
  }

  /// Prefer the addon's fileIdx; otherwise the largest video-looking file.
  static dynamic _pickFile(List files, int? fileIdx) {
    if (files.isEmpty) return fileIdx ?? 0;
    if (fileIdx != null && fileIdx >= 0 && fileIdx < files.length) {
      return files[fileIdx]['id'] ?? fileIdx;
    }
    files.sort((a, b) => ((b['size'] ?? 0) as num).compareTo((a['size'] ?? 0) as num));
    return files.first['id'] ?? 0;
  }
}
