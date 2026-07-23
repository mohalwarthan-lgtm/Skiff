import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import '../services/addons.dart';
import '../services/db.dart';
import '../services/skips.dart';
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
  final Map? stream; // chosen stream (bingeGroup, labels)

  const PlayerScreen({
    super.key,
    required this.url,
    required this.title,
    required this.type,
    required this.itemId,
    required this.videoId,
    this.stream,
    this.headers = const {},
    this.addonSubs = const [],
    this.localSubs = const [],
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
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
    // A volume you set is a preference, not a per-episode whim.
    final vol = double.tryParse(Db.setting('volume') ?? '');
    if (vol != null) player.setVolume(vol.clamp(0, 100));
    // Let mpv render subtitles natively - honoring ASS positioning
    // (top-of-screen signs, background voices) as authored.
    try {
      (player.platform as dynamic).setProperty('sub-visibility', 'yes');
    } catch (_) {}
    _applySubStyle();
    Skips.intro(widget.type, widget.itemId, widget.videoId).then((v) {
      if (mounted && v != null) {
        setState(() {
          _intro = v;
          _introFrom = 'db';
        });
      }
    });
    Skips.outro(widget.type, widget.itemId, widget.videoId).then((v) {
      if (mounted && v != null) {
        setState(() {
          _outro = v;
          _outroFrom = 'db';
        });
      }
    });
    player.stream.position.listen((pos) {
      final d = player.state.duration.inMilliseconds;
      final ms = pos.inMilliseconds;
      if (!_chaptersTried && d > 0) {
        _chaptersTried = true;
        _chapterFallback(d);
      }
      final ready = _outro != null
          ? ms >= _outro!.$1 - 300000 // scout well before credits
          : (d > 0 && ms / d >= 0.60);
      if (ready && !_nextPrefetched && widget.type == 'series') {
        _nextPrefetched = true;
        _prepareNext();
      }
    });
    PlayerFlush.flush = _flushRef;
    WidgetsBinding.instance.addObserver(this);
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

  late final Future<void> Function() _flushRef = _flushStop;
  Timer? _checkpoint;
  (int, int)? _intro; // intro window (ms)
  (int, int)? _outro; // outro/credits window (ms)
  String _introFrom = '', _outroFrom = '';
  bool _chaptersTried = false;
  bool _introDismissed = false;
  Map? _next; // next episode: videoId/label/url/stream
  bool _nextPrefetched = false, _nextDismissed = false;
  Timer? _nextTimer;
  int _nextCountdown = 8;
  bool _switching = false; // texture detached during fullscreen switch

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Mobile equivalent of the desktop close-flush: the OS can kill a
    // backgrounded app without warning, so save the position now.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      Trakt.scrobble('pause', widget.type, widget.itemId, widget.videoId,
              _pct())
          .catchError((_) {});
    }
  }

  Future<void> _flushStop() async {
    try {
      await Trakt.scrobble(
          'stop', widget.type, widget.itemId, widget.videoId, _pct());
    } catch (_) {}
  }

  /// Many releases embed chapters named "Opening" / "Ending" / etc.
  /// When the crowd databases have nothing, the file itself often does -
  /// and it is exact for THIS encode, so no drift. Read through mpv's
  /// property interface; if the backend doesn't expose it, this silently
  /// does nothing.
  Future<void> _chapterFallback(int durMs) async {
    if (_intro != null && _outro != null) return;
    try {
      final p = player.platform as dynamic;
      final n = int.tryParse('${await p.getProperty('chapter-list/count')}') ?? 0;
      if (n <= 0) return;
      final titles = <String>[];
      final times = <double>[];
      for (var i = 0; i < n; i++) {
        titles.add('${await p.getProperty('chapter-list/$i/title')}');
        times.add(
            double.tryParse('${await p.getProperty('chapter-list/$i/time')}') ??
                -1);
      }
      final introRe =
          RegExp(r'\b(intro|opening|op|ncop|avant)\b', caseSensitive: false);
      final outroRe = RegExp(
          r'\b(outro|ending|credits|endcard|ed|nced|preview|next episode)\b',
          caseSensitive: false);
      int endOf(int i) =>
          ((i + 1 < n && times[i + 1] > times[i]) ? times[i + 1] * 1000 : durMs)
              .toInt();

      if (_intro == null) {
        for (var i = 0; i < n; i++) {
          if (times[i] < 0 || !introRe.hasMatch(titles[i])) continue;
          final a = (times[i] * 1000).toInt(), b = endOf(i);
          if (b - a < 5000 || b - a > 240000) continue; // sanity
          if (mounted) {
            setState(() {
              _intro = (a, b);
              _introFrom = 'chapters';
            });
          }
          break;
        }
      }
      if (_outro == null) {
        for (var i = n - 1; i >= 0; i--) {
          if (times[i] < 0 || !outroRe.hasMatch(titles[i])) continue;
          final a = (times[i] * 1000).toInt();
          if (a < durMs ~/ 2) continue; // credits belong to the tail
          if (mounted) {
            setState(() {
              _outro = (a, endOf(i));
              _outroFrom = 'chapters';
            });
          }
          break;
        }
      }
    } catch (_) {/* backend doesn't expose properties - fine */}
  }

  /// Decide the next episode and its stream - the same-release ladder:
  /// bingeGroup match, then quality tokens, then best instant option,
  /// else hand back to the picker.
  Future<void> _prepareNext() async {
    final mc = Db.cachedMeta(widget.type, widget.itemId);
    final vids = (mc?['videos'] as List? ?? [])
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
    // Semantic next, not positional next: merged-preset metadata can
    // carry duplicate/absolute-numbered twin rows, and "the row after
    // this one" silently switches lanes - wrong label, wrong id dialect
    // for skip lookups. Same season, episode+1; else next season, E1.
    Map? cur;
    for (final v in vids) {
      if ('${v['id']}' == widget.videoId) {
        cur = v;
        break;
      }
    }
    if (cur == null) return;
    final cs = (cur['season'] as num).toInt();
    final ce = (cur['episode'] as num?)?.toInt() ?? 0;
    // LANE-LOCK: metadata can hold twin rows for the same episode in
    // different id dialects (one often nameless). The next episode must
    // come from the SAME id family as the one playing now - so a binge
    // can never hop lanes (which broke skip lookups and dropped titles).
    final lane = widget.videoId.contains(':')
        ? widget.videoId.substring(
            0, widget.videoId.lastIndexOf(':') + 1)
        : '';
    Map? pickRow(int ws, int we) {
      Map? named, any;
      for (final v in vids) {
        if ((v['season'] as num).toInt() != ws ||
            ((v['episode'] as num?)?.toInt() ?? 0) != we) {
          continue;
        }
        if (lane.isNotEmpty && '${v['id']}'.startsWith(lane)) {
          return v; // same lane: always wins
        }
        if (named == null && v['name'] != null) named = v;
        any ??= v;
      }
      return named ?? any;
    }

    final nv = pickRow(cs, ce + 1) ?? pickRow(cs + 1, 1);
    if (nv == null) return;
    final rel = DateTime.tryParse('${nv['released'] ?? ''}');
    if (rel != null && rel.isAfter(DateTime.now())) return;
    final nid = '${nv['id']}';
    // Title format identical to a picker-launched episode.
    // Identical construction to the details screen: addons put the
    // episode title in 'title' (not 'name'), which is why the handoff
    // label kept coming out bare.
    final epTitle = '${nv['title'] ?? nv['name'] ?? ''}';
    final label = '${mc?['name'] ?? ''} — S${nv['season']} '
        'E${nv['episode']}'
        '${epTitle.isEmpty ? '' : ' · $epTitle'}';
    // streamsFor returns addon wrappers {'addon', 'streams': [...]} -
    // flatten to the actual streams.
    final streams = <Map>[];
    try {
      for (final g in await Addons.streamsFor(widget.type, nid)) {
        for (final st in (g['streams'] as List? ?? [])) {
          if (st is Map) streams.add(st);
        }
      }
    } catch (_) {}
    Map? pick;
    final bg = widget.stream?['behaviorHints']?['bingeGroup'];
    if (bg != null) {
      for (final st in streams) {
        if (st['behaviorHints']?['bingeGroup'] == bg &&
            st['url'] != null) {
          pick = st;
          break;
        }
      }
    }
    pick ??= _sameQuality(streams);
    if (pick == null) {
      for (final st in streams) {
        if (st['url'] != null &&
            st['behaviorHints']?['notWebReady'] != true) {
          pick = st;
          break;
        }
      }
    }
    if (!mounted) return;
    setState(() => _next = {
          'videoId': nid,
          'label': label,
          if (pick != null) 'url': pick['url'],
          if (pick != null) 'stream': pick,
        });
  }

  Map? _sameQuality(List<Map> streams) {
    final cur =
        '${widget.stream?['name'] ?? ''} ${widget.stream?['title'] ?? ''}'
            .toLowerCase();
    const toks = [
      'remux', 'bluray', 'bdrip', 'web-dl', 'webdl', 'webrip', 'hdtv',
      '2160', '1080', '720'
    ];
    final want = toks.where(cur.contains).toList();
    if (want.isEmpty) return null;
    for (final st in streams) {
      final t = '${st['name'] ?? ''} ${st['title'] ?? ''}'.toLowerCase();
      if (want.every(t.contains) && st['url'] != null) return st;
    }
    return null;
  }

  void _armNextTimer() {
    if (_nextTimer != null) return;
    _nextTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_nextCountdown <= 1) {
        _playNext();
      } else {
        setState(() => _nextCountdown--);
      }
    });
  }

  Future<void> _playNext() async {
    final n = _next;
    _nextTimer?.cancel();
    _nextTimer = null;
    if (n == null) return;
    if (n['url'] == null) {
      // No confident same-release pick - back to the episode list,
      // where the picker keeps you in charge.
      Navigator.pop(context);
      return;
    }
    // Continuity: the next episode deserves everything the first one
    // had - its own addon subtitles and the stream's request headers.
    final subs = await Addons.subtitlesFor(widget.type, '${n['videoId']}')
        .catchError((_) => <Map>[]);
    final ph = (n['stream'] as Map?)?['behaviorHints']?['proxyHeaders']
        ?['request'];
    final headers = ph is Map
        ? ph.map((k, v) => MapEntry('$k', '$v'))
        : <String, String>{};
    if (!mounted) return;
    Navigator.pushReplacement(
        context,
        MaterialPageRoute(
            builder: (_) => PlayerScreen(
                  url: '${n['url']}',
                  title: '${n['label']}',
                  type: widget.type,
                  itemId: widget.itemId,
                  videoId: '${n['videoId']}',
                  headers: headers,
                  addonSubs: subs,
                  stream: n['stream'] as Map?,
                )));
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
    WidgetsBinding.instance.removeObserver(this);
    _nextTimer?.cancel();
    _checkpoint?.cancel();
    // pushReplacement disposes the OLD screen after the NEW one has
    // registered - only clear the hook if it is still ours.
    if (identical(PlayerFlush.flush, _flushRef)) PlayerFlush.flush = null;
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

  /// Push the user's subtitle style into mpv's native renderer.
  /// sub-ass-override=yes applies size/outline/box to ASS subs while
  /// KEEPING authored positioning (top signs, background voices).
  void _applySubStyle() {
    // ASS scripts keep their authored styling, positioning, and
    // collision handling (the "piling" fix); the sliders govern
    // plain-text subtitles (SRT), where mpv's style options apply.
    _setMpv('sub-ass-override', 'no');
    _setMpv('sub-font-size', '${(subSize * 1.25).round()}');
    _setMpv('sub-border-size', subOutline.toStringAsFixed(1));
    final a = (subBg * 2.55).round().clamp(0, 255);
    _setMpv('sub-back-color',
        '#${a.toRadixString(16).padLeft(2, '0')}000000');
    _setMpv('sub-ass-force-style', ''); // never restyle ASS scripts
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
                    _applySubStyle(); // live on the video, natively
                    setD(() {});
                    setState(() {}); // live-preview on the video
                  },
                ),
              ),
            ]);
          }

          return AlertDialog(
            title: const Text('Subtitle style'),
            // Honest scope: ASS/SSA subtitles keep their authored
            // styling and positioning; these govern plain-text subs.
            contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                    'Applies to plain-text subtitles. ASS/SSA tracks '
                    'keep their own styling and placement.',
                    style: TextStyle(fontSize: 11, color: Colors.white54)),
              ),
              row('Size', subSize, 20, 80, 30, 'sub_size',
                  (v) => subSize = v),
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
                    // IgnorePointer: clicks must never reach the native
                    // texture surface - the overlay owns all input.
                    : IgnorePointer(
                        child: Video(
                        controller: controller!,
                        controls: NoVideoControls,
                        // We paint subtitles ourselves below - full control
                        // over position and style on every platform.
                        subtitleViewConfiguration:
                            const SubtitleViewConfiguration(
                                visible: false)))),
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
                                      onChanged: (v) {
                                        player.setVolume(v);
                                        Db.setSetting('volume', v.toString());
                                      },
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
                      // ---- Skip-data whisper (first seconds only): settles
            // "feature broken vs data absent" at a glance ----
            if (widget.type == 'series')
              StreamBuilder<Duration>(
                stream: player.stream.position,
                builder: (context, snap) {
                  final ms = (snap.data ?? Duration.zero).inMilliseconds;
                  if (ms <= 0 || ms > 8000) {
                    return const SizedBox.shrink();
                  }
                  return Positioned(
                    top: 14,
                    right: 18,
                    child: Text(
                      'skip · intro ${_intro != null ? '✓ $_introFrom' : '–'}'
                      ' · outro ${_outro != null ? '✓ $_outroFrom' : '–'}'
                      ' · ${Skips.lastLookup}',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.white38),
                    ),
                  );
                },
              ),
            // ---- Skip intro (SkipDB) ----
            if (_intro != null && !_introDismissed)
              StreamBuilder<Duration>(
                stream: player.stream.position,
                builder: (context, snap) {
                  final ms = (snap.data ?? Duration.zero).inMilliseconds;
                  if (ms < _intro!.$1 - 1000 || ms >= _intro!.$2) {
                    return const SizedBox.shrink();
                  }
                  return Positioned(
                    right: 24,
                    bottom: 110,
                    child: FilledButton.tonal(
                      onPressed: () {
                        player.seek(Duration(milliseconds: _intro!.$2));
                        player.play(); // never let the tap layer pause us
                        setState(() => _introDismissed = true);
                      },
                      child: const Text('Skip intro'),
                    ),
                  );
                },
              ),
            // ---- Up next ----
            if (_next != null && !_nextDismissed)
              StreamBuilder<Duration>(
                stream: player.stream.position,
                builder: (context, snap) {
                  final d = player.state.duration.inMilliseconds;
                  final ms = (snap.data ?? Duration.zero).inMilliseconds;
                  // Crowd-marked outro start when known; 92% otherwise.
                  final due = _outro != null
                      ? ms >= _outro!.$1
                      : (d > 0 && ms / d >= 0.92);
                  if (!due) return const SizedBox.shrink();
                  return Positioned(
                    right: 24,
                    bottom: 110,
                    child: Material(
                      color: const Color(0xE6141B26),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Up next',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.white54)),
                              const SizedBox(height: 2),
                              Text('${_next!['label']}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 8),
                              Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    FilledButton(
                                        onPressed: _playNext,
                                        child: Text(_next!['url'] != null
                                            ? 'Play next'
                                            : 'Choose stream')),
                                    const SizedBox(width: 8),
                                    TextButton(
                                        onPressed: () {
                                          _nextTimer?.cancel();
                                          setState(() =>
                                              _nextDismissed = true);
                                        },
                                        child: const Text('Cancel')),
                                  ]),
                            ]),
                      ),
                    ),
                  );
                },
              ),
          ]),
        ),
      ),
    );
  }
}
