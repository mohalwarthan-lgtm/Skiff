import 'package:flutter/material.dart';
import '../config.dart';
import '../services/db.dart';
import '../services/addons.dart';
import '../services/trakt.dart';
import 'details_screen.dart';
import 'widgets.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  bool _hydrating = false;

  @override
  void initState() {
    super.initState();
    _hydrateMissingMeta();
  }

  /// A fresh device synced from Trakt has library ids but no local
  /// metadata yet — fetch it from the add-ons, a few titles at a time,
  /// and fill in names and posters as they arrive.
  int _hydDone = 0, _hydTotal = 0;
  String _q = '';
  int _shown = 0;

  Future<void> _hydrateMissingMeta() async {
    if (_hydrating) return;
    _hydrating = true;
    try {
      final missing = Db.items.values
          .cast<Map>()
          .where((it) =>
              Db.cachedMeta(it['type'], it['id']) == null ||
              it['alProgress'] != null)
          .toList();
      if (missing.isNotEmpty && mounted) {
        setState(() {
          _hydTotal = missing.length;
          _hydDone = 0;
        });
      }
      for (var i = 0; i < missing.length; i += 4) {
        if (mounted) setState(() => _hydDone = i);
        await Future.wait([
          for (final it in missing.skip(i).take(4))
            () async {
              try {
                var m = Db.cachedMeta(it['type'], it['id'])
                    ?.cast<String, dynamic>();
                if (m == null) {
                  m = await Addons.metaFor(it['type'], it['id']);
                  Db.cacheMeta(it['type'], it['id'], m);
                  Db.touchItem(it['type'], it['id'],
                      name: m['name'], poster: m['poster']);
                }
                // AniList import: turn the episodes-watched count into
                // ticks on the show's REAL episode ids.
                final n = (it['alProgress'] as num?)?.toInt() ?? 0;
                if (n != 0) {
                  final vids = (m['videos'] as List? ?? [])
                      .whereType<Map>()
                      .where((v) =>
                          ((v['season'] as num?)?.toInt() ?? 0) > 0)
                      .toList()
                    ..sort((a, b) {
                      final sa = (a['season'] as num).toInt(),
                          sb = (b['season'] as num).toInt();
                      return sa != sb
                          ? sa - sb
                          : ((a['episode'] as num?)?.toInt() ?? 0) -
                              ((b['episode'] as num?)?.toInt() ?? 0);
                    });
                  final toTick = n == -1
                      ? vids.where((v) {
                          final rel = DateTime.tryParse(
                              '${v['released'] ?? ''}');
                          return rel == null ||
                              !rel.isAfter(DateTime.now());
                        }).toList()
                      : vids.take(n).toList();
                  for (final v in toTick) {
                    Db.markWatched(
                        it['type'], it['id'], '${v['id']}', true);
                  }
                  final k = '${it['type']}|${it['id']}';
                  final rec = Map.of(Db.items.get(k) as Map)
                    ..remove('alProgress');
                  await Db.items.put(k, rec);
                }
              } catch (_) {/* no capable add-on yet - retried next open */}
            }(),
        ]);
        if (mounted) setState(() {});
      }
    } finally {
      if (mounted) setState(() => _hydTotal = 0);
    _hydrating = false;
    }
  }

  String? tab; // null = all

  void _open(String type, String id) async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => DetailsScreen(type: type, id: id)));
    setState(() {});
  }

  /// Right-click / long-press menu: move shelf, remove — mirrored to Trakt.
  void _editItem(Map it) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              title: Text(it['name'] ?? it['id'],
                  style: const TextStyle(fontWeight: FontWeight.w600))),
          for (final s in statuses)
            ListTile(
              leading: Icon(it['status'] == s.$1
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off),
              title: Text(s.$2),
              onTap: () {
                Db.setStatus(it['type'], it['id'], s.$1);
                Trakt.pushStatus(it['type'], it['id'], s.$1);
                Navigator.pop(context);
                setState(() {});
              },
            ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Remove from library & Trakt'),
            onTap: () {
              Db.removeItem(it['type'], it['id']);
              Trakt.pushRemoval(it['type'], it['id']);
              Navigator.pop(context);
              setState(() {});
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cont = Db.continueWatching();
    var items = Db.itemsByStatus(tab);
    if (_q.isNotEmpty) {
      final q = _q.toLowerCase();
      items = items
          .where((it) => '${it['name'] ?? ''}'.toLowerCase().contains(q))
          .toList();
    }
    items.sort((a, b) => '${a['name'] ?? ''}'
        .toLowerCase()
        .compareTo('${b['name'] ?? ''}'.toLowerCase()));
    _shown = items.length;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: TextField(
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: 'Search your library',
              border: const OutlineInputBorder(),
              suffixText: _q.isEmpty ? null : '$_shown shown',
              suffixStyle:
                  const TextStyle(fontSize: 12, color: Colors.white38),
            ),
            onChanged: (v) => setState(() => _q = v.trim()),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(children: [
            const Text('Library',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            const Spacer(),
            // Cataloguing sweep: episode lists (and AniList ticks) being
            // filled in - lets you see it's working, and when it's done.
            if (_hydTotal > 0)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  'Cataloguing $_hydDone/$_hydTotal…',
                  style: const TextStyle(
                      fontSize: 12, color: Colors.white54),
                ),
              ),
            // Live Trakt sync status, so you can close the app knowing
            // whether your shelves made it to Trakt.
            ValueListenableBuilder<String>(
              valueListenable: Trakt.syncStatus,
              builder: (_, status, __) => Row(children: [
                if (Trakt.connected) ...[
                  Icon(
                      status.startsWith('Push failed')
                          ? Icons.sync_problem
                          : status == 'Syncing…'
                              ? Icons.sync
                              : Icons.cloud_done_outlined,
                      size: 15),
                  const SizedBox(width: 6),
                  Text(status.isEmpty ? 'Trakt connected' : status,
                      style:
                          TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                  IconButton(
                    icon: const Icon(Icons.sync, size: 16),
                    tooltip: 'Sync with Trakt now (push your library, then pull)',
                    onPressed: () async {
                      // Push the local library up first, then reconcile down.
                      await Trakt.pushLibrary().catchError((_) {});
                      await Trakt.pullAll().catchError((e) {
                        Trakt.syncStatus.value = 'Sync failed';
                        return '';
                      });
                      if (mounted) setState(() {});
                    },
                  ),
                ] else
                  Text('Trakt not connected',
                      style: TextStyle(
                          fontSize: 12, color: Theme.of(context).hintColor)),
              ]),
            ),
          ]),
        ),
        if (cont.isNotEmpty && tab == null) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 20, 18, 8),
            child: Text('CONTINUE WATCHING',
                style: TextStyle(fontSize: 12, letterSpacing: 1.5)),
          ),
          SizedBox(
            height: 250,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              itemCount: cont.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (_, i) {
                final c = cont[i];
                final vid = c['videoId'] as String;
                final parts = vid.split(':');
                final sub = parts.length >= 3
                    ? (parts.first.startsWith('tt')
                        ? 'S${parts[1]} · E${parts[2]}'
                        : 'E${parts.last}')
                    : null;
                return SizedBox(
                  width: 140,
                  child: Stack(children: [
                    PosterCard(
                      poster: c['poster'],
                      title: c['name'] ?? c['itemId'],
                      subtitle: sub,
                      progress: (c['duration'] ?? 0) > 0
                          ? (c['position'] as num) / (c['duration'] as num)
                          : ((c['pct'] ?? 0) as num) > 0
                              ? ((c['pct'] as num) / 100)
                              : null,
                      onTap: () => _open(c['type'], c['itemId']),
                    ),
                    Positioned(
                      top: 2,
                      right: 2,
                      child: IconButton(
                        icon: const Icon(Icons.close, size: 15),
                        tooltip: 'Remove from Continue Watching',
                        style: IconButton.styleFrom(
                            backgroundColor: Colors.black54),
                        onPressed: () {
                          Db.dismissContinue(
                              c['type'], c['itemId'], c['videoId']);
                          // Also clear it from Trakt's Continue Watching.
                          Trakt.clearPlayback(c['itemId']);
                          setState(() {});
                        },
                      ),
                    ),
                  ]),
                );
              },
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 4),
          child: Wrap(
            spacing: 8,
            children: [
              // Clean chips; only the SELECTED one carries its count.
              ChoiceChip(
                  label: Text(tab == null
                      ? 'All · ${Db.itemsByStatus(null).length}'
                      : 'All'),
                  selected: tab == null,
                  onSelected: (_) => setState(() => tab = null)),
              for (final s in statuses)
                ChoiceChip(
                    label: Text(tab == s.$1
                        ? '${s.$2} · ${Db.itemsByStatus(s.$1).length}'
                        : s.$2),
                    selected: tab == s.$1,
                    onSelected: (_) => setState(() => tab = s.$1)),
            ],
          ),
        ),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(60),
            child: Center(
                child: Text(
                    'Nothing here yet. Set a status from any title, '
                    'or connect Trakt in Settings to import your history.')),
          )
        else
          PosterGrid(shrinkWrap: true, children: [
            for (final it in items)
              GestureDetector(
                onLongPress: () => _editItem(it),
                onSecondaryTap: () => _editItem(it),
                child: PosterCard(
                  poster: it['poster'],
                  title: it['name'] ?? it['id'],
                  subtitle: statusLabel(it['status']),
                  onTap: () => _open(it['type'], it['id']),
                ),
              ),
          ]),
      ],
    );
  }
}
