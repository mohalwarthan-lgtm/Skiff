import 'package:flutter/material.dart';
import '../services/addons.dart';
import 'details_screen.dart';
import 'search_screen.dart';
import 'widgets.dart';

/// Discover, two levels deep:
///   1) Type family tabs (Movies / Series / Anime / ...) — dotted subtypes
///      like "anime.movie" are grouped under their family, as the manifest
///      intends, while the original type string is kept for API calls.
///   2) Catalog chips within the family (Popular, By Language, MAL Genres...).
/// Catalogs that REQUIRE a parameter (genre/language/year/studio) get a
/// dropdown built from the options the manifest declares.
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});
  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final scroll = ScrollController();
  List<Map> catalogs = [];
  List<String> families = [];
  String? family;
  int catalogIdx = 0;
  String search = '';
  String? option; // selected value for a required extra (genre/language/...)
  List items = [];
  bool loading = false;
  bool loadingMore = false;
  bool endReached = false;
  String? error;

  static const _labels = {
    'movie': 'Movies',
    'series': 'Series',
    'anime': 'Anime',
    'tv': 'TV',
    'channel': 'Channels',
  };
  static const _order = ['movie', 'series', 'anime'];

  String _familyOf(String type) => type.split('.').first.toLowerCase();
  String _label(String f) =>
      _labels[f] ?? (f.isEmpty ? f : f[0].toUpperCase() + f.substring(1));

  @override
  void initState() {
    super.initState();
    _buildCatalogs();
  }

  void _buildCatalogs() {
    catalogs = [
      for (final a in Addons.enabled())
        for (final c in ((a['manifest'] as Map)['catalogs'] as List? ?? []))
          {
            'transportUrl': a['transportUrl'],
            'addonName': (a['manifest'] as Map)['name'],
            'type': c['type'], // original, used in request URLs
            'family': _familyOf(c['type'] as String), // used for grouping only
            'id': c['id'],
            'name': c['name'] ?? c['id'],
            'extra': c['extra'],
            'hasSearch': ((c['extra'] as List?) ?? [])
                .any((e) => e is Map && e['name'] == 'search'),
          }
    ];
    final found = catalogs.map((c) => c['family'] as String).toSet();
    families = [
      for (final f in _order)
        if (found.contains(f)) f,
      ...found.where((f) => !_order.contains(f)),
    ];
    family = families.isEmpty ? null : families.first;
    catalogIdx = 0;
    option = null;
    if (family != null) _load();
  }

  List<Map> get _familyCatalogs =>
      catalogs.where((c) => c['family'] == family).toList();

  Map? get _current {
    final list = _familyCatalogs;
    if (list.isEmpty) return null;
    return list[catalogIdx.clamp(0, list.length - 1)];
  }

  /// The first required non-search extra of the current catalog, if any.
  Map? get _requiredExtra {
    for (final e in ((_current?['extra'] as List?) ?? [])) {
      if (e is Map && e['isRequired'] == true && e['name'] != 'search') {
        return e;
      }
    }
    return null;
  }

  Map<String, String> _extraFor() {
    final extra = <String, String>{};
    final req = _requiredExtra;
    if (req != null) {
      final opts = (req['options'] as List?)?.cast<String>() ?? [];
      option ??= opts.isNotEmpty ? opts.first : null;
      if (option != null) extra['${req['name']}'] = option!;
    }
    return extra;
  }

  Future<void> _load() async {
    final c = _current;
    if (c == null) return;
    setState(() {
      loading = true;
      endReached = false;
      error = null;
    });
    try {
      items = await Addons.fetchCatalog(
          c['transportUrl'], c['type'], c['id'], _extraFor());
      if (items.isEmpty) endReached = true;
    } catch (e) {
      error = '$e';
      items = [];
    }
    if (mounted) setState(() => loading = false);
    _fillViewport();
  }
  /// Large windows can swallow whole pages without ever scrolling, which
  /// starves scroll-based paging - so keep fetching until the grid actually
  /// overflows (or the catalog ends).
  void _fillViewport() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || endReached || loading || loadingMore) return;
      if (!scroll.hasClients) return;
      if (scroll.position.maxScrollExtent <= 0 && items.isNotEmpty) {
        await _loadMore();
        _fillViewport();
      }
    });
  }


  /// Next page via the protocol's `skip` extra. Dedupes so catalogs that
  /// ignore `skip` naturally stop instead of repeating forever.
  Future<void> _loadMore() async {
    final c = _current;
    if (c == null || loading || loadingMore || endReached) return;
    setState(() => loadingMore = true);
    try {
      final page = await Addons.fetchCatalog(c['transportUrl'], c['type'],
          c['id'], {..._extraFor(), 'skip': '${items.length}'});
      final seen = {for (final m in items) '${m['type']}|${m['id']}'};
      final fresh = page
          .where((m) => m is Map && seen.add('${m['type']}|${m['id']}'))
          .toList();
      if (fresh.isEmpty) {
        endReached = true;
      } else {
        items = [...items, ...fresh];
      }
    } catch (_) {
      endReached = true;
    }
    if (mounted) setState(() => loadingMore = false);
    _fillViewport();
  }

  @override
  Widget build(BuildContext context) {
    if (catalogs.isEmpty) {
      return const Center(
          child: Text('No catalogs yet.\nInstall a metadata add-on in the '
              'Add-ons tab and its catalogs will appear here.',
              textAlign: TextAlign.center));
    }
    final list = _familyCatalogs;
    final req = _requiredExtra;
    final reqOptions = (req?['options'] as List?)?.cast<String>() ?? [];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
        child: Row(children: [
          const Text('Discover',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
          const SizedBox(width: 24),
          Wrap(spacing: 8, children: [
            for (final f in families)
              ChoiceChip(
                label: Text(_label(f)),
                selected: family == f,
                onSelected: (_) {
                  setState(() {
                    family = f;
                    catalogIdx = 0;
                    search = '';
                    option = null;
                  });
                  _load();
                },
              ),
          ]),
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
          const SizedBox(width: 12),
          if (loading)
            const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
        child: Row(children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Wrap(spacing: 8, children: [
                for (var i = 0; i < list.length; i++)
                  ChoiceChip(
                    label: Text(list[i]['name']),
                    selected: catalogIdx == i,
                    onSelected: (_) {
                      setState(() {
                        catalogIdx = i;
                        option = null;
                        search = '';
                      });
                      _load();
                    },
                  ),
              ]),
            ),
          ),
          if (reqOptions.isNotEmpty) ...[
            const SizedBox(width: 12),
            DropdownButton<String>(
              value: option ?? reqOptions.first,
              items: [
                for (final o in reqOptions)
                  DropdownMenuItem(value: o, child: Text(o)),
              ],
              onChanged: (v) {
                setState(() => option = v);
                _load();
              },
            ),
          ],
        ]),
      ),
      if (error != null)
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Text(error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error))),
      Expanded(
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.pixels > n.metrics.maxScrollExtent - 600) {
              _loadMore();
            }
            return false;
          },
          child: PosterGrid(controller: scroll, children: [
            for (final m in items)
              PosterCard(
                poster: m['poster'],
                title: m['name'] ?? m['id'],
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        DetailsScreen(type: m['type'], id: m['id']))),
              ),
          ]),
        ),
      ),
      if (loadingMore)
        const Padding(
            padding: EdgeInsets.all(8),
            child: Center(
                child: SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)))),
    ]);
  }
}
