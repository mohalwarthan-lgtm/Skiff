import 'package:flutter/material.dart';
import '../services/db.dart';
import '../services/downloads.dart';
import 'player_screen.dart';

/// Downloads — grouped like the library: one card per title, episodes
/// stacked inside, with the cached poster and name. Active downloads on top.
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  String _size(int bytes) {
    if (bytes > 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
    if (bytes > 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';
    return '$bytes B';
  }

  /// Sort episode records by season, then episode (parsed from videoId).
  int _episodeCompare(Map a, Map b) {
    List<int> se(Map d) {
      final parts = (d['videoId'] as String).split(':');
      if (parts.length >= 3) {
        return [int.tryParse(parts[1]) ?? 0, int.tryParse(parts[2]) ?? 0];
      }
      return [0, 0];
    }

    final sa = se(a), sb = se(b);
    return sa[0] != sb[0] ? sa[0] - sb[0] : sa[1] - sb[1];
  }

  Widget _episodeTile(BuildContext context, Map d) {
    return ListTile(
      dense: true,
      title: Text(d['videoTitle'] ?? d['videoId']),
      subtitle: Text(_size(d['size'] ?? 0)),
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
          onPressed: () =>
              Downloads.delete(d['type'], d['itemId'], d['videoId']),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: Downloads.revision,
      builder: (context, _, __) {
        final done =
            Downloads.all().where((d) => d['status'] == 'done').toList();
        final active = Downloads.active.values.toList();
        final waiting = List<Map<String, dynamic>>.from(Downloads.queued);

        // Group by title; fall back to the offline meta cache for display.
        final groups = <String, List<Map>>{};
        for (final d in done) {
          groups.putIfAbsent('${d['type']}|${d['itemId']}', () => []).add(d);
        }

        final busy = active.isNotEmpty || waiting.isNotEmpty;
        return ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const Text('Downloads',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            if (active.isNotEmpty) ...[
              if (busy)

                Padding(

                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),

                  child: Row(children: [

                    Text('${active.length} downloading · ${waiting.length} queued',

                        style: const TextStyle(fontSize: 12, color: Colors.white54)),

                    const Spacer(),

                    TextButton.icon(

                      icon: const Icon(Icons.stop_circle_outlined, size: 18),

                      label: const Text('Stop all'),

                      onPressed: Downloads.cancelAll,

                    ),

                  ]),

                ),

              if (waiting.isNotEmpty) ...[

                const Padding(

                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),

                  child: Text('QUEUED',

                      style: TextStyle(fontSize: 12, letterSpacing: 1.5)),

                ),

                for (final j in waiting)

                  ListTile(

                    dense: true,

                    leading: const Icon(Icons.schedule, size: 18),

                    title: Text('${j['label'] ?? j['key']}',

                        maxLines: 1, overflow: TextOverflow.ellipsis),

                    trailing: IconButton(

                      icon: const Icon(Icons.close, size: 18),

                      tooltip: 'Remove from queue',

                      onPressed: () => Downloads.unqueue('${j['key']}'),

                    ),

                  ),

              ],

              const Text('DOWNLOADING',
                  style: TextStyle(fontSize: 12, letterSpacing: 1.5)),
              for (final task in active)
                AnimatedBuilder(
                  animation: task,
                  builder: (_, __) => ListTile(
                    title: Text(task.label.isEmpty
                        ? task.key.split('|').last
                        : task.label),
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
            if (groups.isEmpty && active.isEmpty)
              const Padding(
                padding: EdgeInsets.all(60),
                child: Center(
                    child: Text(
                        'Nothing downloaded yet.\nOn any title, open a stream '
                        'and hit the download icon — the episode and its '
                        'subtitles will be saved here for offline watching.',
                        textAlign: TextAlign.center)),
              ),
            for (final entry in groups.entries)
              Builder(builder: (context) {
                final recs = entry.value..sort(_episodeCompare);
                final first = recs.first;
                final type = first['type'] as String;
                final itemId = first['itemId'] as String;
                final cached = Db.cachedMeta(type, itemId);
                final name =
                    first['name'] ?? cached?['name'] ?? itemId;
                final poster = first['poster'] ?? cached?['poster'];
                final total =
                    recs.fold<int>(0, (t, d) => t + ((d['size'] ?? 0) as int));
                final leading = poster != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.network(poster,
                            width: 42, height: 60, fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.movie_outlined)))
                    : const Icon(Icons.movie_outlined);

                // A movie (single file, no episode id) stays a flat tile.
                if (type == 'movie' && recs.length == 1) {
                  final d = first;
                  return Card(
                    child: ListTile(
                      leading: leading,
                      title: Text(name),
                      subtitle: Text(_size(d['size'] ?? 0)),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          icon: const Icon(Icons.play_arrow),
                          tooltip: 'Play offline',
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => PlayerScreen(
                                url: d['path'],
                                title: name,
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
                          onPressed: () => Downloads.delete(
                              d['type'], d['itemId'], d['videoId']),
                        ),
                      ]),
                    ),
                  );
                }

                // Series (or multiple files): stacked under one card.
                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: ExpansionTile(
                    leading: leading,
                    title: Text(name),
                    subtitle: Text(
                        '${recs.length} episode${recs.length == 1 ? '' : 's'} · ${_size(total)}'),
                    children: [
                      for (final d in recs) _episodeTile(context, d),
                    ],
                  ),
                );
              }),
          ],
        );
      },
    );
  }
}
