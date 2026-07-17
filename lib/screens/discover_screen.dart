import 'package:flutter/material.dart';
import '../services/addons.dart';
import 'details_screen.dart';
import 'widgets.dart';

/// Discover, two levels deep:
///   1) Content type tabs — Movies / Series / Anime / anything else addons declare
///   2) Catalog chips within that type — Popular, Top rated, etc.
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});
  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  List<Map> catalogs = [];
  List<String> types = [];
  String? selectedType;
  int catalogIdx = 0;
  String search = '';
  List items = [];
  bool loading = false;
  String? error;

  static const _typeLabels = {
    'movie': 'Movies',
    'series': 'Series',
    'anime': 'Anime',
    'tv': 'TV',
    'channel': 'Channels',
  };
  static const _typeOrder = ['movie', 'series', 'anime'];

  String _label(String t) =>
      _typeLabels[t] ?? (t.isEmpty ? t : t[0].toUpperCase() + t.substring(1));

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
            'type': c['type'],
            'id': c['id'],
            'name': c['name'] ?? c['id'],
            'hasSearch': ((c['extra'] as List?) ?? [])
                .any((e) => e is Map && e['name'] == 'search'),
          }
    ];
    // Movies, Series, Anime first; any other addon-declared types after.
    final found = catalogs.map((c) => c['type'] as String).toSet();
    types = [
      for (final t in _typeOrder)
        if (found.contains(t)) t,
      ...found.where((t) => !_typeOrder.contains(t)),
    ];
    selectedType = types.isEmpty ? null : types.first;
    catalogIdx = 0;
    if (selectedType != null) _load();
  }

  List<Map> get _typeCatalogs =>
      catalogs.where((c) => c['type'] == selectedType).toList();

  Future<void> _load() async {
    final list = _typeCatalogs;
    if (list.isEmpty) return;
    final c = list[catalogIdx.clamp(0, list.length - 1)];
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final extra = <String, String>{};
      if (search.isNotEmpty && c['hasSearch'] == true) extra['search'] = search;
      items = await Addons.fetchCatalog(c['transportUrl'], c['type'], c['id'], extra);
    } catch (e) {
      error = '$e';
      items = [];
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (catalogs.isEmpty) {
      return const Center(
          child: Text('No catalogs yet.\nInstall a metadata add-on in the '
              'Add-ons tab and its catalogs will appear here.',
              textAlign: TextAlign.center));
    }
    final list = _typeCatalogs;
    final current = list.isEmpty ? null : list[catalogIdx.clamp(0, list.length - 1)];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
        child: Row(children: [
          const Text('Discover',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
          const SizedBox(width: 24),
          // Level 1: content type
          Wrap(spacing: 8, children: [
            for (final t in types)
              ChoiceChip(
                label: Text(_label(t)),
                selected: selectedType == t,
                onSelected: (_) {
                  setState(() {
                    selectedType = t;
                    catalogIdx = 0;
                    search = '';
                  });
                  _load();
                },
              ),
          ]),
          const Spacer(),
          if (loading)
            const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
      ),
      // Level 2: catalogs within the type (Popular, Top rated, ...)
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
        child: Row(children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Wrap(spacing: 8, children: [
                for (var i = 0; i < list.length; i++)
                  ChoiceChip(
                    label: Text(list.length > 1 &&
                            list.where((c) => c['name'] == list[i]['name']).length > 1
                        ? '${list[i]['name']} · ${list[i]['addonName']}'
                        : list[i]['name']),
                    selected: catalogIdx == i,
                    onSelected: (_) {
                      setState(() => catalogIdx = i);
                      _load();
                    },
                  ),
              ]),
            ),
          ),
          if (current?['hasSearch'] == true) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 240,
              child: TextField(
                decoration: const InputDecoration(
                    hintText: 'Search', isDense: true),
                onSubmitted: (v) {
                  search = v;
                  _load();
                },
              ),
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
        child: PosterGrid(children: [
          for (final m in items)
            PosterCard(
              poster: m['poster'],
              title: m['name'] ?? m['id'],
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => DetailsScreen(type: m['type'], id: m['id']))),
            ),
        ]),
      ),
    ]);
  }
}
