import 'package:flutter/material.dart';
import '../services/db.dart';
import '../services/downloads.dart';
import 'player_screen.dart';

/// "Downloaded titles" — everything saved for offline, playable without
/// internet, with active downloads shown at the top.
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  String _size(int bytes) {
    if (bytes > 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
    if (bytes > 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: Downloads.revision,
      builder: (context, _, __) {
        final done = Downloads.all().where((d) => d['status'] == 'done').toList();
        final active = Downloads.active.values.toList();

        return ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const Text('Downloads',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            if (active.isNotEmpty) ...[
              const Text('DOWNLOADING',
                  style: TextStyle(fontSize: 12, letterSpacing: 1.5)),
              for (final task in active)
                AnimatedBuilder(
                  animation: task,
                  builder: (_, __) => ListTile(
                    title: Text(task.key.split('|').last),
                    subtitle: task.progress >= 0
                        ? LinearProgressIndicator(value: task.progress)
                        : const LinearProgressIndicator(),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(_size(task.received)),
                      IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Cancel',
                          onPressed: task.cancel),
                    ]),
                  ),
                ),
              const Divider(height: 30),
            ],
            if (done.isEmpty && active.isEmpty)
              const Padding(
                padding: EdgeInsets.all(60),
                child: Center(
                    child: Text(
                        'Nothing downloaded yet.\nOn any title, open a stream '
                        'and hit the download icon — the episode and its '
                        'subtitles will be saved here for offline watching.',
                        textAlign: TextAlign.center)),
              ),
            for (final d in done)
              Card(
                child: ListTile(
                  leading: d['poster'] != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.network(d['poster'],
                              width: 42, height: 60, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.movie_outlined)))
                      : const Icon(Icons.movie_outlined),
                  title: Text(d['name'] ?? d['itemId']),
                  subtitle: Text(
                      '${d['videoTitle'] ?? d['videoId']}  ·  ${_size(d['size'] ?? 0)}'
                      '${((d['subs'] as List?)?.isNotEmpty ?? false) ? '  ·  ${(d['subs'] as List).length} subtitle file(s)' : ''}'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      icon: const Icon(Icons.play_arrow),
                      tooltip: 'Play offline',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PlayerScreen(
                            url: d['path'],
                            title: '${d['name']} — ${d['videoTitle']}',
                            type: d['type'],
                            itemId: d['itemId'],
                            videoId: d['videoId'],
                            localSubs: [
                              for (final s in (d['subs'] as List? ?? []))
                                {'path': s['path'], 'lang': s['lang']}
                            ],
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Delete download',
                      onPressed: () => Downloads.delete(
                          d['type'], d['itemId'], d['videoId']),
                    ),
                  ]),
                ),
              ),
          ],
        );
      },
    );
  }
}
