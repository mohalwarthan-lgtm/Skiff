import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import '../services/db.dart';
import '../services/net.dart';
import '../services/trakt.dart';

/// Player. Audio-codec failures never block a playing video (banner +
/// auto track switch); the full error panel only appears when truly stalled.
/// Lets the app flush the current playback position to Trakt before the
/// window closes (the process would otherwise die mid-request).
class PlayerFlush {
  static Future<void> Function()? flush;
}

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

  // Subtitle style - applied to media_kit's Flutter subtitle overlay (the
  // thing actually painting the text; mpv properties do not affect it).
  late double subSize =
      double.tryParse(Db.setting('sub_size') ?? '') ?? 44;
  late double subBottom =
      double.tryParse(Db.setting('sub_bottom') ?? '') ?? 40;
  late double subOutline =
      double.tryParse(Db.setting('sub_outline') ?? '') ?? 2;
  late double subBg = double.tryParse(Db.setting('sub_bg') ?? '') ?? 0;
  bool stylePreview = false; // style dialog open: always show a sample line

  @override
  void initState() {
    super.initState();
    player = Player(
        configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn));
    controller = VideoController(player); // surface BEFORE open, always
    final cacheDir = Db.setting('cache_dir');
    if (cacheDir != null && cacheDir.trim().isNotEmpty) {
      _setMpv('cache-dir', cacheDir.trim());
    }
    player.stream.error.listen(_onEngineError);
    PlayerFlush.flush = _flushStop;
    // Checkpoint: refresh Trakt's position every few minutes while
    // playing, so even a crash loses almost nothing.
    _checkpoint = Timer.periodic(const Duration(minutes: 5), (_) {
      if (player.state.playing) {
        Trakt.scrobble('start', widget.type, widget.itemId,
                widget.videoId, _pct())
            .catchError((_) {});
      }
    });
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

    player.stream.duration.listen((d) {
      if (!resumed && d.inSeconds > 0) {
        resumed = true;
        final p = Db.prog(widget.type, widget.itemId, widget.videoId);
        final pos = (p?['position'] ?? 0.0) as num;
        final pct = (p?['pct'] ?? 0.0) as num;
        if (p?['watched'] != true) {
          if (pos > 30 && pos < d.inSeconds - 30) {
            player.seek(Duration(seconds: pos.toInt()));
          } else if (pct > 1 && pct < 98) {
            // Position synced from Trakt (watched elsewhere).
            player.seek(
                Duration(seconds: (d.inSeconds * pct / 100).round()));
          }
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
      Trakt.scrobble(playing ? 'start' : 'pause', widget.type, widget.itemId,
              widget.videoId, _pct())
          .catchError((_) {});
    });

    _poke();
  }

  Timer? _checkpoint;
  bool _switching = false; // texture detached during fullscreen switch

  Future<void> _flushStop() async {
    try {
      await Trakt.scrobble(
          'stop', widget.type, widget.itemId, widget.videoId, _pct());
    } catch (_) {}
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
    _checkpoint?.cancel();
    PlayerFlush.flush = null;
    Trakt.scrobble('stop', widget.type, widget.itemId, widget.videoId, _pct())
        .catchError((_) {});
    saveTimer?.cancel();
    hideTimer?.cancel();
    if (fullscreen && _desktop) windowManager.setFullScreen(false);
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

  static final bool _desktop =
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Future<void> _toggleFullscreen() async {
    if (!_desktop || _switching) return;
    fullscreen = !fullscreen;
    // The Windows compositor can stall permanently if the video swapchain
    // is presenting during the mode change (the telltale: one frame per
    // resize, then stillness). Detach the texture for the blink of the
    // switch so nothing presents while the window transforms.
    setState(() => _switching = true);
    await Future.delayed(const Duration(milliseconds: 60));
    await windowManager.setFullScreen(fullscreen);
    await Future.delayed(const Duration(milliseconds: 180));
    if (mounted) setState(() => _switching = false);
    if (mounted) setState(() {});
    // Windows can leave the video surface stale after the mode switch
    // (frozen picture, audio continues) - force a few frames.
    for (var i = 0; i < 4; i++) {
      await Future.delayed(const Duration(milliseconds: 130));
      if (!mounted) return;
      setState(() {});
      WidgetsBinding.instance.scheduleForcedFrame();
    }
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

  static const _langNames = {
    'en': 'English', 'eng': 'English',
    'ar': 'Arabic', 'ara': 'Arabic',
    'es': 'Spanish', 'spa': 'Spanish',
    'fr': 'French', 'fre': 'French', 'fra': 'French',
    'de': 'German', 'ger': 'German', 'deu': 'German',
    'it': 'Italian', 'ita': 'Italian',
    'pt': 'Portuguese', 'por': 'Portuguese', 'pob': 'Portuguese (BR)',
    'ru': 'Russian', 'rus': 'Russian',
    'ja': 'Japanese', 'jpn': 'Japanese',
    'ko': 'Korean', 'kor': 'Korean',
    'zh': 'Chinese', 'chi': 'Chinese', 'zho': 'Chinese',
    'hi': 'Hindi', 'hin': 'Hindi',
    'tr': 'Turkish', 'tur': 'Turkish',
    'nl': 'Dutch', 'dut': 'Dutch', 'nld': 'Dutch',
    'pl': 'Polish', 'pol': 'Polish',
    'sv': 'Swedish', 'swe': 'Swedish',
    'no': 'Norwegian', 'nor': 'Norwegian',
    'da': 'Danish', 'dan': 'Danish',
    'fi': 'Finnish', 'fin': 'Finnish',
    'he': 'Hebrew', 'heb': 'Hebrew',
    'ur': 'Urdu', 'urd': 'Urdu',
  };

  String _langName(String? code) {
    if (code == null || code.isEmpty) return 'Unknown';
    return _langNames[code.toLowerCase()] ?? code.toUpperCase();
  }

  Future<void> _pickSubs() async {
    final embedded = player.state.tracks.subtitle
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    final addon = _dedupedAddonSubs;

    // Language + source only; number repeats ("English 2 (add-on)").
    final counts = <String, int>{};
    String label(String lang, String source) {
      final base = _langName(lang);
      final n = counts.update('$source|$base', (v) => v + 1,
          ifAbsent: () => 1);
      return n == 1 ? '$base ($source)' : '$base $n ($source)';
    }

    final entries = <(String, String)>[
      ('off', 'Off'),
      for (final t in embedded)
        ('e:${t.id}', label(t.language ?? '', 'embedded')),
      for (var i = 0; i < addon.length; i++)
        ('a:$i', label(addon[i]['lang'] as String? ?? '', 'add-on')),
      for (var i = 0; i < widget.localSubs.length; i++)
        ('l:$i',
            label(widget.localSubs[i]['lang'] as String? ?? '', 'downloaded')),
    ];
    final picked = await _pickFromList('Subtitles', entries);
    if (picked == null) return;
    if (picked == 'off') {
      await player.setSubtitleTrack(SubtitleTrack.no());
    } else if (picked.startsWith('e:')) {
      final id = picked.substring(2);
      await player.setSubtitleTrack(embedded.firstWhere((t) => t.id == id));
    } else if (picked.startsWith('a:')) {
      final sub = addon[int.parse(picked.substring(2))];
      await player.setSubtitleTrack(
          SubtitleTrack.uri(sub['url'], language: sub['lang']));
    } else if (picked.startsWith('l:')) {
      final sub = widget.localSubs[int.parse(picked.substring(2))];
      await player.setSubtitleTrack(
          SubtitleTrack.uri('file:///${sub['path']}', language: sub['lang']));
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

  TextStyle get _subStyle => TextStyle(
        fontSize: subSize,
        height: 1.35,
        color: Colors.white,
        fontWeight: FontWeight.w500,
        backgroundColor: subBg <= 0
            ? null
            : Colors.black.withOpacity((subBg / 100).clamp(0.0, 1.0)),
        shadows: subOutline <= 0
            ? null
            : [
                for (final o in const [
                  Offset(-1, -1), Offset(1, -1),
                  Offset(-1, 1), Offset(1, 1), Offset(0, 0)
                ])
                  Shadow(
                      offset: o * subOutline,
                      blurRadius: subOutline,
                      color: Colors.black),
              ],
      );

  Future<void> _subStyleDialog() async {
    var delay = 0.0;
    setState(() => stylePreview = true);
    await showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setD) {
          Widget row(String label, double value, double min, double max,
              int divisions, String key, void Function(double) assign,
              {String Function(double)? fmt}) {
            return Row(children: [
              SizedBox(width: 70, child: Text(label)),
              Expanded(
                child: Slider(
                  value: value,
                  min: min,
                  max: max,
                  divisions: divisions,
                  label: fmt != null ? fmt(value) : value.round().toString(),
                  onChanged: (v) {
                    assign(v);
                    Db.setSetting(key, v.toStringAsFixed(1));
                    setD(() {});
                    setState(() {}); // live-preview on the video
                  },
                ),
              ),
            ]);
          }

          return AlertDialog(
            title: const Text('Subtitle style'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              row('Size', subSize, 20, 80, 30, 'sub_size',
                  (v) => subSize = v),
              row('Position', subBottom, 0, 300, 60, 'sub_bottom',
                  (v) => subBottom = v),
              row('Outline', subOutline, 0, 5, 10, 'sub_outline',
                  (v) => subOutline = v,
                  fmt: (v) => v.toStringAsFixed(1)),
              row('Box', subBg, 0, 100, 20, 'sub_bg', (v) => subBg = v,
                  fmt: (v) => v.round().toString() + '%'),
              Row(children: [
                const SizedBox(width: 70, child: Text('Delay')),
                IconButton(
                    icon: const Icon(Icons.remove),
                    onPressed: () {
                      delay -= 0.5;
                      _setMpv('sub-delay', delay.toStringAsFixed(1));
                      setD(() {});
                    }),
                Text(delay.toStringAsFixed(1) + 's'),
                IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () {
                      delay += 0.5;
                      _setMpv('sub-delay', delay.toStringAsFixed(1));
                      setD(() {});
                    }),
              ]),
            ]),
            actions: [
              FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done')),
            ],
          );
        },
      ),
    );
    if (mounted) setState(() => stylePreview = false);
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
                child: controller == null || _switching
                    ? const CircularProgressIndicator()
                    : Video(
                        controller: controller!,
                        controls: NoVideoControls,
                        // We paint subtitles ourselves below - full control
                        // over position and style on every platform.
                        subtitleViewConfiguration:
                            const SubtitleViewConfiguration(visible: false))),
            Center(
              child: StreamBuilder<bool>(
                stream: player.stream.buffering,
                builder: (_, s) => (s.data ?? false)
                    ? const CircularProgressIndicator()
                    : const SizedBox.shrink(),
              ),
            ),
            // Custom subtitle overlay; shows a preview line while styling.
            StreamBuilder<List<String>>(
              stream: player.stream.subtitle,
              builder: (_, snap) {
                var text = (snap.data ?? const <String>[])
                    .where((l) => l.trim().isNotEmpty)
                    .join('\n');
                if (stylePreview && text.isEmpty) {
                  text = 'Subtitle preview — drag the sliders';
                }
                if (text.isEmpty) return const SizedBox.shrink();
                return IgnorePointer(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: EdgeInsets.only(
                          left: 24, right: 24, bottom: subBottom),
                      child: Text(text,
                          textAlign: TextAlign.center, style: _subStyle),
                    ),
                  ),
                );
              },
            ),
            // Tap = pause/play, double tap = fullscreen
            Positioned.fill(
              child: GestureDetector(
                onTap: () {
                  player.playOrPause();
                  _poke();
                },
                onDoubleTap: () {
                // Toggling the window from inside the double-click gesture
                // desyncs Windows' pointer/raster handshake (frozen frames,
                // live audio). Let the click sequence fully settle, then
                // take the identical path the F key uses - which works.
                Future.delayed(const Duration(milliseconds: 320),
                    _toggleFullscreen);
              },
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
                                if (_desktop)
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
