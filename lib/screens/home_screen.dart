import 'package:flutter/material.dart';
import '../services/addons.dart';
import '../services/db.dart';
import 'catalog_screen.dart';
import 'details_screen.dart';
import 'search_screen.dart';
import 'widgets.dart';

/// Home: continue-watching first, then one horizontal row per catalog from
/// your metadata add-ons (AIOMetadata etc.) — a browsable front page.
String? _epLabel(String vid) {
  final parts = vid.split(':');
  if (parts.length < 3) return null;
  return parts.first.startsWith('tt')
      ? 'S${parts[1]} · E${parts[2]}'
      : 'E${parts.last}';
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map> rows = []; // {transportUrl, addonName, type, id, name, hasSearch, future}

  @override
  void initState() {
    super.initState();
    _build();
  }

  /// A catalog belongs on the Home board only when it can be fetched with
  /// no parameters. Catalogs that REQUIRE an extra (genre, language, year,
  /// studio...) are Discover material — this mirrors how the addon itself
  /// marks "show in home" in its manifest, so nothing is hardcoded.
  static bool _isBoardCatalog(Map c) {
    final extras = (c['extra'] as List?) ?? [];
    final requiresParam = extras.any((e) =>
        e is Map && e['isRequired'] == true && e['name'] != 'search');
    // Legacy manifests express the same via extraRequired: [...].
    final legacyRequired = ((c['extraRequired'] as List?) ?? [])
        .any((n) => n != 'search');
    return !requiresParam && !legacyRequired;
  }

  void _build() {
    rows = [
      for (final a in Addons.enabled())
        for (final c in ((a['manifest'] as Map)['catalogs'] as List? ?? []))
          if (_isBoardCatalog(c))
            {
              'transportUrl': a['transportUrl'],
              'addonName': (a['manifest'] as Map)['name'],
              'type': c['type'],
              'id': c['id'],
              'name': c['name'] ?? c['id'],
              'hasSearch': ((c['extra'] as List?) ?? [])
                  .any((e) => e is Map && e['name'] == 'search'),
            }
    ].take(16).toList();
    // Kick off all fetches once; rows render as they arrive.
    for (final r in rows) {
      r['future'] = Addons.fetchCatalog(r['transportUrl'], r['type'], r['id'])
          .catchError((_) => <dynamic>[]);
    }
    setState(() {});
  }

  void _openDetails(String type, String id) async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => DetailsScreen(type: type, id: id)));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cont = Db.continueWatching();
    return RefreshIndicator(
      onRefresh: () async => _build(),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(children: [
              const Text('Home',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
              const Spacer(),
              SizedBox(
                width: 240,
                child: TextField(
                  decoration: const InputDecoration(
                      hintText: 'Search',
                      prefixIcon: Icon(Icons.search, size: 18),
                      isDense: true),
                  onSubmitted: (q) {
                    if (q.trim().isEmpty) return;
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => SearchScreen(query: q.trim())));
                  },
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh catalogs',
                  onPressed: _build),
            ]),
          ),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.all(60),
              child: Center(
                  child: Text(
                      'Install a metadata add-on (Add-ons tab) and its '
                      'catalogs will fill this page.')),
            ),
          if (cont.isNotEmpty)
            _Row(
              title: 'Continue watching',
              children: [
                for (final c in cont)
                  SizedBox(
                    width: 140,
                    child: PosterCard(
                      poster: c['poster'],
                      title: c['name'] ?? c['itemId'],
                      subtitle: _epLabel(c['videoId'] as String),
                      progress: (c['duration'] ?? 0) > 0
                          ? (c['position'] as num) / (c['duration'] as num)
                          : null,
                      onTap: () => _openDetails(c['type'], c['itemId']),
                    ),
                  ),
              ],
            ),
          for (final r in rows)
            FutureBuilder<List>(
              future: r['future'] as Future<List>,
              builder: (_, snap) {
                final items = snap.data ?? [];
                if (snap.connectionState != ConnectionState.done) {
                  return const SizedBox(
                      height: 60,
                      child: Center(
                          child: SizedBox(
                              width: 18, height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))));
                }
                if (items.isEmpty) return const SizedBox.shrink();
                return _Row(
                  title: '${r['name']}',
                  subtitle: '${r['addonName']} · ${r['type']}',
                  onSeeAll: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => CatalogScreen(
                          transportUrl: r['transportUrl'],
                          type: r['type'],
                          id: r['id'],
                          name: r['name'],
                          hasSearch: r['hasSearch'] == true))),
                  children: [
                    for (final m in items.take(20))
                      SizedBox(
                        width: 140,
                        child: PosterCard(
                          poster: m['poster'],
                          title: m['name'] ?? m['id'],
                          onTap: () => _openDetails(m['type'], m['id']),
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onSeeAll;
  final List<Widget> children;
  const _Row(
      {required this.title,
      required this.children,
      this.subtitle,
      this.onSeeAll});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(title.toUpperCase(),
              style: const TextStyle(fontSize: 12, letterSpacing: 1.5)),
          if (subtitle != null) ...[
            const SizedBox(width: 8),
            Text(subtitle!,
                style: TextStyle(
                    fontSize: 11, color: Theme.of(context).hintColor)),
          ],
          const Spacer(),
          if (onSeeAll != null)
            TextButton(onPressed: onSeeAll, child: const Text('See all')),
        ]),
      ),
      SizedBox(
        height: 248 * Db.uiScale.value,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          itemCount: children.length,
          separatorBuilder: (_, __) => const SizedBox(width: 14),
          itemBuilder: (_, i) => children[i],
        ),
      ),
    ]);
  }
}
