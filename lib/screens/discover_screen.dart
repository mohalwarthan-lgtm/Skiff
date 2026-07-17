import 'package:flutter/material.dart';
import '../services/addons.dart';
import 'details_screen.dart';
import 'widgets.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});
  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  List<Map> catalogs = []; // {transportUrl, addonName, type, id, name, hasSearch}
  int pick = 0;
  String search = '';
  List items = [];
  bool loading = false;
  String? error;

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
    pick = pick.clamp(0, catalogs.isEmpty ? 0 : catalogs.length - 1);
    if (catalogs.isNotEmpty) _load();
  }

  Future<void> _load() async {
    final c = catalogs[pick];
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
    final c = catalogs[pick];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
          child: Row(
            children: [
              const Text('Discover',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
              const SizedBox(width: 20),
              DropdownButton<int>(
                value: pick,
                items: [
                  for (var i = 0; i < catalogs.length; i++)
                    DropdownMenuItem(
                        value: i,
                        child: Text(
                            '${catalogs[i]['addonName']} · ${catalogs[i]['name']} (${catalogs[i]['type']})')),
                ],
                onChanged: (v) {
                  setState(() => pick = v!);
                  _load();
                },
              ),
              const SizedBox(width: 20),
              if (c['hasSearch'] == true)
                SizedBox(
                  width: 260,
                  child: TextField(
                    decoration:
                        const InputDecoration(hintText: 'Search this catalog'),
                    onSubmitted: (v) {
                      search = v;
                      _load();
                    },
                  ),
                ),
              if (loading)
                const Padding(
                    padding: EdgeInsets.only(left: 16),
                    child: SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))),
            ],
          ),
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
                    builder: (_) =>
                        DetailsScreen(type: m['type'], id: m['id']))),
              ),
          ]),
        ),
      ],
    );
  }
}
