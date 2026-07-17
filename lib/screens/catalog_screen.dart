import 'package:flutter/material.dart';
import '../services/addons.dart';
import 'details_screen.dart';
import 'widgets.dart';

/// A single catalog opened full-screen (from Home's "See all"),
/// with search when the catalog supports it.
class CatalogScreen extends StatefulWidget {
  final String transportUrl, type, id, name;
  final bool hasSearch;
  const CatalogScreen(
      {super.key,
      required this.transportUrl,
      required this.type,
      required this.id,
      required this.name,
      required this.hasSearch});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  List items = [];
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  Future<void> _load(String search) async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      items = await Addons.fetchCatalog(widget.transportUrl, widget.type,
          widget.id, search.isEmpty ? {} : {'search': search});
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.name} (${widget.type})'),
        actions: [
          if (widget.hasSearch)
            SizedBox(
              width: 260,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: TextField(
                  decoration: const InputDecoration(hintText: 'Search'),
                  onSubmitted: _load,
                ),
              ),
            ),
          const SizedBox(width: 16),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(child: Text(error!))
              : PosterGrid(children: [
                  for (final m in items)
                    PosterCard(
                      poster: m['poster'],
                      title: m['name'] ?? m['id'],
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) =>
                              DetailsScreen(type: m['type'], id: m['id']))),
                    ),
                ]),
    );
  }
}
