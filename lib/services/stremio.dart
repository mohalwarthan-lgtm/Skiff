import 'dart:convert';
import 'package:http/http.dart' as http;

/// Stremio account client: log in, read the add-on collection, return the
/// third-party install URLs. The password is never stored.
class Stremio {
  static const _api = 'https://api.strem.io/api';

  static Future<String> login(String email, String password) async {
    final res = await http.post(Uri.parse('$_api/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email.trim(), 'password': password}));
    final data = jsonDecode(res.body);
    final key = data?['result']?['authKey'];
    if (res.statusCode >= 300 || key == null) {
      final err = data?['error']?['message'] ?? 'login failed';
      throw 'Stremio: $err';
    }
    return key as String;
  }

  /// Third-party add-on transport URLs from the account's collection
  /// (Stremio's own built-in add-ons are skipped).
  static Future<List<String>> addonUrls(String authKey) async {
    final res = await http.post(Uri.parse('$_api/addonCollectionGet'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'type': 'AddonCollectionGet',
          'authKey': authKey,
          'update': true,
        }));
    final data = jsonDecode(res.body);
    final addons = data?['result']?['addons'];
    if (res.statusCode >= 300 || addons is! List) {
      throw 'Stremio: could not read the add-on collection.';
    }
    final urls = <String>[];
    for (final a in addons) {
      if (a is! Map) continue;
      final url = a['transportUrl'];
      final flags = a['flags'] as Map? ?? const {};
      if (url is String && url.isNotEmpty && flags['official'] != true) {
        urls.add(url);
      }
    }
    return urls;
  }
}
