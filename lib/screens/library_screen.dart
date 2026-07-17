import 'package:flutter/material.dart';
import '../config.dart';
import '../services/db.dart';
import '../services/trakt.dart';
import 'details_screen.dart';
import 'widgets.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
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
            title: const Text('Remove from library'),
            onTap: () {
              Db.removeItem(it['type'], it['id']);
              Trakt.pushStatus(it['type'], it['id'], 'removed');
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
    final items = Db.itemsByStatus(tab);

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(children: [
            const Text('Library',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            const Spacer(),
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
                final sub = vid.contains(':')
                    ? 'S${vid.split(':')[1]} · E${vid.split(':')[2]}'
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
              ChoiceChip(
                  label: const Text('All'),
                  selected: tab == null,
                  onSelected: (_) => setState(() => tab = null)),
              for (final s in statuses)
                ChoiceChip(
                    label: Text(s.$2),
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
