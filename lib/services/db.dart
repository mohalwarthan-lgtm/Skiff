import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Local persistence. Hive is pure Dart (no native libraries to link),
/// which keeps the build bulletproof. Records are plain JSON-style maps.
class Db {
  /// Live UI text scale (0.9-1.3), applied app-wide.
  static final uiScale = ValueNotifier<double>(1.0);

  static late Box addons; // transportUrl -> {manifest, enabled}
  static late Box items; // "type|id" -> {id,type,name,poster,status,updatedAt}
  static late Box progress; // "type|itemId|videoId" -> {position,duration,watched,updatedAt}
  static late Box settings; // key -> value
  static late Box downloads; // "type|itemId|videoId" -> {path,subPaths,name,poster,videoTitle,size,status}
  static late Box meta; // "type|id" -> trimmed meta cached for offline use

  static Future<void> init() async {
    await Hive.initFlutter('skiff');
    addons = await Hive.openBox('addons');
    items = await Hive.openBox('items');
    progress = await Hive.openBox('progress');
    settings = await Hive.openBox('settings');
    uiScale.value =
        double.tryParse(setting('ui_scale') ?? '') ?? 1.0;
    downloads = await Hive.openBox('downloads');
    meta = await Hive.openBox('meta');
  }

  // ---------- Offline metadata cache ----------

  /// Cache the essentials of a title so Library / Continue Watching / Details
  /// render correctly with no internet.
  static void cacheMeta(String type, String id, Map m) {
    meta.put(itemKey(type, id), {
      'id': id,
      'type': type,
      'name': m['name'],
      'poster': m['poster'],
      'imdb_id': m['imdb_id'] ?? m['imdbId'],
      'logo': m['logo'],
      'cast': m['cast'],
      'background': m['background'],
      'description': m['description'],
      'year': m['year'],
      'runtime': m['runtime'],
      'imdbRating': m['imdbRating'],
      'genres': m['genres'],
      'videos': _canonicalVideos(id, m['videos'] as List? ?? const []),
    });
  }

  /// Some provider presets emit TWO rows for the same episode in
  /// different id dialects (one of them often nameless). Keep exactly one
  /// row per season+episode - preferring the item's own id dialect - and
  /// merge every field so no title or date is lost.
  static List<Map> _canonicalVideos(String itemId, List raw) {
    final lane = itemId.contains(':')
        ? itemId.substring(0, itemId.indexOf(':') + 1)
        : (itemId.startsWith('tt') ? 'tt' : '');
    final byEp = <String, Map>{};
    for (final v in raw) {
      if (v is! Map) continue;
      final row = {
        'id': v['id'],
        'title': v['title'],
        'name': v['name'],
        'season': v['season'],
        'episode': v['episode'],
        'released': v['released'],
      };
      final k = '${v['season']}|${v['episode']}';
      final prev = byEp[k];
      if (prev == null) {
        byEp[k] = row;
        continue;
      }
      // merge: never lose a name/title/date that one twin has
      for (final f in ['name', 'title', 'released']) {
        if (prev[f] == null && row[f] != null) prev[f] = row[f];
      }
      final prevOwn = '${prev['id']}'.startsWith(lane);
      final rowOwn = '${row['id']}'.startsWith(lane);
      final prevTitled = (prev['title'] ?? prev['name']) != null;
      final rowTitled = (row['title'] ?? row['name']) != null;
      if ((rowOwn && !prevOwn) ||
          (rowOwn == prevOwn && !prevTitled && rowTitled)) {
        prev['id'] = row['id'];
      }
    }
    final out = byEp.values.toList()
      ..sort((a, b) {
        final sa = (a['season'] as num?)?.toInt() ?? 0,
            sb = (b['season'] as num?)?.toInt() ?? 0;
        return sa != sb
            ? sa - sb
            : ((a['episode'] as num?)?.toInt() ?? 0) -
                ((b['episode'] as num?)?.toInt() ?? 0);
      });
    return out;
  }

  static Map? cachedMeta(String type, String id) =>
      meta.get(itemKey(type, id)) as Map?;

  /// Upsert display info without touching the shelf status.
  static void touchItem(String type, String id, {String? name, String? poster}) {
    final existing = item(type, id);
    if (existing == null) return; // don't create shelf entries implicitly
    items.put(itemKey(type, id), {
      ...existing,
      'name': name ?? existing['name'],
      'poster': poster ?? existing['poster'],
    });
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

  /// Remove from the library AND clear its progress rows, so it also
  /// disappears from Continue Watching instead of getting stuck there.
  static void removeItem(String type, String id) {
    items.delete(itemKey(type, id));
    final stale = progress.keys
        .where((k) => (k as String).startsWith('$type|$id|'))
        .toList();
    for (final k in stale) {
      progress.delete(k);
    }
  }

  /// Dismiss a single entry from Continue Watching.
  static void dismissContinue(String type, String itemId, String videoId) =>
      progress.delete(progKey(type, itemId, videoId));

  static List<Map> itemsByStatus(String? status) {
    final all = items.values.cast<Map>().toList()
      ..sort((a, b) => (b['updatedAt'] ?? 0).compareTo(a['updatedAt'] ?? 0));
    final filtered =
        status == null ? all : all.where((m) => m['status'] == status).toList();
    // Fill gaps from the offline meta cache so names/posters always show.
    return filtered.map((m) {
      if (m['name'] != null && m['poster'] != null) return m;
      final mc = cachedMeta(m['type'], m['id']);
      return {
        ...m,
        'name': m['name'] ?? mc?['name'],
        'poster': m['poster'] ?? mc?['poster'],
      };
    }).toList();
  }

  // ---------- Progress ----------

  static String progKey(String type, String itemId, String videoId) =>
      '$type|$itemId|$videoId';

  static Map? prog(String type, String itemId, String videoId) =>
      progress.get(progKey(type, itemId, videoId)) as Map?;

  static bool isWatched(String type, String itemId, String videoId) =>
      prog(type, itemId, videoId)?['watched'] == true;

  /// Merge a Trakt playback percentage (watched elsewhere; no absolute
  /// seconds known). The player resumes from it and Continue Watching
  /// shows it; real local playback overwrites it with exact seconds.
  static void mergePct(String type, String itemId, String videoId, double pct,
      {int? at}) {
    final prev = prog(type, itemId, videoId);
    if (prev?['watched'] == true) return;
    final stamp = at ?? now();
    final prevAt = (prev?['updatedAt'] ?? 0) as num;
    // Whoever watched most recently is the authority - EXCEPT that a
    // barely-started local row (created by just opening an episode)
    // never outranks a real position watched elsewhere.
    if (stamp < prevAt) {
      final pos = (prev?['position'] ?? 0) as num;
      final ppct = (prev?['pct'] ?? 0) as num;
      if (pos >= 60 || ppct >= 1) return; // local progress is real - keep
    }
    final merged = <dynamic, dynamic>{
      ...?prev,
      'itemId': itemId,
      'type': type,
      'videoId': videoId,
      'pct': pct,
      'updatedAt': stamp,
    }
      // Drop stale local seconds so the fresher Trakt position wins; the
      // next local playback writes exact seconds again with a newer stamp.
      ..remove('position')
      ..remove('duration');
    progress.put(progKey(type, itemId, videoId), merged);
  }

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
    final prev = prog(type, itemId, videoId);
    progress.put(progKey(type, itemId, videoId), {
      ...?prev,
      'itemId': itemId,
      'type': type,
      'videoId': videoId,
      'watched': watched,
      'updatedAt': now(),
    });
  }

  /// Most recent unfinished playback across the library.
  static List<Map> continueWatching({int limit = 20}) {
    final rows = progress.values
        .cast<Map>()
        .where((p) =>
            p['watched'] != true &&
            ((p['position'] ?? 0) > 60 || ((p['pct'] ?? 0) as num) > 0))
        .toList();
    // Like Trakt's Continue Watching: also surface the NEXT unwatched,
    // already-released episode of every show on the Watching shelf.
    final present = {for (final r in rows) '${r['type']}|${r['itemId']}'};
    for (final it in items.values.cast<Map>()) {
      if (it['type'] != 'series' || it['status'] != 'watching') continue;
      if (present.contains('series|${it['id']}')) continue;
      final meta = cachedMeta('series', it['id']);
      final vids = (meta?['videos'] as List? ?? [])
          .whereType<Map>()
          .where((v) => ((v['season'] as num?)?.toInt() ?? 0) > 0)
          .toList()
        ..sort((a, b) {
          final sa = (a['season'] as num).toInt(),
              sb = (b['season'] as num).toInt();
          return sa != sb
              ? sa - sb
              : ((a['episode'] as num?)?.toInt() ?? 0) -
                  ((b['episode'] as num?)?.toInt() ?? 0);
        });
      final anyWatched = vids
          .any((v) => isWatched('series', it['id'], '${v['id']}'));
      if (!anyWatched) continue; // not started - belongs on Home, not here
      Map? next;
      for (final v in vids) {
        if (isWatched('series', it['id'], '${v['id']}')) continue;
        final rel = DateTime.tryParse('${v['released'] ?? ''}');
        if (rel != null && rel.isAfter(DateTime.now())) continue;
        next = v;
        break;
      }
      if (next == null) continue; // fully caught up
      rows.add({
        'itemId': it['id'],
        'type': 'series',
        'videoId': '${next['id']}',
        'position': 0.0,
        'pct': 0.0,
        'upNext': true,
        'updatedAt': it['updatedAt'] ?? 0,
      });
    }
    rows.sort(
        (a, b) => (b['updatedAt'] ?? 0).compareTo(a['updatedAt'] ?? 0));
    return rows.take(limit).map((p) {
      final it = item(p['type'], p['itemId']);
      final mc = cachedMeta(p['type'], p['itemId']);
      return {
        ...p,
        'name': it?['name'] ?? mc?['name'],
        'poster': it?['poster'] ?? mc?['poster'],
      };
    }).toList();
  }

  // ---------- Settings ----------

  static String? setting(String key) => settings.get(key) as String?;
  static void setSetting(String key, String value) => settings.put(key, value);
  static void deleteSetting(String key) => settings.delete(key);
}
