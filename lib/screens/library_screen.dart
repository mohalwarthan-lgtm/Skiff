import 'package:flutter/material.dart';
import '../config.dart';
import '../services/db.dart';
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

  @override
  Widget build(BuildContext context) {
    final cont = Db.continueWatching();
    final items = Db.itemsByStatus(tab);

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 18),
          child: Text('Library',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
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
                  child: PosterCard(
                    poster: c['poster'],
                    title: c['name'] ?? c['itemId'],
                    subtitle: sub,
                    progress: (c['duration'] ?? 0) > 0
                        ? (c['position'] as num) / (c['duration'] as num)
                        : null,
                    onTap: () => _open(c['type'], c['itemId']),
                  ),
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
              PosterCard(
                poster: it['poster'],
                title: it['name'] ?? it['id'],
                subtitle: statusLabel(it['status']),
                onTap: () => _open(it['type'], it['id']),
              ),
          ]),
      ],
    );
  }
}
