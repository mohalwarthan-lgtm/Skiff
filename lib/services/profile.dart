import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'db.dart';

/// Portable profile: one JSON blob carrying add-ons, library, progress,
/// settings, and the offline metadata cache. Export it on one device,
/// import it on another (Windows, Android, anything Flutter runs on) and
/// Skiff comes up identical. Downloads are excluded (paths are per-device).
class Profile {
  static String exportJson() => jsonEncode({
        'version': 1,
        'app': 'skiff',
        'exportedAt': DateTime.now().toIso8601String(),
        'addons': _stringKeys(Db.addons.toMap()),
        'items': _stringKeys(Db.items.toMap()),
        'progress': _stringKeys(Db.progress.toMap()),
        'settings': _stringKeys(Db.settings.toMap()),
        'meta': _stringKeys(Db.meta.toMap()),
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
    Future<void> apply(String key, dynamic box) async {
      final section = data[key];
      if (section is Map) {
        for (final e in section.entries) {
          await box.put(e.key, e.value);
          n++;
        }
      }
    }

    await apply('addons', Db.addons);
    await apply('items', Db.items);
    await apply('progress', Db.progress);
    await apply('settings', Db.settings);
    await apply('meta', Db.meta);
    return 'Imported $n records. Add-ons, library, progress, and settings are in.';
  }
}
