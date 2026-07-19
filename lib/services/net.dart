import 'package:http/http.dart' as http;

/// Resolves a stream URL to its final direct form: follows redirects and
/// resolver text responses so the player always gets a playable link.
class Net {
  /// A browser-like UA defeats naive client filtering on resolver hosts.
  static const ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Skiff/0.2';

  static Map<String, String> withUa(Map<String, String> headers) => {
        if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent'))
          'User-Agent': ua,
        ...headers,
      };

  static Future<String> finalUrl(String url,
      [Map<String, String> headers = const {}]) async {
    final client = http.Client();
    try {
      var current = url;
      for (var hop = 0; hop < 6; hop++) {
        final req = http.Request('GET', Uri.parse(current))
          ..followRedirects = false
          ..headers.addAll({
            ...withUa(headers),
            'Range': 'bytes=0-2047', // keep probes tiny on real media
            'Accept': '*/*',
          });
        final res = await client.send(req);

        // Redirect: follow manually so we end up with the last hop's URL.
        final loc = res.headers['location'];
        if (const [301, 302, 303, 307, 308].contains(res.statusCode) &&
            loc != null) {
          current = Uri.parse(current).resolve(loc).toString();
          continue;
        }

        if (res.statusCode >= 400) {
          throw 'HTTP ${res.statusCode} from ${Uri.parse(current).host}';
        }

        // Only clearly textual answers are treated as resolver responses;
        // anything else (video/*, octet-stream, HLS playlists, missing
        // content type) is handed straight to the player.
        final ct = (res.headers['content-type'] ?? '').toLowerCase();
        final isTexty = ct.startsWith('text/plain') ||
            ct.startsWith('text/html') ||
            ct.contains('json');

        if (res.statusCode == 200 && isTexty) {
          final bytes = <int>[];
          await for (final chunk in res.stream) {
            bytes.addAll(chunk);
            if (bytes.length > 16384) break;
          }
          final body = String.fromCharCodes(bytes);
          final match = RegExp(r'https?://\S+').firstMatch(body);
          if (match != null) {
            var found = match.group(0)!;
            // Trim trailing quote/bracket junk from HTML or JSON context.
            const stop = '"<>)]}\',';
            while (found.isNotEmpty && stop.contains(found[found.length - 1])) {
              found = found.substring(0, found.length - 1);
            }
            if (found != current) {
              current = found;
              continue;
            }
          }
          final snippet =
              body.length > 160 ? body.substring(0, 160) : body;
          throw 'Resolver at ${Uri.parse(current).host} returned no media '
              'link ($snippet)';
        }

        return current;
      }
      throw 'Too many redirect hops resolving the stream.';
    } finally {
      client.close();
    }
  }
}
