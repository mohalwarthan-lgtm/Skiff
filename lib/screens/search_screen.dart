import 'package:flutter/material.dart';
import '../services/addons.dart';
import 'details_screen.dart';
import 'widgets.dart';

/// One query, every add-on, every searchable catalog — merged and deduped.
class SearchScreen extends StatefulWidget {
  final String query;
  const SearchScreen({super.key, required this.query});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  List<Map>? results;
  late final ctrl = TextEditingController(text: widget.query);

  @override
  void initState() {
    super.initState();
    _run(widget.query);
  }

  Future<void> _run(String q) async {
    setState(() => results = null);
    final r = await Addons.searchAll(q);
    if (mounted) setState(() => results = r);
  }

  @override
  Widget build(BuildContext context) {
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
      body: results == null
          ? const Center(child: CircularProgressIndicator())
          : results!.isEmpty
              ? const Center(child: Text('No results from any add-on.'))
              : PosterGrid(children: [
                  for (final m in results!)
                    PosterCard(
                      poster: m['poster'],
                      title: m['name'] ?? m['id'],
                      subtitle: m['type'],
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) =>
                              DetailsScreen(type: m['type'], id: m['id']))),
                    ),
                ]),
    );
  }
}
