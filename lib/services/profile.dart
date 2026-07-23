import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'addons.dart';
import 'db.dart';

/// Portable profile: add-on URLs, library, progress, settings, and Trakt
/// login in one JSON file. Device-specific paths and downloads stay local.
class Profile {
  /// Per-device settings; they never travel inside a profile. Interface
  /// scale belongs here too: a value that suits a desktop monitor wrecks
  /// a phone's layout.
  static const _deviceKeys = {'download_dir', 'cache_dir', 'ui_scale'};

  static String exportJson() => jsonEncode({
        'version': 2,
        'app': 'skiff',
        'exportedAt': DateTime.now().toIso8601String(),
        // Just the install URLs - small, readable, and manifests are
        // re-fetched fresh on import.
        'addonUrls': [
          for (final a in Db.addons.values.cast<Map>()) a['transportUrl']
        ],
        'items': _stringKeys(Db.items.toMap()),
        'progress': _stringKeys(Db.progress.toMap()),
        'settings': _stringKeys(Db.settings.toMap())
          ..removeWhere((k, v) => _deviceKeys.contains(k)),
      });

  static Map<String, dynamic> _stringKeys(Map m) =>
      m.map((k, v) => MapEntry('$k', v));

  /// Writes the profile next to the user's downloads (or documents) and
  /// returns the full path.
  static Future<String> exportToFile() async {
    final dir = await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    final file = File(
        '${dir.path}/skiff-profile-${DateTime.now().toIso8601String().split('T').first}.json');
    await file.writeAsString(exportJson());
    return file.path;
  }

  /// Accepts either raw profile JSON or a path to a profile file.
  static Future<String> import(String input) async {
    var text = input.trim();
    if (!text.startsWith('{')) {
      final f = File(text);
      if (!await f.exists()) {
        throw 'That is neither profile JSON nor a file path that exists.';
      }
      text = await f.readAsString();
    }
    final data = jsonDecode(text);
    if (data is! Map || data['app'] != 'skiff') {
      throw 'This does not look like a SkiffBox profile.';
    }
    var n = 0;
    var installed = 0;
    // v2 profiles carry add-on URLs; re-install each (manifest re-fetched).
    final urls = data['addonUrls'];
    if (urls is List) {
      for (final u in urls) {
        if (u is! String || u.isEmpty) continue;
        try {
          await Addons.install(u);
          installed++;
        } catch (_) {/* dead addon URL - skip, keep importing the rest */}
      }
    }
    Future<void> apply(String key, dynamic box) async {
      final section = data[key];
      if (section is Map) {
        for (final e in section.entries) {
          if (key == 'settings' && _deviceKeys.contains(e.key)) continue;
          await box.put(e.key, e.value);
          n++;
        }
      }
    }

    await apply('addons', Db.addons); // legacy v1 profiles
    await apply('items', Db.items);
    await apply('progress', Db.progress);
    await apply('settings', Db.settings);
    await apply('meta', Db.meta); // legacy v1 profiles
    return 'Imported $n records'
        '${installed > 0 ? ' and $installed add-ons' : ''}. '
        'Library, progress, and settings are in.';
  }
}
