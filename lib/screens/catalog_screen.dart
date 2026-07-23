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
  final scroll = ScrollController();
  List items = [];
  bool loading = true;
  bool loadingMore = false;
  bool endReached = false;
  String search = '';
  String? error;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  Future<void> _load(String q) async {
    search = q;
    setState(() {
      loading = true;
      endReached = false;
      error = null;
    });
    try {
      items = await Addons.fetchCatalog(widget.transportUrl, widget.type,
          widget.id, q.isEmpty ? {} : {'search': q});
      if (items.isEmpty) endReached = true;
    } catch (e) {
      error = '$e';
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


  Future<void> _loadMore() async {
    if (loading || loadingMore || endReached) return;
    setState(() => loadingMore = true);
    try {
      final extra = <String, String>{
        if (search.isNotEmpty) 'search': search,
        'skip': '${items.length}',
      };
      final page = await Addons.fetchCatalog(
          widget.transportUrl, widget.type, widget.id, extra);
      final seen = {for (final m in items) '${m['id']}'};
      final fresh =
          page.where((m) => m is Map && seen.add('${m['id']}')).toList();
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
  void dispose() {
    scroll.dispose();
    super.dispose();
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
              : NotificationListener<ScrollNotification>(
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
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => DetailsScreen(
                                    type: m['type'], id: m['id']))),
                      ),
                  ]),
                ),
    );
  }
}
