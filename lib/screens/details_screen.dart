import 'package:flutter/material.dart';
import '../config.dart';
import '../services/addons.dart';
import '../services/db.dart';
import '../services/downloads.dart';
import '../services/net.dart';
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
  bool offline = false;

  @override
  void initState() {
    super.initState();
    Addons.metaFor(widget.type, widget.id).then((m) {
      if (!mounted) return;
      // Cache the essentials so the library works with no internet.
      Db.cacheMeta(widget.type, widget.id, m);
      Db.touchItem(widget.type, widget.id,
          name: m['name'], poster: m['poster']);
      setState(() {
        meta = m;
        final seasons = _seasons(m);
        season = _startingSeason(m, seasons);
      });
    }).catchError((e) {
      if (!mounted) return;
      // Offline (or addon down): fall back to the cached copy.
      final cached = Db.cachedMeta(widget.type, widget.id);
      if (cached != null) {
        setState(() {
          meta = cached.cast<String, dynamic>();
          offline = true;
          final seasons = _seasons(meta!);
          season = _startingSeason(meta!, seasons);
        });
      } else {
        setState(() => error = '$e');
      }
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

  /// Batch-download the selected season: pick from the qualities actually
  /// on offer; per episode the queue takes the top-ranked stream of that
  /// quality - and since AIOStreams sorts cached links, language, and
  /// sources per your setup, the top match is the best cached one.
  bool selecting = false;
  final selected = <String>{};

  /// Relation links some metadata add-ons provide (prequels, sequels,
  /// franchise entries) - rendered as chips for one-tap navigation.
  Widget _relatedLinks(Map m) {
    final rel = <(String, String, String, String)>[];
    for (final l in (m['links'] as List? ?? [])) {
      if (l is! Map) continue;
      final url = l['url'] as String? ?? '';
      if (!url.startsWith('stremio:///detail/')) continue;
      final parts = url.substring('stremio:///detail/'.length).split('/');
      if (parts.length < 2) continue;
      rel.add((
        '${l['category'] ?? 'Related'}',
        '${l['name'] ?? parts[1]}',
        parts[0],
        Uri.decodeComponent(parts[1]),
      ));
    }
    if (rel.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('RELATED',
            style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.5,
                color: Theme.of(context).hintColor)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final r in rel)
            ActionChip(
              label: Text(
                  r.$1.toLowerCase() == r.$2.toLowerCase()
                      ? r.$2
                      : '${r.$1} · ${r.$2}',
                  style: const TextStyle(fontSize: 12)),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => DetailsScreen(type: r.$3, id: r.$4))),
            ),
        ]),
      ]),
    );
  }

  Future<void> _downloadSeason() async {
    final m = meta;
    if (m == null || season == null) return;
    final eps = (m['videos'] as List? ?? [])
        .where((v) => v['season'] == season)
        .toList()
      ..sort((a, b) =>
          ((a['episode'] ?? 0) as num).compareTo((b['episode'] ?? 0) as num));
    await _batchDownload(eps);
  }

  Future<void> _downloadSelected() async {
    final m = meta;
    if (m == null || selected.isEmpty) return;
    final eps = (m['videos'] as List? ?? [])
        .where((v) => selected.contains(v['id']))
        .toList()
      ..sort((a, b) {
        final bySeason =
            ((a['season'] ?? 0) as num).compareTo((b['season'] ?? 0) as num);
        if (bySeason != 0) return bySeason;
        return ((a['episode'] ?? 0) as num)
            .compareTo((b['episode'] ?? 0) as num);
      });
    setState(() => selecting = false);
    await _batchDownload(eps);
    selected.clear();
  }

  void _markSelected(bool watched) {
    for (final vid in selected) {
      Db.markWatched(widget.type, widget.id, vid, watched);
      Trakt.pushWatched(widget.type, widget.id, vid, watched);
    }
    setState(() {
      selecting = false;
      selected.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(watched
            ? 'Marked as watched.'
            : 'Marked as unwatched.'),
        duration: const Duration(seconds: 2)));
  }

  /// Release types recognized in stream labels (first match wins).
  static const _relTypes = [
    ('Remux', ['remux']),
    ('BluRay', ['bluray', 'blu-ray', 'blu ray']),
    ('BDRip', ['bdrip', 'brrip']),
    ('WEB-DL', ['web-dl', 'webdl', 'web dl']),
    ('WEBRip', ['webrip']),
    ('HDTV', ['hdtv']),
  ];

  /// Cached = playable right now: has a direct url and the add-on does
  /// not flag it as needing processing (uncached results are marked
  /// notWebReady by the add-on).
  bool _cachedOf(Map st) =>
      st['url'] != null && st['behaviorHints']?['notWebReady'] != true;

  /// Label for a picked stream: the add-on's group label when present,
  /// else best-effort from its text.
  String _pickLabel(Map pick, String quality, String Function(String) lab) {
    final g = '${pick['behaviorHints']?['bingeGroup'] ?? ''}';
    if (g.isNotEmpty) return lab(g);
    return _qualityOf('${pick['name']} ${pick['title']} ${pick['description']}'
        .toLowerCase());
  }

  /// Best-effort "1080p BluRay" style label from a stream's text.
  String _qualityOf(String text) {
    const resOrder = ['2160p', '4k', '1080p', '720p', '480p'];
    for (final r in resOrder) {
      if (!text.contains(r)) continue;
      final label = r == '4k' ? '4K' : r;
      for (final rt in _relTypes) {
        if (rt.$2.any(text.contains)) return '$label ${rt.$1}';
      }
      return label;
    }
    return '';
  }

  /// "1080p BluRay" -> resolution AND any of that type's tokens.
  bool _matchesQuality(String text, String q) {
    final parts = q.toLowerCase().split(' ');
    if (!text.contains(parts.first)) return false;
    if (parts.length == 1) return true;
    final typeLabel = q.substring(q.indexOf(' ') + 1);
    for (final rt in _relTypes) {
      if (rt.$1 == typeLabel) return rt.$2.any(text.contains);
    }
    return true;
  }

  /// The season the viewer is "at": first unwatched, already-released
  /// episode; falls back to the first season.
  int _startingSeason(Map m, List<int> seasons) {
    final vids = (m['videos'] as List? ?? [])
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
    for (final v in vids) {
      if (Db.isWatched(widget.type, widget.id, '${v['id']}')) continue;
      final rel = DateTime.tryParse('${v['released'] ?? ''}');
      if (rel != null && rel.isAfter(DateTime.now())) continue;
      return (v['season'] as num).toInt();
    }
    return seasons.firstWhere((x) => x > 0,
        orElse: () => seasons.isEmpty ? 1 : seasons.first);
  }

  Future<void> _batchDownload(List eps) async {
    final m = meta;
    if (m == null || eps.isEmpty) return;

    String textOf(Map st) =>
        '${st['name'] ?? ''} ${st['title'] ?? ''} ${st['description'] ?? ''}'
            .toLowerCase();

    // Check every selected episode so only combinations available for the
    // whole batch are offered - all downloads come out one quality.
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text('Checking qualities across ${eps.length} episodes…'),
        duration: const Duration(seconds: 3)));
    final perEp = <List<Map>>[];
    for (var i = 0; i < eps.length; i += 4) {
      perEp.addAll(await Future.wait([
        for (final v in eps.skip(i).take(4))
          () async {
            try {
              final groups =
                  await Addons.streamsFor(widget.type, v['id']);
              return [for (final g in groups) ...(g['streams'] as List)]
                  .whereType<Map>().where(_cachedOf)
                  .toList();
            } catch (_) {
              return <Map>[];
            }
          }(),
      ]));
    }

    String groupOf(Map st) => '${st['behaviorHints']?['bingeGroup'] ?? ''}';
    String labelOf(String g) {
      if (!g.contains('|')) return g;
      final parts = g.split('|').sublist(1);
      return parts.where((e) => e.trim().isNotEmpty).join(' · ');
    }

    // Primary: the add-on's own quality groups, in the add-on's own order.
    final orderedGroups = <String>[];
    if (perEp.isNotEmpty) {
      for (final st in perEp.first) {
        final g = groupOf(st);
        if (g.isNotEmpty && !orderedGroups.contains(g)) {
          orderedGroups.add(g);
        }
      }
    }
    Set<String>? commonG;
    for (final flat in perEp) {
      if (flat.isEmpty) continue;
      final c = {
        for (final st in flat)
          if (groupOf(st).isNotEmpty) groupOf(st)
      };
      commonG = commonG == null ? c : commonG.intersection(c);
    }
    final groupFound = [
      for (final g in orderedGroups)
        if ((commonG ?? const {}).contains(g)) g
    ];

    const resOrder = ['2160p', '4k', '1080p', '720p', '480p'];
    Set<String> combosOf(List<Map> flat) {
      final out = <String>{};
      for (final r in resOrder) {
        final label = r == '4k' ? '4K' : r;
        var covered = false;
        for (final rt in _relTypes) {
          if (flat.any((st) =>
              textOf(st).contains(r) && rt.$2.any(textOf(st).contains))) {
            out.add('$label ${rt.$1}');
            covered = true;
          }
        }
        if (!covered && flat.any((st) => textOf(st).contains(r))) {
          out.add(label);
        }
      }
      return out;
    }

    Set<String>? common;
    for (final flat in perEp) {
      if (flat.isEmpty) continue; // don't let one failed fetch empty it all
      final c = combosOf(flat);
      common = common == null ? c : common.intersection(c);
    }
    // Text tokens only as a fallback for add-ons without quality groups.
    final found = groupFound.isNotEmpty
        ? groupFound
        : <String>[
            for (final r in resOrder)
              for (final label in [
                for (final rt in _relTypes)
                  '${r == '4k' ? '4K' : r} ${rt.$1}',
                r == '4k' ? '4K' : r,
              ])
                if ((common ?? const {}).contains(label)) label
          ];

    // Self-diagnosis: if no release types were recognized, surface a raw
    // stream label so the wording can be read and the detector taught.
    final hasCombos =
        found.any((f) => f.contains('|') || f.contains(' '));
    var sampleText = '';
    for (final flat in perEp) {
      if (flat.isNotEmpty) {
        sampleText = textOf(flat.first).trim();
        if (sampleText.length > 140) {
          sampleText = sampleText.substring(0, 140) + '…';
        }
        break;
      }
    }

    if (found.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No cached quality is available for every '
                'selected episode.')));
      }
      return;
    }

    var quality = Db.setting('batch_quality') ?? '';
    if (!found.contains(quality)) {
      quality = found.first;
    }
    var skipWatched = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          title: Text('Download ${eps.length} episode${eps.length == 1 ? '' : 's'}'),
          content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Quality'),
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: [
                  for (final q in found)
                    ChoiceChip(
                      label: Text(labelOf(q)),
                      selected: quality == q,
                      onSelected: (_) => setD(() => quality = q),
                    ),
                ]),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Skip watched episodes'),
                  value: skipWatched,
                  onChanged: (v) => setD(() => skipWatched = v ?? true),
                ),
                const SizedBox(height: 4),
                Text(
                    'Only qualities available for every selected episode '
                    'are offered - the whole batch downloads in one '
                    'quality, cached streams only, top per your ranking.',
                    style: TextStyle(
                        fontSize: 12, color: Theme.of(context).hintColor)),
                if (!hasCombos && sampleText.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('No release types recognized. Sample label: "'
                      '$sampleText"',
                      style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).hintColor)),
                ],
              ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Queue downloads')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    Db.setSetting('batch_quality', quality);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Queuing ${eps.length} episode${eps.length == 1 ? '' : 's'} — they download one by '
              'one. Track them in the Downloads tab.')));
    }

    // Sequential background queue: one episode at a time.
    () async {
      for (final v in eps) {
        final vid = v['id'] as String;
        if (Downloads.isDownloaded(widget.type, widget.id, vid)) continue;
        if (skipWatched && Db.isWatched(widget.type, widget.id, vid)) continue;
        try {
          final groups = await Addons.streamsFor(widget.type, vid);
          final flat = [for (final g in groups) ...(g['streams'] as List)]
              .whereType<Map>().where(_cachedOf)
              .toList();
          Map? pick;
          for (final st in flat) {
            final g = '${st['behaviorHints']?['bingeGroup'] ?? ''}';
            if (st['url'] != null &&
                (g == quality || _matchesQuality(textOf(st), quality))) {
              pick = st;
              break;
            }
          }
          // Chosen quality missing for this episode? Skip rather than
          // silently mixing qualities.
          if (pick == null) continue;
          final hinted = pick['behaviorHints']?['proxyHeaders']?['request'];
          final headers = hinted is Map
              ? hinted.map((k, val) => MapEntry('$k', '$val'))
              : <String, String>{};
          final url = await Net.finalUrl(pick['url'], headers);
          final subs = await Addons.subtitlesFor(widget.type, vid)
              .catchError((_) => <Map>[]);
          await Downloads.start(
            type: widget.type,
            itemId: widget.id,
            videoId: vid,
            url: url,
            displayName: m['name'] ?? widget.id,
            videoTitle:
                'S${v['season']} E${v['episode']} · ${v['title'] ?? v['name'] ?? ''}'
                '${_pickLabel(pick, quality, labelOf).isEmpty ? '' : ' · ${_pickLabel(pick, quality, labelOf)}'}',
            poster: m['poster'],
            headers: headers,
            subs: subs,
          );
        } catch (_) {/* one bad episode should not stop the season */}
      }
    }();
  }

  Future<void> _openStreams(String videoId, String videoTitle) async {
    // Make sure the item carries display info before any progress rows are
    // written, so Continue Watching never shows a bare tt-id.
    if (Db.itemStatus(widget.type, widget.id) == null) {
      Db.setStatus(widget.type, widget.id, 'watching',
          name: meta?['name'], poster: meta?['poster']);
    } else {
      Db.touchItem(widget.type, widget.id,
          name: meta?['name'], poster: meta?['poster']);
    }
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
    ].whereType<String>().join('  ·  ');

    final bg = m['background'] ?? m['poster'];
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.all(6),
          child: CircleAvatar(
            backgroundColor: const Color(0xCC0A1522),
            child: BackButton(color: Colors.white.withOpacity(0.95)),
          ),
        ),
      ),
      extendBodyBehindAppBar: true,
      body: Stack(fit: StackFit.expand, children: [
        if (bg != null)
          Image.network(bg,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, __, ___) => const SizedBox()),
        const DecoratedBox(
            decoration: BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.0, 0.45, 1.0],
                    colors: [
              Color(0xB30A1522),
              Color(0xE60A1522),
              Color(0xFF0A1522)
            ]))),
        Material(
          type: MaterialType.transparency,
          child: ListView(
        padding: EdgeInsets.fromLTRB(
            18,
            kToolbarHeight + MediaQuery.paddingOf(context).top + 26,
            18,
            18),
        children: [
          if (offline)
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(8)),
              child: const Row(children: [
                Icon(Icons.cloud_off, size: 16),
                SizedBox(width: 8),
                Text('Offline — showing saved details. Downloads still play.'),
              ]),
            ),
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
                    if (m['logo'] != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Image.network(m['logo'],
                              height: 54,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) =>
                                  const SizedBox()),
                        ),
                      ),
                    Text(m['name'] ?? '',
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(metaLine, style: TextStyle(color: Theme.of(context).hintColor)),
                    const SizedBox(height: 10),
                    if ((m['genres'] as List?)?.isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final g in (m['genres'] as List).take(6))
                            Chip(
                                label: Text('$g',
                                    style: const TextStyle(fontSize: 12)),
                                visualDensity: VisualDensity.compact,
                                backgroundColor: const Color(0x14FFFFFF),
                                side: const BorderSide(
                                    color: Color(0x22FFFFFF))),
                        ]),
                      ),
                    if (m['description'] != null) Text(m['description']),
                    if ((m['cast'] as List?)?.isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final c in (m['cast'] as List).take(10))
                            Chip(
                                label: Text('$c',
                                    style: const TextStyle(fontSize: 11)),
                                visualDensity: VisualDensity.compact,
                                backgroundColor: const Color(0x0DFFFFFF),
                                side: const BorderSide(
                                    color: Color(0x1AFFFFFF))),
                        ]),
                      ),
                    _relatedLinks(m),
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
                            Trakt.pushRemoval(widget.type, widget.id);
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
              const Spacer(),
              if (!selecting) ...[
                IconButton(
                    icon: const Icon(Icons.checklist, size: 20),
                    tooltip: 'Select episodes',
                    onPressed: () => setState(() => selecting = true)),
                TextButton.icon(
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('Download season'),
                    onPressed: _downloadSeason),
              ] else ...[
                TextButton(
                    onPressed: () => setState(() => selected
                      ..clear()
                      ..addAll([for (final v in videos) v['id'] as String])),
                    child: const Text('All')),
                TextButton(
                    onPressed: () => setState(() => selected.clear()),
                    child: const Text('None')),
                Text('${selected.length}',
                    style: TextStyle(
                        color: Theme.of(context).hintColor, fontSize: 12)),
                IconButton(
                    icon: const Icon(Icons.download_outlined, size: 20),
                    tooltip: 'Download selected',
                    onPressed: selected.isEmpty ? null : _downloadSelected),
                IconButton(
                    icon: const Icon(Icons.check_circle_outline, size: 20),
                    tooltip: 'Mark selected watched',
                    onPressed:
                        selected.isEmpty ? null : () => _markSelected(true)),
                IconButton(
                    icon: const Icon(Icons.remove_done, size: 20),
                    tooltip: 'Mark selected unwatched',
                    onPressed:
                        selected.isEmpty ? null : () => _markSelected(false)),
                TextButton(
                    onPressed: () => setState(() {
                          selecting = false;
                          selected.clear();
                        }),
                    child: const Text('Cancel')),
              ],
            ]),
            const SizedBox(height: 6),
            for (final v in videos)
              _EpisodeTile(
                type: widget.type,
                itemId: widget.id,
                video: v,
                selecting: selecting,
                isSelected: selected.contains(v['id']),
                onSelectToggle: () => setState(() {
                  final id = v['id'] as String;
                  selected.contains(id)
                      ? selected.remove(id)
                      : selected.add(id);
                }),
                onStartSelect: () => setState(() {
                  selecting = true;
                  selected.add(v['id'] as String);
                }),
                onPlay: () => _openStreams(
                    v['id'],
                    'S${v['season']} E${v['episode']} · ${v['title'] ?? v['name'] ?? ''}'),
                onChanged: () => setState(() {}),
              ),
          ],
        ],
          ),
        ),
      ]),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  final String type, itemId;
  final Map video;
  final bool selecting, isSelected;
  final VoidCallback onPlay, onChanged, onSelectToggle, onStartSelect;
  const _EpisodeTile(
      {required this.type,
      required this.itemId,
      required this.video,
      required this.selecting,
      required this.isSelected,
      required this.onSelectToggle,
      required this.onStartSelect,
      required this.onPlay,
      required this.onChanged});

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  @override
  Widget build(BuildContext context) {
    final vid = video['id'] as String;
    final watched = Db.isWatched(type, itemId, vid);
    final downloaded = Downloads.isDownloaded(type, itemId, vid);
    final p = Db.prog(type, itemId, vid);
    final pos = (p?['position'] ?? 0.0) as num;
    final dur = (p?['duration'] ?? 0.0) as num;

    // Release date from the metadata add-on ('released' per episode).
    final rel = DateTime.tryParse('${video['released'] ?? ''}');
    final upcoming = rel != null && rel.isAfter(DateTime.now());
    final relStr = rel == null
        ? null
        : '${rel.day} ${_months[rel.month - 1]} ${rel.year}';

    final hint = Theme.of(context).hintColor;
    return ListTile(
      dense: true,
      leading: selecting
          ? Checkbox(value: isSelected, onChanged: (_) => onSelectToggle())
          : Text('E${(video['episode'] ?? '').toString().padLeft(2, '0')}',
              style: const TextStyle(fontFamily: 'monospace')),
      title: Text(video['title'] ?? video['name'] ?? vid,
          style: upcoming ? TextStyle(color: hint) : null),
      subtitle: (dur > 0 && !watched && pos > 60)
          ? LinearProgressIndicator(
              value: (pos / dur).clamp(0, 1).toDouble(), minHeight: 2)
          : relStr != null
              ? Text(upcoming ? 'Upcoming · $relStr' : relStr,
                  style: TextStyle(fontSize: 11, color: hint))
              : null,
      hoverColor: const Color(0x1F35D6E8),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (downloaded)
          const Icon(Icons.download_done, size: 18, color: Color(0xFF63C589)),
        IconButton(
          icon: Icon(watched ? Icons.check_circle : Icons.check_circle_outline,
              color: watched ? const Color(0xFF63C589) : null),
          tooltip: watched ? 'Watched — click to unmark' : 'Mark watched',
          onPressed: () {
            Db.markWatched(type, itemId, vid, !watched);
            Trakt.pushWatched(type, itemId, vid, !watched);
            onChanged();
          },
        ),
      ]),
      onLongPress: selecting ? null : onStartSelect,
      onTap: selecting ? onSelectToggle : onPlay,
    );
  }
}

/// Bottom sheet listing streams from every enabled addon, with Play and
/// Download actions per stream.
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
    final raw = s['url'] as String?;
    if (raw == null) {
      throw 'This stream is torrent-only with no direct link. Pick one of '
          'the AIOStreams entries instead — your debrid services are '
          'configured there and those streams play directly.';
    }
    // Addon /resolve endpoints answer with redirects or a text body holding
    // the real CDN link — walk that chain so the player gets a direct URL.
    if (mounted) setState(() => busy = 'Resolving stream…');
    try {
      return await Net.finalUrl(raw, _headers(s));
    } finally {
      if (mounted) setState(() => busy = null);
    }
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
          stream: s, // identity for the same-release Up Next ladder
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
          hoverColor: const Color(0x1235D6E8),
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
