import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import '../services/db.dart';
import '../services/net.dart';
import '../services/trakt.dart';

/// Full-screen player.
///
/// Error philosophy: an audio-codec failure (TrueHD & friends) must never
/// block a playing video — it gets a one-time dismissible banner and an
/// automatic switch to a working audio track. The full error panel appears
/// only when playback is genuinely stalled, after one silent retry.
class PlayerScreen extends StatefulWidget {
  final String url; // http(s) URL or local file path
  final String title;
  final String type, itemId, videoId;
  final Map<String, String> headers;
  final List<Map> addonSubs; // [{url, lang, id?}]
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

  // Error handling state
  String? playerError; // fatal: playback stalled, full panel
  String? audioWarn; // audio-only: video plays on, small banner
  bool audioDismissed = false;
  bool triedAutoAudio = false;
  bool retriedOpen = false;
  final Set<String> seenErrors = {};
  final List<String> logs = [];

  // UI state
  Timer? saveTimer;
  Timer? hideTimer;
  bool resumed = false;
  bool controlsVisible = true;
  bool fullscreen = false;
  double? scrubbing;
  final focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    player = Player(
        configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn));
    controller = VideoController(player); // surface BEFORE open, always
    player.stream.error.listen(_onEngineError);
    player.stream.log.listen((l) {
      logs.add('${l.prefix}: ${l.text}');
      if (logs.length > 10) logs.removeAt(0);
    });
    _open();
  }

  // ---------- Open / resume / progress ----------

  Future<void> _open() async {
    setState(() => playerError = null);
    try {
      final isLocal = !widget.url.startsWith('http');
      await player.open(
          Media(widget.url,
              httpHeaders: isLocal ? null : Net.withUa(widget.headers)),
          play: true);
    } catch (e) {
      _onEngineError('$e');
      return;
    }
    _applySavedSubStyle();
    Trakt.scrobble('start', widget.type, widget.videoId, 0).catchError((_) {});

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

    saveTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      final pos = player.state.position.inSeconds.toDouble();
      final dur = player.state.duration.inSeconds.toDouble();
      if (pos > 0) {
        Db.setProgress(widget.type, widget.itemId, widget.videoId, pos, dur);
      }
    });

    player.stream.playing.listen((playing) {
      Trakt.scrobble(
              playing ? 'start' : 'pause', widget.type, widget.videoId, _pct())
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
    Trakt.scrobble('stop', widget.type, widget.videoId, _pct())
        .catchError((_) {});
    saveTimer?.cancel();
    hideTimer?.cancel();
    if (fullscreen) windowManager.setFullScreen(false);
    player.dispose();
    focusNode.dispose();
    super.dispose();
  }

  // ---------- Error classification ----------

  void _onEngineError(String e) async {
    if (!mounted) return;
    // mpv repeats decoder failures per packet — react to each message once.
    if (!seenErrors.add(e)) return;
    final low = e.toLowerCase();
    final audioIssue = low.contains('decoder') || low.contains('audio');

    if (audioIssue) {
      if (!audioDismissed && audioWarn == null) {
        setState(() => audioWarn = e);
      }
      if (!triedAutoAudio) {
        triedAutoAudio = true;
        await Future.delayed(const Duration(seconds: 1));
        if (!mounted) return;
        final tracks = player.state.tracks.audio
            .where((t) => t.id != 'auto' && t.id != 'no')
            .toList();
        final current = player.state.track.audio.id;
        final other = tracks.where((t) => t.id != current).toList();
        if (other.isNotEmpty) {
          await player.setAudioTrack(other.first);
          if (mounted && !audioDismissed) {
            setState(() => audioWarn =
                "This release's main audio codec is unsupported — "
                "switched to another audio track automatically.");
          }
        } else if (mounted && !audioDismissed) {
          setState(() => audioWarn =
              "This release's audio codec is unsupported and it has no "
              "other audio track — pick a different release.");
        }
      }
      _escalateIfStalled(e);
      return;
    }

    // Non-audio failure: one silent retry, then the panel.
    if (!retriedOpen) {
      retriedOpen = true;
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) _open();
      return;
    }
    _escalateIfStalled(e, force: true);
  }

  /// Show the full panel only when playback is truly dead — never over a
  /// playing video.
  void _escalateIfStalled(String e, {bool force = false}) async {
    await Future.delayed(Duration(seconds: force ? 4 : 10));
    if (!mounted || playerError != null) return;
    final dead = player.state.position == Duration.zero &&
        player.state.duration == Duration.zero;
    if (dead) setState(() => playerError = e);
  }

  void _retry() {
    seenErrors.clear();
    triedAutoAudio = false;
    audioDismissed = false;
    retriedOpen = true; // a manual retry consumes the silent one
    setState(() {
      playerError = null;
      audioWarn = null;
    });
    _open();
  }

  // ---------- Fullscreen & keyboard ----------

  Future<void> _toggleFullscreen() async {
    fullscreen = !fullscreen;
    await windowManager.setFullScreen(fullscreen);
    if (mounted) setState(() {});
  }

  void _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.space) {
      player.playOrPause();
    } else if (k == LogicalKeyboardKey.arrowRight) {
      player.seek(player.state.position + const Duration(seconds: 10));
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      final t = player.state.position - const Duration(seconds: 10);
      player.seek(t.isNegative ? Duration.zero : t);
    } else if (k == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
    } else if (k == LogicalKeyboardKey.escape) {
      if (fullscreen) {
        _toggleFullscreen();
      } else {
        Navigator.of(context).pop();
      }
    }
    _poke();
  }

  void _poke() {
    if (!controlsVisible && mounted) setState(() => controlsVisible = true);
    hideTimer?.cancel();
    hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => controlsVisible = false);
    });
  }

  // ---------- Tracks & subtitles ----------

  String _trackLabel(dynamic t, String fallback) {
    final bits = [
      (t.language as String?)?.toUpperCase(),
      t.title as String?,
    ].whereType<String>().where((x) => x.isNotEmpty).join(' · ');
    return bits.isEmpty ? fallback : bits;
  }

  Future<void> _pickAudio() async {
    final tracks = player.state.tracks.audio
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    final picked = await _pickFromList('Audio', [
      for (final t in tracks) (t.id, _trackLabel(t, 'Track ${t.id}')),
    ]);
    if (picked != null) {
      await player.setAudioTrack(tracks.firstWhere((t) => t.id == picked));
      setState(() {
        audioWarn = null;
        audioDismissed = true;
      });
    }
  }

  /// Addon subtitle lists arrive messy (20 identical "eng" rows) — dedupe
  /// by URL and number them so every entry is distinct and pickable.
  List<Map> get _dedupedAddonSubs {
    final seen = <String>{};
    final out = <Map>[];
    for (final s in widget.addonSubs) {
      final url = s['url'] as String?;
      if (url != null && seen.add(url)) out.add(s);
    }
    return out;
  }

  Future<void> _pickSubs() async {
    final embedded = player.state.tracks.subtitle
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    final addon = _dedupedAddonSubs;
    final entries = <(String, String)>[
      ('off', 'Off'),
      for (final t in embedded)
        ('e:${t.id}', _trackLabel(t, 'Embedded ${t.id}')),
      for (var i = 0; i < addon.length; i++)
        (
          'a:$i',
          'Add-on ${i + 1} · '
              '${(addon[i]['lang'] as String? ?? 'sub').toUpperCase()}'
              '${addon[i]['id'] != null ? ' · ${addon[i]['id']}' : ''}'
        ),
      for (var i = 0; i < widget.localSubs.length; i++)
        (
          'l:$i',
          'Downloaded · ${(widget.localSubs[i]['lang'] as String? ?? 'sub ${i + 1}').toUpperCase()}'
        ),
    ];
    final picked = await _pickFromList('Subtitles', entries);
    if (picked == null) return;
    if (picked == 'off') {
      await player.setSubtitleTrack(SubtitleTrack.no());
    } else if (picked.startsWith('e:')) {
      final id = picked.substring(2);
      await player.setSubtitleTrack(embedded.firstWhere((t) => t.id == id));
    } else if (picked.startsWith('a:')) {
      final s = addon[int.parse(picked.substring(2))];
      await player
          .setSubtitleTrack(SubtitleTrack.uri(s['url'], language: s['lang']));
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

  // ---------- Subtitle styling (size / position / delay) ----------

  Future<void> _setMpv(String prop, String value) async {
    try {
      final p = player.platform;
      await (p as dynamic).setProperty(prop, value);
    } catch (_) {/* property API unavailable on this backend */}
  }

  void _applySavedSubStyle() {
    // Render subtitles as outlined text (like Stremio/mpv defaults) rather
    // than text on an opaque box. 'back-color' alpha controls the box; we
    // default it fully transparent and expose it as a slider.
    _setMpv('sub-border-size', Db.setting('sub_border') ?? '3.0');
    _setMpv('sub-border-color', '#000000');
    _setMpv('sub-shadow-offset', '0.0');
    _setMpv('sub-color', '#FFFFFF');
    _setMpv('sub-back-color', _backColor(Db.setting('sub_bg_opacity') ?? '0'));
    _setMpv('sub-scale', Db.setting('sub_scale') ?? '1.0');
    _setMpv('sub-pos', Db.setting('sub_pos') ?? '100');
  }

  /// mpv wants ARGB hex; map a 0-100 opacity to the alpha byte.
  String _backColor(String pct) {
    final a = ((double.tryParse(pct) ?? 0) / 100 * 255).round().clamp(0, 255);
    final hex = a.toRadixString(16).padLeft(2, '0').toUpperCase();
    return '#${hex}000000';
  }

  Future<void> _subStyleDialog() async {
    var scale = double.tryParse(Db.setting('sub_scale') ?? '') ?? 1.0;
    var pos = double.tryParse(Db.setting('sub_pos') ?? '') ?? 100.0;
    var border = double.tryParse(Db.setting('sub_border') ?? '') ?? 3.0;
    var bg = double.tryParse(Db.setting('sub_bg_opacity') ?? '') ?? 0.0;
    var delay = 0.0;
    await showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          title: const Text('Subtitle style'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const SizedBox(width: 70, child: Text('Size')),
              Expanded(
                child: Slider(
                  value: scale,
                  min: 0.5,
                  max: 2.0,
                  divisions: 30,
                  label: '${(scale * 100).round()}%',
                  onChanged: (v) {
                    setD(() => scale = v);
                    _setMpv('sub-scale', v.toStringAsFixed(2));
                    Db.setSetting('sub_scale', v.toStringAsFixed(2));
                  },
                ),
              ),
            ]),
            Row(children: [
              const SizedBox(width: 70, child: Text('Height')),
              Expanded(
                child: Slider(
                  value: pos,
                  min: 30,
                  max: 100,
                  divisions: 70,
                  label: pos.round().toString(),
                  onChanged: (v) {
                    setD(() => pos = v);
                    _setMpv('sub-pos', v.round().toString());
                    Db.setSetting('sub_pos', v.round().toString());
                  },
                ),
              ),
            ]),
            Row(children: [
              const SizedBox(width: 70, child: Text('Border')),
              Expanded(
                child: Slider(
                  value: border,
                  min: 0,
                  max: 6,
                  divisions: 12,
                  label: border.toStringAsFixed(1),
                  onChanged: (v) {
                    setD(() => border = v);
                    _setMpv('sub-border-size', v.toStringAsFixed(1));
                    Db.setSetting('sub_border', v.toStringAsFixed(1));
                  },
                ),
              ),
            ]),
            Row(children: [
              const SizedBox(width: 70, child: Text('Box')),
              Expanded(
                child: Slider(
                  value: bg,
                  min: 0,
                  max: 100,
                  divisions: 20,
                  label: '${bg.round()}%',
                  onChanged: (v) {
                    setD(() => bg = v);
                    _setMpv('sub-back-color', _backColor(v.round().toString()));
                    Db.setSetting('sub_bg_opacity', v.round().toString());
                  },
                ),
              ),
            ]),
            Row(children: [
              const SizedBox(width: 70, child: Text('Delay')),
              IconButton(
                  icon: const Icon(Icons.remove),
                  onPressed: () {
                    setD(() => delay -= 0.5);
                    _setMpv('sub-delay', delay.toStringAsFixed(1));
                  }),
              Text('${delay.toStringAsFixed(1)}s'),
              IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () {
                    setD(() => delay += 0.5);
                    _setMpv('sub-delay', delay.toStringAsFixed(1));
                  }),
            ]),
          ]),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done')),
          ],
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0'), ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: KeyboardListener(
        focusNode: focusNode,
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          onHover: (_) => _poke(),
          child: Stack(children: [
            Center(
                child: controller == null
                    ? const CircularProgressIndicator()
                    : Video(controller: controller!, controls: NoVideoControls)),
            Center(
              child: StreamBuilder<bool>(
                stream: player.stream.buffering,
                builder: (_, s) => (s.data ?? false)
                    ? const CircularProgressIndicator()
                    : const SizedBox.shrink(),
              ),
            ),
            // Tap = pause/play, double tap = fullscreen
            Positioned.fill(
              child: GestureDetector(
                onTap: () {
                  player.playOrPause();
                  _poke();
                },
                onDoubleTap: _toggleFullscreen,
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
                      FilledButton(
                          onPressed: _retry, child: const Text('Retry')),
                      const SizedBox(width: 10),
                      TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Close')),
                    ]),
                  ]),
                ),
              ),
            if (audioWarn != null && playerError == null)
              Positioned(
                top: 64,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(8)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.volume_off, size: 16),
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 480),
                        child: Text(audioWarn!,
                            style: const TextStyle(fontSize: 12)),
                      ),
                      TextButton(
                          onPressed: _pickAudio,
                          child: const Text('Audio tracks')),
                      IconButton(
                          icon: const Icon(Icons.close, size: 14),
                          onPressed: () => setState(() {
                                audioWarn = null;
                                audioDismissed = true;
                              })),
                    ]),
                  ),
                ),
              ),
            AnimatedOpacity(
              opacity: controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !controlsVisible,
                child: Column(children: [
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
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600))),
                    ]),
                  ),
                  const Spacer(),
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
                        final maxV =
                            dur.inSeconds.toDouble().clamp(1, double.infinity);
                        return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Slider(
                                value: shown.clamp(0, maxV).toDouble(),
                                max: maxV.toDouble(),
                                onChanged: (v) =>
                                    setState(() => scrubbing = v),
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
                                Text(
                                    '${_fmt(Duration(seconds: shown.toInt()))} / ${_fmt(dur)}',
                                    style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12)),
                                const Spacer(),
                                TextButton.icon(
                                    icon:
                                        const Icon(Icons.audiotrack, size: 18),
                                    label: const Text('Audio'),
                                    onPressed: _pickAudio),
                                TextButton.icon(
                                    icon: const Icon(Icons.subtitles, size: 18),
                                    label: const Text('Subtitles'),
                                    onPressed: _pickSubs),
                                IconButton(
                                    icon: const Icon(Icons.tune, size: 18),
                                    tooltip: 'Subtitle style',
                                    onPressed: _subStyleDialog),
                                PopupMenuButton<double>(
                                  tooltip: 'Speed',
                                  initialValue: player.state.rate,
                                  onSelected: (v) => player.setRate(v),
                                  itemBuilder: (_) => [
                                    for (final v in [
                                      0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0
                                    ])
                                      PopupMenuItem(
                                          value: v, child: Text('${v}x')),
                                  ],
                                  child: const Padding(
                                      padding: EdgeInsets.all(8),
                                      child: Icon(Icons.speed, size: 20)),
                                ),
                                SizedBox(
                                  width: 100,
                                  child: StreamBuilder<double>(
                                    stream: player.stream.volume,
                                    builder: (_, s) => Slider(
                                      value: (s.data ?? 100).clamp(0, 100),
                                      max: 100,
                                      onChanged: (v) => player.setVolume(v),
                                    ),
                                  ),
                                ),
                                IconButton(
                                    icon: Icon(fullscreen
                                        ? Icons.fullscreen_exit
                                        : Icons.fullscreen),
                                    tooltip: 'Fullscreen (F)',
                                    onPressed: _toggleFullscreen),
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
      ),
    );
  }
}
