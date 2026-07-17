import 'package:flutter/material.dart';
import '../config.dart';
import '../services/addons.dart';
import '../services/db.dart';
import '../services/downloads.dart';
import '../services/torbox.dart';
import '../services/trakt.dart';
import 'player_screen.dart';

class DetailsScreen extends StatefulWidget {
  final String type;
  final String id;
  const DetailsScreen({super.key, required this.type, required this.id});
  @override
  State<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends State<DetailsScreen> {
  Map<String, dynamic>? meta;
  String? error;
  int? season;

  @override
  void initState() {
    super.initState();
    Addons.metaFor(widget.type, widget.id).then((m) {
      if (!mounted) return;
      setState(() {
        meta = m;
        final seasons = _seasons(m);
        season = seasons.firstWhere((s) => s > 0, orElse: () => seasons.isEmpty ? 1 : seasons.first);
      });
    }).catchError((e) {
      if (mounted) setState(() => error = '$e');
    });
  }

  List<int> _seasons(Map m) {
    final s = <int>{};
    for (final v in (m['videos'] as List? ?? [])) {
      if (v['season'] != null) s.add(v['season'] as int);
    }
    return s.toList()..sort();
  }

  void _setStatus(String status) {
    Db.setStatus(widget.type, widget.id, status,
        name: meta?['name'], poster: meta?['poster']);
    Trakt.pushStatus(widget.type, widget.id, status);
    setState(() {});
  }

  Future<void> _openStreams(String videoId, String videoTitle) async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _StreamSheet(
        type: widget.type,
        itemId: widget.id,
        videoId: videoId,
        displayName: meta?['name'] ?? widget.id,
        videoTitle: videoTitle,
        poster: meta?['poster'],
        onDone: () => setState(() {}),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (meta == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
            child: error != null
                ? Text(error!)
                : const CircularProgressIndicator()),
      );
    }
    final m = meta!;
    final videos = (m['videos'] as List? ?? [])
        .where((v) => season == null || v['season'] == season)
        .toList()
      ..sort((a, b) => ((a['episode'] ?? 0) as num).compareTo((b['episode'] ?? 0) as num));
    final isSeries = (m['videos'] as List? ?? []).isNotEmpty;
    final status = Db.itemStatus(widget.type, widget.id);
    final metaLine = [
      m['year'],
      m['runtime'],
      if (m['imdbRating'] != null) 'IMDb ${m['imdbRating']}',
      (m['genres'] as List?)?.join(' · '),
    ].whereType<String>().join('  ·  ');

    return Scaffold(
      appBar: AppBar(title: Text(m['name'] ?? widget.id)),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (m['poster'] != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(m['poster'],
                      width: 180, height: 270, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox(width: 180)),
                ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m['name'] ?? '',
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(metaLine, style: TextStyle(color: Theme.of(context).hintColor)),
                    const SizedBox(height: 10),
                    if (m['description'] != null) Text(m['description']),
                    const SizedBox(height: 14),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final s in statuses)
                        ChoiceChip(
                          label: Text(s.$2),
                          selected: status == s.$1,
                          onSelected: (_) => _setStatus(s.$1),
                        ),
                      if (status != null)
                        ActionChip(
                          label: const Text('Remove'),
                          onPressed: () {
                            Db.removeItem(widget.type, widget.id);
                            Trakt.pushStatus(widget.type, widget.id, 'removed');
                            setState(() {});
                          },
                        ),
                    ]),
                    const SizedBox(height: 16),
                    if (!isSeries)
                      FilledButton.icon(
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Find streams'),
                        onPressed: () =>
                            _openStreams(m['id'] ?? widget.id, m['name'] ?? ''),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (isSeries) ...[
            const SizedBox(height: 24),
            Row(children: [
              const Text('EPISODES', style: TextStyle(letterSpacing: 1.5, fontSize: 12)),
              const SizedBox(width: 16),
              DropdownButton<int>(
                value: season,
                items: [
                  for (final s in _seasons(m))
                    DropdownMenuItem(
                        value: s, child: Text(s == 0 ? 'Specials' : 'Season $s')),
                ],
                onChanged: (v) => setState(() => season = v),
              ),
            ]),
            const SizedBox(height: 6),
            for (final v in videos)
              _EpisodeTile(
                type: widget.type,
                itemId: widget.id,
                video: v,
                onPlay: () => _openStreams(
                    v['id'],
                    'S${v['season']} E${v['episode']} · ${v['title'] ?? v['name'] ?? ''}'),
                onChanged: () => setState(() {}),
              ),
          ],
        ],
      ),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  final String type, itemId;
  final Map video;
  final VoidCallback onPlay, onChanged;
  const _EpisodeTile(
      {required this.type,
      required this.itemId,
      required this.video,
      required this.onPlay,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final vid = video['id'] as String;
    final watched = Db.isWatched(type, itemId, vid);
    final downloaded = Downloads.isDownloaded(type, itemId, vid);
    final p = Db.prog(type, itemId, vid);
    final pos = (p?['position'] ?? 0.0) as num;
    final dur = (p?['duration'] ?? 0.0) as num;
    return ListTile(
      dense: true,
      leading: Text('E${(video['episode'] ?? '').toString().padLeft(2, '0')}',
          style: const TextStyle(fontFamily: 'monospace')),
      title: Text(video['title'] ?? video['name'] ?? vid),
      subtitle: (dur > 0 && !watched && pos > 60)
          ? LinearProgressIndicator(value: (pos / dur).clamp(0, 1).toDouble(), minHeight: 2)
          : null,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (downloaded)
          const Icon(Icons.download_done, size: 18, color: Color(0xFF63C589)),
        IconButton(
          icon: Icon(watched ? Icons.check_circle : Icons.check_circle_outline,
              color: watched ? const Color(0xFF63C589) : null),
          tooltip: watched ? 'Watched — click to unmark' : 'Mark watched',
          onPressed: () {
            Db.markWatched(type, itemId, vid, !watched);
            Trakt.pushWatched(type, vid, !watched);
            onChanged();
          },
        ),
      ]),
      onTap: onPlay,
    );
  }
}

/// Bottom sheet listing streams from every enabled addon, with Play and
/// Download actions per stream. infoHash-only streams resolve through TorBox.
class _StreamSheet extends StatefulWidget {
  final String type, itemId, videoId, displayName, videoTitle;
  final String? poster;
  final VoidCallback onDone;
  const _StreamSheet(
      {required this.type,
      required this.itemId,
      required this.videoId,
      required this.displayName,
      required this.videoTitle,
      required this.onDone,
      this.poster});

  @override
  State<_StreamSheet> createState() => _StreamSheetState();
}

class _StreamSheetState extends State<_StreamSheet> {
  List<Map>? groups;
  String? error, busy;

  @override
  void initState() {
    super.initState();
    Addons.streamsFor(widget.type, widget.videoId).then((g) {
      if (mounted) setState(() => groups = g);
    }).catchError((e) {
      if (mounted) setState(() => error = '$e');
    });
  }

  Future<String> _resolveUrl(Map s) async {
    if (s['url'] != null) return s['url'];
    if (s['infoHash'] != null) {
      setState(() => busy = 'Asking TorBox to fetch this torrent…');
      try {
        return await TorBox.resolve(s['infoHash'], s['fileIdx']);
      } finally {
        if (mounted) setState(() => busy = null);
      }
    }
    throw 'This stream has no playable source.';
  }

  Map<String, String> _headers(Map s) {
    final h = s['behaviorHints']?['proxyHeaders']?['request'];
    return h is Map ? h.map((k, v) => MapEntry('$k', '$v')) : {};
  }

  Future<void> _play(Map s) async {
    try {
      final url = await _resolveUrl(s);
      final subs = await Addons.subtitlesFor(widget.type, widget.videoId)
          .catchError((_) => <Map>[]);
      if (!mounted) return;
      Navigator.of(context).pop();
      await Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
        builder: (_) => PlayerScreen(
          url: url,
          title: '${widget.displayName} — ${widget.videoTitle}',
          type: widget.type,
          itemId: widget.itemId,
          videoId: widget.videoId,
          headers: _headers(s),
          addonSubs: subs,
        ),
      ));
      widget.onDone();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _download(Map s) async {
    try {
      final url = await _resolveUrl(s);
      final subs = await Addons.subtitlesFor(widget.type, widget.videoId)
          .catchError((_) => <Map>[]);
      Downloads.start(
        type: widget.type,
        itemId: widget.itemId,
        videoId: widget.videoId,
        url: url,
        displayName: widget.displayName,
        videoTitle: widget.videoTitle,
        poster: widget.poster,
        headers: _headers(s),
        subs: subs,
      );
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Download started — track it in the Downloads tab.')));
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (_, controller) {
        if (groups == null && error == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return Column(children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(widget.videoTitle,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          if (busy != null) Text(busy!, style: TextStyle(color: Theme.of(context).hintColor)),
          if (error != null)
            Padding(
                padding: const EdgeInsets.all(8),
                child: Text(error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error))),
          Expanded(
            child: ListView(controller: controller, children: [
              for (final g in groups ?? [])
                for (final s in (g['streams'] as List))
                  ListTile(
                    dense: true,
                    leading: SizedBox(
                      width: 110,
                      child: Text(s['name'] ?? g['addon'] ?? '',
                          style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: Color(0xFFE8B15C))),
                    ),
                    title: Text(s['description'] ?? s['title'] ?? s['url'] ?? '',
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12)),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (s['infoHash'] != null && s['url'] == null)
                        const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: Text('P2P', style: TextStyle(fontSize: 10))),
                      IconButton(
                          icon: const Icon(Icons.download_outlined, size: 20),
                          tooltip: 'Download for offline',
                          onPressed: () => _download(s)),
                      IconButton(
                          icon: const Icon(Icons.play_arrow, size: 22),
                          tooltip: 'Play',
                          onPressed: () => _play(s)),
                    ]),
                    onTap: () => _play(s),
                  ),
              if ((groups ?? []).isEmpty && error == null)
                const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(
                        child: Text('No add-on returned streams for this.'))),
            ]),
          ),
        ]);
      },
    );
  }
}
