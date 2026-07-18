import 'dart:convert';
import 'package:http/http.dart' as http;
import 'db.dart';

/// Stremio addon protocol client. Everything derives from a transport URL:
///   {base}/catalog/{type}/{id}[/{extra}].json
///   {base}/meta/{type}/{id}.json
///   {base}/stream/{type}/{id}.json
///   {base}/subtitles/{type}/{id}[/{extra}].json
/// Nothing here is specific to any addon — AIOMetadata, AIOStreams, or any
/// other protocol-compliant addon works identically.
class Addons {
  static Future<Map<String, dynamic>> _getJson(Uri url) async {
    final res = await http.get(url).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw 'HTTP ${res.statusCode} from ${url.host}';
    }
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  static String baseUrl(String transportUrl) {
    var b = transportUrl.trim();
    if (b.endsWith('/manifest.json')) {
      b = b.substring(0, b.length - '/manifest.json'.length);
    }
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  static String _extraSeg(Map<String, String> extra) => extra.entries
      .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
      .join('&');

  // ---------- Raw protocol calls ----------

  static Future<Map<String, dynamic>> fetchManifest(String transportUrl) async {
    final url = transportUrl.endsWith('manifest.json')
        ? transportUrl
        : '${baseUrl(transportUrl)}/manifest.json';
    return _getJson(Uri.parse(url));
  }

  static Future<List> fetchCatalog(String transportUrl, String type, String id,
      [Map<String, String> extra = const {}]) async {
    final base = baseUrl(transportUrl);
    final path = extra.isEmpty
        ? '$base/catalog/$type/${Uri.encodeComponent(id)}.json'
        : '$base/catalog/$type/${Uri.encodeComponent(id)}/${_extraSeg(extra)}.json';
    return (await _getJson(Uri.parse(path)))['metas'] as List? ?? [];
  }

  static Future<Map<String, dynamic>> fetchMeta(
      String transportUrl, String type, String id) async {
    final base = baseUrl(transportUrl);
    final json =
        await _getJson(Uri.parse('$base/meta/$type/${Uri.encodeComponent(id)}.json'));
    return json['meta'] as Map<String, dynamic>? ?? {};
  }

  static Future<List> fetchStreams(
      String transportUrl, String type, String id) async {
    final base = baseUrl(transportUrl);
    final json =
        await _getJson(Uri.parse('$base/stream/$type/${Uri.encodeComponent(id)}.json'));
    return json['streams'] as List? ?? [];
  }

  static Future<List> fetchSubtitles(
      String transportUrl, String type, String id) async {
    final base = baseUrl(transportUrl);
    final json = await _getJson(
        Uri.parse('$base/subtitles/$type/${Uri.encodeComponent(id)}.json'));
    return json['subtitles'] as List? ?? [];
  }

  // ---------- Installed addon management ----------

  static Future<Map> install(String url) async {
    final normalized = url.trim().replaceFirst(RegExp(r'^stremio://'), 'https://');
    final manifest = await fetchManifest(normalized);
    final key = normalized.endsWith('manifest.json')
        ? normalized
        : '${baseUrl(normalized)}/manifest.json';
    final record = {'transportUrl': key, 'manifest': manifest, 'enabled': true};
    Db.addons.put(key, record);
    return record;
  }

  static List<Map> installed() => Db.addons.values.cast<Map>().toList();

  static List<Map> enabled() =>
      installed().where((a) => a['enabled'] == true).toList();

  /// Does a manifest serve `resource` for `type` and `id`? Honors both the
  /// short ("stream") and object ({name, types, idPrefixes}) resource forms.
  static bool supports(Map manifest, String resource, String type, String id) {
    bool prefixOk(dynamic prefixes) {
      if (prefixes is List && prefixes.isNotEmpty) {
        return prefixes.any((p) => id.startsWith(p as String));
      }
      return true;
    }

    final types = (manifest['types'] as List?) ?? [];
    for (final r in (manifest['resources'] as List?) ?? []) {
      if (r is String) {
        if (r == resource && types.contains(type) && prefixOk(manifest['idPrefixes'])) {
          return true;
        }
      } else if (r is Map && r['name'] == resource) {
        final rTypes = r['types'] as List?;
        final typeOk = (rTypes != null && rTypes.isNotEmpty)
            ? rTypes.contains(type)
            : types.contains(type);
        if (typeOk && prefixOk(r['idPrefixes'] ?? manifest['idPrefixes'])) {
          return true;
        }
      }
    }
    return false;
  }

  // ---------- Aggregation across enabled addons ----------

  /// First enabled addon that can serve meta for this id wins.
  static Future<Map<String, dynamic>> metaFor(String type, String id) async {
    String lastErr = 'No installed add-on provides metadata for $type/$id';
    for (final a in enabled()) {
      final m = a['manifest'] as Map;
      if (supports(m, 'meta', type, id)) {
        try {
          return await fetchMeta(a['transportUrl'], type, id);
        } catch (e) {
          lastErr = '${m['name']}: $e';
        }
      }
    }
    throw lastErr;
  }

  /// Streams from every enabled stream addon, grouped by addon name.
  static Future<List<Map>> streamsFor(String type, String id) async {
    final out = <Map>[];
    for (final a in enabled()) {
      final m = a['manifest'] as Map;
      if (supports(m, 'stream', type, id)) {
        try {
          final s = await fetchStreams(a['transportUrl'], type, id);
          if (s.isNotEmpty) out.add({'addon': m['name'], 'streams': s});
        } catch (_) {/* one addon failing shouldn't sink the rest */}
      }
    }
    return out;
  }

  /// Search every capable catalog but keep results grouped per catalog,
  /// so a metadata add-on's own separation (Movies / Series / Anime ...)
  /// carries straight through, exactly like Stremio renders it.
  static Future<List<Map>> searchGrouped(String query) async {
    final futures = <Future<Map?>>[];
    for (final a in enabled()) {
      final m = a['manifest'] as Map;
      for (final c in (m['catalogs'] as List? ?? [])) {
        final hasSearch = ((c['extra'] as List?) ?? [])
            .any((e) => e is Map && e['name'] == 'search');
        if (!hasSearch) continue;
        futures.add(() async {
          try {
            final items = await fetchCatalog(
                a['transportUrl'], c['type'], c['id'], {'search': query});
            if (items.isEmpty) return null;
            final seen = <String>{};
            final rows = <Map>[];
            for (final it in items) {
              if (it is Map &&
                  it['id'] != null &&
                  seen.add('${it['type']}|${it['id']}')) {
                rows.add(it.cast<String, dynamic>());
              }
            }
            return {
              'title': '${c['name'] ?? c['id']}',
              'addon': '${m['name'] ?? ''}',
              'items': rows,
            };
          } catch (_) {
            return null;
          }
        }());
      }
    }
    return (await Future.wait(futures)).whereType<Map>().toList();
  }

  static Future<List<Map>> subtitlesFor(String type, String id) async {
    final out = <Map>[];
    for (final a in enabled()) {
      final m = a['manifest'] as Map;
      if (supports(m, 'subtitles', type, id)) {
        try {
          for (final s in await fetchSubtitles(a['transportUrl'], type, id)) {
            if (s is Map && s['url'] != null) out.add(s.cast<String, dynamic>());
          }
        } catch (_) {}
      }
    }
    return out;
  }
}
