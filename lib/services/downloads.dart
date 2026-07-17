import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'db.dart';
import 'net.dart';

/// Offline downloads for travel: saves the video file plus every addon
/// subtitle (.srt/.vtt) next to it, tracked in the Downloads tab.
class DownloadTask extends ChangeNotifier {
  final String key;
  double progress = 0; // 0..1, or -1 when size is unknown
  int received = 0;
  String status = 'downloading'; // downloading | done | error | cancelled
  String? error;
  bool _cancel = false;

  DownloadTask(this.key);
  void cancel() => _cancel = true;
}

class Downloads {
  static final Map<String, DownloadTask> active = {};
  static final ValueNotifier<int> revision = ValueNotifier(0); // UI refresh tick

  static String key(String type, String itemId, String videoId) =>
      '$type|$itemId|$videoId';

  static Map? record(String type, String itemId, String videoId) =>
      Db.downloads.get(key(type, itemId, videoId)) as Map?;

  static bool isDownloaded(String type, String itemId, String videoId) =>
      record(type, itemId, videoId)?['status'] == 'done';

  static List<Map> all() => Db.downloads.values.cast<Map>().toList()
    ..sort((a, b) => (b['createdAt'] ?? 0).compareTo(a['createdAt'] ?? 0));

  static Future<Directory> _dirFor(String itemId) async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}/downloads/$itemId');
    await dir.create(recursive: true);
    return dir;
  }

  static String _safe(String s) => s.replaceAll(RegExp(r'[^\w\-. ]'), '_');

  /// Start a download. [subs] are addon subtitles: [{url, lang}, ...].
  static Future<void> start({
    required String type,
    required String itemId,
    required String videoId,
    required String url,
    required String displayName, // e.g. show name
    required String videoTitle, // e.g. "S1 E3 · The Title"
    String? poster,
    Map<String, String> headers = const {},
    List<Map> subs = const [],
  }) async {
    final k = key(type, itemId, videoId);
    if (active.containsKey(k)) return;
    final task = DownloadTask(k);
    active[k] = task;
    revision.value++;

    try {
      final dir = await _dirFor(itemId);
      final base = _safe(videoId);

      // Subtitles first: tiny files, and worth having even if video fails.
      final subPaths = <Map>[];
      for (var i = 0; i < subs.length && i < 12; i++) {
        try {
          final sUrl = subs[i]['url'] as String;
          final ext = sUrl.toLowerCase().contains('.vtt') ? 'vtt' : 'srt';
          final path = '${dir.path}/$base.${subs[i]['lang'] ?? 'sub$i'}.$i.$ext';
          final res = await http.get(Uri.parse(sUrl));
          if (res.statusCode == 200) {
            await File(path).writeAsBytes(res.bodyBytes);
            subPaths.add({'path': path, 'lang': subs[i]['lang']});
          }
        } catch (_) {}
      }

      // Video: streamed to disk with progress.
      final videoPath = '${dir.path}/$base.mkv';
      final client = http.Client();
      final req = http.Request('GET', Uri.parse(url))
        ..headers.addAll(Net.withUa(headers));
      final res = await client.send(req);
      if (res.statusCode >= 400) throw 'HTTP ${res.statusCode}';
      final total = res.contentLength ?? -1;
      final sink = File(videoPath).openWrite();
      try {
        await for (final chunk in res.stream) {
          if (task._cancel) throw 'cancelled';
          sink.add(chunk);
          task.received += chunk.length;
          task.progress = total > 0 ? task.received / total : -1;
          task.notifyListeners();
        }
      } finally {
        await sink.close();
        client.close();
      }

      Db.downloads.put(k, {
        'type': type,
        'itemId': itemId,
        'videoId': videoId,
        'name': displayName,
        'videoTitle': videoTitle,
        'poster': poster,
        'path': videoPath,
        'subs': subPaths,
        'size': task.received,
        'status': 'done',
        'createdAt': Db.now(),
      });
      task.status = 'done';
    } catch (e) {
      task.status = e == 'cancelled' ? 'cancelled' : 'error';
      task.error = '$e';
      // Remove partial video file.
      try {
        final dir = await _dirFor(itemId);
        final f = File('${dir.path}/${_safe(videoId)}.mkv');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    } finally {
      task.notifyListeners();
      active.remove(k);
      revision.value++;
    }
  }

  static Future<void> delete(String type, String itemId, String videoId) async {
    final rec = record(type, itemId, videoId);
    if (rec != null) {
      try {
        final f = File(rec['path']);
        if (await f.exists()) await f.delete();
        for (final s in (rec['subs'] as List? ?? [])) {
          final sf = File(s['path']);
          if (await sf.exists()) await sf.delete();
        }
      } catch (_) {}
      Db.downloads.delete(key(type, itemId, videoId));
      revision.value++;
    }
  }
}
