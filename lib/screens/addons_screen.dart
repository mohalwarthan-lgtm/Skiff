import 'package:flutter/material.dart';
import '../services/addons.dart';
import '../services/db.dart';

class AddonsScreen extends StatefulWidget {
  const AddonsScreen({super.key});
  @override
  State<AddonsScreen> createState() => _AddonsScreenState();
}

class _AddonsScreenState extends State<AddonsScreen> {
  final urlCtrl = TextEditingController();
  bool busy = false;
  String? error;

  Future<void> _install() async {
    if (urlCtrl.text.trim().isEmpty) return;
    setState(() { busy = true; error = null; });
    try {
      await Addons.install(urlCtrl.text);
      urlCtrl.clear();
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final addons = Addons.installed();
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text('Add-ons',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                  hintText:
                      'Paste a manifest URL (https://…/manifest.json or stremio://…)'),
              onSubmitted: (_) => _install(),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
              onPressed: busy ? null : _install,
              child: Text(busy ? 'Installing…' : 'Install')),
        ]),
        const SizedBox(height: 6),
        Text(
            'Configure add-ons like AIOMetadata or AIOStreams on their own site '
            'first, then paste the personalized manifest URL they give you.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
        if (error != null)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error))),
        const SizedBox(height: 16),
        if (addons.isEmpty)
          const Padding(
              padding: EdgeInsets.all(50),
              child: Center(child: Text('No add-ons installed.'))),
        for (final a in addons)
          Card(
            child: ListTile(
              leading: (a['manifest']?['logo'] != null)
                  ? Image.network(a['manifest']['logo'],
                      width: 36, height: 36,
                      errorBuilder: (_, __, ___) => const Icon(Icons.extension))
                  : const Icon(Icons.extension),
              title: Text(
                  '${a['manifest']?['name'] ?? a['transportUrl']}  v${a['manifest']?['version'] ?? ''}'),
              subtitle: Text(a['manifest']?['description'] ?? '',
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Switch(
                  value: a['enabled'] == true,
                  onChanged: (v) {
                    Db.addons.put(a['transportUrl'], {...a, 'enabled': v});
                    setState(() {});
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    Db.addons.delete(a['transportUrl']);
                    setState(() {});
                  },
                ),
              ]),
            ),
          ),
      ],
    );
  }
}
