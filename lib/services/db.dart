import 'package:hive_flutter/hive_flutter.dart';

/// Local persistence. Hive is pure Dart (no native libraries to link),
/// which keeps the build bulletproof. Records are plain JSON-style maps.
class Db {
  static late Box addons; // transportUrl -> {manifest, enabled}
  static late Box items; // "type|id" -> {id,type,name,poster,status,updatedAt}
  static late Box progress; // "type|itemId|videoId" -> {position,duration,watched,updatedAt}
  static late Box settings; // key -> value
  static late Box downloads; // "type|itemId|videoId" -> {path,subPaths,name,poster,videoTitle,size,status}

  static Future<void> init() async {
    await Hive.initFlutter('skiff');
    addons = await Hive.openBox('addons');
    items = await Hive.openBox('items');
    progress = await Hive.openBox('progress');
    settings = await Hive.openBox('settings');
    downloads = await Hive.openBox('downloads');
  }

  static int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  // ---------- Library ----------

  static String itemKey(String type, String id) => '$type|$id';

  static Map? item(String type, String id) =>
      (items.get(itemKey(type, id)) as Map?);

  static String? itemStatus(String type, String id) =>
      item(type, id)?['status'] as String?;

  static void setStatus(String type, String id, String status,
      {String? name, String? poster}) {
    final existing = item(type, id) ?? {};
    items.put(itemKey(type, id), {
      'id': id,
      'type': type,
      'name': name ?? existing['name'],
      'poster': poster ?? existing['poster'],
      'status': status,
      'updatedAt': now(),
    });
  }

  static void removeItem(String type, String id) =>
      items.delete(itemKey(type, id));

  static List<Map> itemsByStatus(String? status) {
    final all = items.values.cast<Map>().toList()
      ..sort((a, b) => (b['updatedAt'] ?? 0).compareTo(a['updatedAt'] ?? 0));
    if (status == null) return all;
    return all.where((m) => m['status'] == status).toList();
  }

  // ---------- Progress ----------

  static String progKey(String type, String itemId, String videoId) =>
      '$type|$itemId|$videoId';

  static Map? prog(String type, String itemId, String videoId) =>
      progress.get(progKey(type, itemId, videoId)) as Map?;

  static bool isWatched(String type, String itemId, String videoId) =>
      prog(type, itemId, videoId)?['watched'] == true;

  static void setProgress(
      String type, String itemId, String videoId, double position, double duration) {
    final watched = duration > 0 && position / duration >= 0.9;
    final prev = prog(type, itemId, videoId);
    progress.put(progKey(type, itemId, videoId), {
      'itemId': itemId,
      'type': type,
      'videoId': videoId,
      'position': position,
      'duration': duration,
      'watched': watched || (prev?['watched'] == true),
      'updatedAt': now(),
    });
    // Playing something moves it to Watching, unless it's already Completed.
    if (itemStatus(type, itemId) != 'completed') {
      setStatus(type, itemId, 'watching');
    }
  }

  static void markWatched(String type, String itemId, String videoId, bool watched) {
    final prev = prog(type, itemId, videoId) ?? {};
    progress.put(progKey(type, itemId, videoId), {
      'itemId': itemId,
      'type': type,
      'videoId': videoId,
      'position': prev['position'] ?? 0.0,
      'duration': prev['duration'] ?? 0.0,
      'watched': watched,
      'updatedAt': now(),
    });
  }

  /// Most recent unfinished playback across the library.
  static List<Map> continueWatching({int limit = 20}) {
    final rows = progress.values
        .cast<Map>()
        .where((p) => p['watched'] != true && (p['position'] ?? 0) > 60)
        .toList()
      ..sort((a, b) => (b['updatedAt'] ?? 0).compareTo(a['updatedAt'] ?? 0));
    return rows.take(limit).map((p) {
      final it = item(p['type'], p['itemId']);
      return {...p, 'name': it?['name'], 'poster': it?['poster']};
    }).toList();
  }

  // ---------- Settings ----------

  static String? setting(String key) => settings.get(key) as String?;
  static void setSetting(String key, String value) => settings.put(key, value);
  static void deleteSetting(String key) => settings.delete(key);
}
