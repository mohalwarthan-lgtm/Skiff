import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/db.dart';
import '../services/trakt.dart';

/// Full-screen player. media_kit bundles its own engine (mpv under the hood),
/// so MKV/HEVC/embedded tracks all work with zero system setup.
/// Handles: resume, per-5s progress saves, Trakt scrobble start/pause/stop,
/// audio + subtitle track selection (embedded and addon-provided), speed,
/// volume, and offline files (pass a local path as [url]).
class PlayerScreen extends StatefulWidget {
  final String url; // http(s) URL or local file path
  final String title;
  final String type, itemId, videoId;
  final Map<String, String> headers;
  final List<Map> addonSubs; // [{url, lang}]
  final List<Map> localSubs; // [{path, lang}] for offline playback

  const PlayerScreen({
    super.key,
    required this.url,
    required this.title,
    required this.type,
    required this.itemId,
    required this.videoId,
    this.headers = const {},
    this.addonSubs = const [],
    this.localSubs = const [],
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player player;
  VideoController? controller;
  String? playerError;
  final List<String> logs = [];
  Timer? saveTimer;
  bool resumed = false;
  bool controlsVisible = true;
  Timer? hideTimer;
  double? scrubbing;

  @override
  void initState() {
    super.initState();
    player = Player(
        configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn));
    // The video surface MUST exist before open(), or the stream decodes
    // into the void and the screen stays black.
    controller = VideoController(player);
    player.stream.error.listen((e) {
      if (mounted) setState(() => playerError = e);
    });
    player.stream.log.listen((l) {
      logs.add('${l.prefix}: ${l.text}');
      if (logs.length > 10) logs.removeAt(0);
    });
    _open();
  }

  Future<void> _open() async {
    setState(() => playerError = null);
    try {
      await player.open(
          Media(widget.url,
              httpHeaders:
                  widget.headers.isEmpty ? null : widget.headers),
          play: true);
    } catch (e) {
      if (mounted) setState(() => playerError = '$e');
      return;
    }
    Trakt.scrobble('start', widget.type, widget.videoId, 0).catchError((_) {});

    // Resume once we know the duration.
    player.stream.duration.listen((d) {
      if (!resumed && d.inSeconds > 0) {
        resumed = true;
        final p = Db.prog(widget.type, widget.itemId, widget.videoId);
        final pos = (p?['position'] ?? 0.0) as num;
        if (p?['watched'] != true && pos > 30 && pos < d.inSeconds - 30) {
          player.seek(Duration(seconds: pos.toInt()));
        }
      }
    });

    // Save progress every 5 seconds while playing.
    saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final pos = player.state.position.inSeconds.toDouble();
      final dur = player.state.duration.inSeconds.toDouble();
      if (pos > 0) {
        Db.setProgress(widget.type, widget.itemId, widget.videoId, pos, dur);
      }
    });

    player.stream.playing.listen((playing) {
      final pct = _pct();
      Trakt.scrobble(playing ? 'start' : 'pause', widget.type, widget.videoId, pct)
          .catchError((_) {});
    });

    _poke();
  }

  double _pct() {
    final dur = player.state.duration.inSeconds;
    if (dur == 0) return 0;
    return (player.state.position.inSeconds / dur * 100).clamp(0, 100);
  }

  @override
  void dispose() {
    final pos = player.state.position.inSeconds.toDouble();
    final dur = player.state.duration.inSeconds.toDouble();
    if (pos > 0) {
      Db.setProgress(widget.type, widget.itemId, widget.videoId, pos, dur);
    }
    Trakt.scrobble('stop', widget.type, widget.videoId, _pct()).catchError((_) {});
    saveTimer?.cancel();
    hideTimer?.cancel();
    player.dispose();
    super.dispose();
  }

  void _poke() {
    setState(() => controlsVisible = true);
    hideTimer?.cancel();
    hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => controlsVisible = false);
    });
  }

  Future<void> _pickAudio() async {
    final tracks = player.state.tracks.audio
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    final picked = await _pickFromList('Audio', [
      for (final t in tracks)
        (t.id, [t.language?.toUpperCase(), t.title].whereType<String>().join(' · ').isEmpty
            ? 'Track ${t.id}'
            : [t.language?.toUpperCase(), t.title].whereType<String>().join(' · ')),
    ]);
    if (picked != null) {
      await player.setAudioTrack(tracks.firstWhere((t) => t.id == picked));
    }
  }

  Future<void> _pickSubs() async {
    final embedded = player.state.tracks.subtitle
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    final entries = <(String, String)>[
      ('off', 'Off'),
      for (final t in embedded)
        ('e:${t.id}',
            [t.language?.toUpperCase(), t.title].whereType<String>().join(' · ').isEmpty
                ? 'Embedded ${t.id}'
                : [t.language?.toUpperCase(), t.title].whereType<String>().join(' · ')),
      for (var i = 0; i < widget.addonSubs.length; i++)
        ('a:$i', 'Add-on · ${widget.addonSubs[i]['lang'] ?? 'sub ${i + 1}'}'),
      for (var i = 0; i < widget.localSubs.length; i++)
        ('l:$i', 'Downloaded · ${widget.localSubs[i]['lang'] ?? 'sub ${i + 1}'}'),
    ];
    final picked = await _pickFromList('Subtitles', entries);
    if (picked == null) return;
    if (picked == 'off') {
      await player.setSubtitleTrack(SubtitleTrack.no());
    } else if (picked.startsWith('e:')) {
      final id = picked.substring(2);
      await player.setSubtitleTrack(embedded.firstWhere((t) => t.id == id));
    } else if (picked.startsWith('a:')) {
      final s = widget.addonSubs[int.parse(picked.substring(2))];
      await player.setSubtitleTrack(
          SubtitleTrack.uri(s['url'], language: s['lang']));
    } else if (picked.startsWith('l:')) {
      final s = widget.localSubs[int.parse(picked.substring(2))];
      await player.setSubtitleTrack(
          SubtitleTrack.uri('file:///${s['path']}', language: s['lang']));
    }
  }

  Future<String?> _pickFromList(String title, List<(String, String)> entries) =>
      showDialog<String>(
        context: context,
        builder: (_) => SimpleDialog(
          title: Text(title),
          children: [
            for (final e in entries)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, e.$1),
                child: Text(e.$2),
              ),
          ],
        ),
      );

  String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0'), ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        onHover: (_) => _poke(),
        child: Stack(children: [
          Center(
              child: controller == null
                  ? const CircularProgressIndicator()
                  : Video(controller: controller!, controls: NoVideoControls)),
          // Buffering spinner while the network catches up.
          Center(
            child: StreamBuilder<bool>(
              stream: player.stream.buffering,
              builder: (_, s) => (s.data ?? false)
                  ? const CircularProgressIndicator()
                  : const SizedBox.shrink(),
            ),
          ),
          if (playerError != null)
            Center(
              child: Container(
                margin: const EdgeInsets.all(40),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(10)),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.error_outline, size: 32),
                  const SizedBox(height: 8),
                  Text('Playback failed: $playerError',
                      textAlign: TextAlign.center),
                  const SizedBox(height: 6),
                  SelectableText(logs.join('\n'),
                      style: const TextStyle(
                          fontSize: 10, fontFamily: 'monospace')),
                  const SizedBox(height: 10),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    FilledButton(onPressed: _open, child: const Text('Retry')),
                    const SizedBox(width: 10),
                    TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close')),
                  ]),
                ]),
              ),
            ),
          // Click video = pause/play
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                player.playOrPause();
                _poke();
              },
            ),
          ),
          AnimatedOpacity(
            opacity: controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: !controlsVisible,
              child: Column(children: [
                // Top bar
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: const BoxDecoration(
                      gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.black87, Colors.transparent])),
                  child: Row(children: [
                    IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.of(context).pop()),
                    Expanded(
                        child: Text(widget.title,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600))),
                  ]),
                ),
                const Spacer(),
                // Bottom bar
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                  decoration: const BoxDecoration(
                      gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Colors.black87, Colors.transparent])),
                  child: StreamBuilder<Duration>(
                    stream: player.stream.position,
                    builder: (_, snap) {
                      final pos = snap.data ?? Duration.zero;
                      final dur = player.state.duration;
                      final shown = scrubbing ?? pos.inSeconds.toDouble();
                      return Column(mainAxisSize: MainAxisSize.min, children: [
                        Slider(
                          value: shown.clamp(
                              0, dur.inSeconds.toDouble().clamp(1, double.infinity)),
                          max: dur.inSeconds.toDouble().clamp(1, double.infinity),
                          onChanged: (v) => setState(() => scrubbing = v),
                          onChangeEnd: (v) {
                            player.seek(Duration(seconds: v.toInt()));
                            setState(() => scrubbing = null);
                          },
                        ),
                        Row(children: [
                          StreamBuilder<bool>(
                            stream: player.stream.playing,
                            builder: (_, s) => IconButton(
                              icon: Icon((s.data ?? false)
                                  ? Icons.pause
                                  : Icons.play_arrow),
                              onPressed: player.playOrPause,
                            ),
                          ),
                          Text('${_fmt(Duration(seconds: shown.toInt()))} / ${_fmt(dur)}',
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 12)),
                          const Spacer(),
                          TextButton.icon(
                              icon: const Icon(Icons.audiotrack, size: 18),
                              label: const Text('Audio'),
                              onPressed: _pickAudio),
                          TextButton.icon(
                              icon: const Icon(Icons.subtitles, size: 18),
                              label: const Text('Subtitles'),
                              onPressed: _pickSubs),
                          PopupMenuButton<double>(
                            tooltip: 'Speed',
                            initialValue: player.state.rate,
                            onSelected: (v) => player.setRate(v),
                            itemBuilder: (_) => [
                              for (final v in [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
                                PopupMenuItem(value: v, child: Text('${v}x')),
                            ],
                            child: const Padding(
                                padding: EdgeInsets.all(8),
                                child: Icon(Icons.speed, size: 20)),
                          ),
                          SizedBox(
                            width: 110,
                            child: StreamBuilder<double>(
                              stream: player.stream.volume,
                              builder: (_, s) => Slider(
                                value: (s.data ?? 100).clamp(0, 100),
                                max: 100,
                                onChanged: (v) => player.setVolume(v),
                              ),
                            ),
                          ),
                        ]),
                      ]);
                    },
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
