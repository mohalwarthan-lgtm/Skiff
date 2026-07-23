import 'package:flutter/material.dart';

import '../services/db.dart';
import '../services/addons.dart';
import 'details_screen.dart';
import 'widgets.dart';

/// One query, results grouped per catalog — your metadata add-on's own
/// separation (Movies / Series / Anime ...) carries straight through.
class SearchScreen extends StatefulWidget {
  final String query;
  const SearchScreen({super.key, required this.query});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  List<Map>? groups;
  late final ctrl = TextEditingController(text: widget.query);

  @override
  void initState() {
    super.initState();
    _run(widget.query);
  }

  Future<void> _run(String q) async {
    setState(() => groups = null);
    final g = await Addons.searchGrouped(q);
    if (mounted) setState(() => groups = g);
  }

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: ctrl,
          autofocus: false,
          decoration: const InputDecoration(
              hintText: 'Search', border: InputBorder.none),
          onSubmitted: _run,
        ),
      ),
      body: groups == null
          ? const Center(child: CircularProgressIndicator())
          : groups!.isEmpty
              ? const Center(child: Text('No results from any add-on.'))
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  children: [
                    for (final g in groups!) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(g['title'],
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(width: 8),
                              Text(g['addon'],
                                  style:
                                      TextStyle(fontSize: 11, color: hint)),
                            ]),
                      ),
                      SizedBox(
                        height: 232 * Db.uiScale.value,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          itemCount: (g['items'] as List).length,
                          itemBuilder: (context, i) {
                            final m = (g['items'] as List)[i] as Map;
                            return SizedBox(
                              width: 128 * Db.uiScale.value,
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                child: PosterCard(
                                  poster: m['poster'],
                                  title: m['name'] ?? m['id'],
                                  onTap: () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                          builder: (_) => DetailsScreen(
                                              type: m['type'],
                                              id: m['id']))),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                ),
    );
  }
}
