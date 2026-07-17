import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/profile.dart';
import '../config.dart';
import '../services/db.dart';
import '../services/trakt.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? device;
  Timer? pollTimer;
  String? note, error;
  final idCtrl = TextEditingController();
  final secretCtrl = TextEditingController();
  final torboxCtrl =
      TextEditingController(text: Db.setting('torbox_api_key') ?? '');

  @override
  void dispose() {
    pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() => error = null);
    try {
      if (!Config.hasBundledTrakt) {
        if (idCtrl.text.isEmpty || secretCtrl.text.isEmpty) {
          setState(() => error = 'Enter your Trakt client ID and secret first.');
          return;
        }
        Db.setSetting('trakt_client_id', idCtrl.text.trim());
        Db.setSetting('trakt_client_secret', secretCtrl.text.trim());
      }
      final d = await Trakt.deviceCode();
      setState(() => device = d);
      final expires = DateTime.now().add(Duration(seconds: d['expires_in']));
      pollTimer = Timer.periodic(
          Duration(seconds: (d['interval'] as int) + 1), (t) async {
        if (DateTime.now().isAfter(expires)) {
          t.cancel();
          setState(() {
            device = null;
            error = 'The code expired before it was approved. Try again.';
          });
          return;
        }
        try {
          if (await Trakt.pollToken(d['device_code'])) {
            t.cancel();
            setState(() {
              device = null;
              note = 'Connected — importing your Trakt history…';
            });
            final msg = await Trakt.pullAll().catchError((e) => '$e');
            if (mounted) setState(() => note = msg);
          }
        } catch (e) {
          t.cancel();
          setState(() {
            device = null;
            error = '$e';
          });
        }
      });
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = TextStyle(fontSize: 12, color: Theme.of(context).hintColor);
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text('Settings',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
        const SizedBox(height: 20),
        const Text('TRAKT', style: TextStyle(fontSize: 12, letterSpacing: 1.5)),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Trakt.connected
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Text('● Connected',
                          style: TextStyle(color: Color(0xFF63C589))),
                      const Spacer(),
                      TextButton(
                          onPressed: () async {
                            setState(() => note = 'Syncing…');
                            final msg =
                                await Trakt.pullAll().catchError((e) => '$e');
                            setState(() => note = msg);
                          },
                          child: const Text('Sync now')),
                      TextButton(
                          onPressed: () {
                            Trakt.disconnect();
                            setState(() {});
                          },
                          child: const Text('Disconnect')),
                    ]),
                    if (note != null) Text(note!, style: hint),
                    Text(
                        'Everything is automatic: playback scrobbles while you '
                        'watch, shelf changes and watched flags push to Trakt, '
                        'and your history pulls in the background every 30 minutes.',
                        style: hint),
                  ])
                : device != null
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Go to ${device!['verification_url']} and enter:'),
                          const SizedBox(height: 8),
                          Row(children: [
                            SelectableText(device!['user_code'],
                                style: const TextStyle(
                                    fontSize: 26,
                                    letterSpacing: 6,
                                    fontFamily: 'monospace')),
                            const SizedBox(width: 14),
                            TextButton(
                                onPressed: () => launchUrl(
                                    Uri.parse(device!['verification_url'])),
                                child: const Text('Open page')),
                          ]),
                          Text('Waiting for approval — this updates automatically.',
                              style: hint),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!Config.hasBundledTrakt) ...[
                            Text(
                                'This build has no bundled Trakt app. Create a '
                                'free API app at trakt.tv/oauth/applications and '
                                'paste its credentials once (stored locally). '
                                'Cloud builds can bundle them via repository '
                                'secrets so this step disappears.',
                                style: hint),
                            const SizedBox(height: 8),
                            TextField(
                                controller: idCtrl,
                                decoration: const InputDecoration(
                                    labelText: 'Client ID')),
                            TextField(
                                controller: secretCtrl,
                                obscureText: true,
                                decoration: const InputDecoration(
                                    labelText: 'Client secret')),
                            const SizedBox(height: 10),
                          ] else
                            Text(
                                'Sign in once — Skiff keeps your library and '
                                'Trakt in sync automatically after that.',
                                style: hint),
                          FilledButton(
                              onPressed: _connect,
                              child: const Text('Connect Trakt')),
                        ],
                      ),
          ),
        ),
        if (error != null)
          Text(error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 20),
        const Text('PROFILE', style: TextStyle(fontSize: 12, letterSpacing: 1.5)),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  'Move Skiff between devices: export writes one file (and '
                  'copies it to your clipboard) with your add-ons, library, '
                  'progress, and settings. Import it on any other platform '
                  'running Skiff.',
                  style: hint),
              const SizedBox(height: 8),
              Row(children: [
                FilledButton.tonal(
                  onPressed: () async {
                    try {
                      final path = await Profile.exportToFile();
                      await Clipboard.setData(
                          ClipboardData(text: Profile.exportJson()));
                      setState(() =>
                          note = 'Profile saved to $path (and copied to clipboard).');
                    } catch (e) {
                      setState(() => error = '$e');
                    }
                  },
                  child: const Text('Export profile'),
                ),
                const SizedBox(width: 10),
                FilledButton.tonal(
                  onPressed: () async {
                    final ctrl = TextEditingController();
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Import profile'),
                        content: TextField(
                          controller: ctrl,
                          maxLines: 6,
                          decoration: const InputDecoration(
                              hintText:
                                  'Paste profile JSON here, or a path to the file'),
                        ),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel')),
                          FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Import')),
                        ],
                      ),
                    );
                    if (ok == true) {
                      try {
                        final msg = await Profile.import(ctrl.text);
                        setState(() => note = msg);
                      } catch (e) {
                        setState(() => error = '$e');
                      }
                    }
                  },
                  child: const Text('Import profile'),
                ),
              ]),
              if (note != null)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(note!, style: hint)),
            ]),
          ),
        ),
        const SizedBox(height: 20),
        const Text('TORBOX', style: TextStyle(fontSize: 12, letterSpacing: 1.5)),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: torboxCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'TorBox API key',
                    helperText:
                        'Used only for torrent-only (P2P) streams: TorBox fetches '
                        'them server-side and Skiff streams the result — no '
                        'torrent client involved. Debrid/usenet streams don\'t '
                        'need this.'),
                onChanged: (v) => Db.setSetting('torbox_api_key', v.trim()),
              ),
            ]),
          ),
        ),
      ],
    );
  }
}
