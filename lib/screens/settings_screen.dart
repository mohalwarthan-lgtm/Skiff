import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/profile.dart';
import '../services/stremio.dart';
import '../services/addons.dart';
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
  String? traktNote, storageNote, profileNote, stremioNote, error;
  late final stremioEmailCtrl = TextEditingController();
  late final stremioPassCtrl = TextEditingController();
  late final dirCtrl =
      TextEditingController(text: Db.setting('download_dir') ?? '');
  late final cacheCtrl =
      TextEditingController(text: Db.setting('cache_dir') ?? '');
  final idCtrl = TextEditingController();
  final secretCtrl = TextEditingController();

  @override
  void dispose() {
    pollTimer?.cancel();
    dirCtrl.dispose();
    cacheCtrl.dispose();
    stremioEmailCtrl.dispose();
    stremioPassCtrl.dispose();
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
              traktNote = 'Connected — importing your Trakt history…';
            });
            final msg = await Trakt.pullAll().catchError((e) => '$e');
            if (mounted) setState(() => traktNote = msg);
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
                            setState(() => traktNote = 'Syncing…');
                            final msg =
                                await Trakt.pullAll().catchError((e) => '$e');
                            setState(() => traktNote = msg);
                          },
                          child: const Text('Sync now')),
                      TextButton(
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (_) => AlertDialog(
                                title: const Text('Make Trakt match this library?'),
                                content: const Text(
                                    'Every title on Trakt that is not in your '
                                    'Skiff library will be removed from Trakt: '
                                    'its watchlist entry, its watch history, '
                                    'and its Continue Watching progress. Your '
                                    'Skiff library becomes the single source '
                                    'of truth. This cannot be undone.'),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('Cancel')),
                                  FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('Clean up Trakt')),
                                ],
                              ),
                            );
                            if (ok != true) return;
                            setState(() => traktNote = 'Cleaning up Trakt…');
                            final msg = await Trakt.mirrorLocal()
                                .catchError((e) => 'Cleanup failed: ' + '$e');
                            setState(() => traktNote = msg);
                          },
                          child: const Text('Clean up Trakt')),
                      TextButton(
                          onPressed: () {
                            Trakt.disconnect();
                            setState(() {});
                          },
                          child: const Text('Disconnect')),
                    ]),
                    if (traktNote != null) Text(traktNote!, style: hint),
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
        const Text('SWITCHING FROM STREMIO?',
            style: TextStyle(fontSize: 12, letterSpacing: 1.5)),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  'Sign in once to pull your add-ons from your Stremio '
                  'account — full configuration included. Your password is '
                  'sent only to Stremio and never stored.',
                  style: hint),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: stremioEmailCtrl,
                    decoration:
                        const InputDecoration(labelText: 'Stremio email'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: stremioPassCtrl,
                    obscureText: true,
                    decoration:
                        const InputDecoration(labelText: 'Password'),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.tonal(
                  onPressed: () async {
                    final email = stremioEmailCtrl.text.trim();
                    final pass = stremioPassCtrl.text;
                    if (email.isEmpty || pass.isEmpty) return;
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Pull add-ons from Stremio?'),
                        content: const Text(
                            'Your current add-on list in SkiffBox will be '
                            'replaced by the add-ons from your Stremio '
                            'account.'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel')),
                          FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Pull add-ons')),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    setState(() => stremioNote = 'Signing in to Stremio…');
                    try {
                      final key = await Stremio.login(email, pass);
                      setState(
                          () => stremioNote = 'Reading add-on collection…');
                      final urls = await Stremio.addonUrls(key);
                      await Db.addons.clear();
                      var installed = 0;
                      var failed = 0;
                      for (final u in urls) {
                        try {
                          await Addons.install(u);
                          installed++;
                        } catch (_) {
                          failed++;
                        }
                      }
                      stremioPassCtrl.clear();
                      setState(() => stremioNote =
                          'Imported $installed add-on(s) from Stremio' +
                              (failed > 0 ? ' ($failed failed)' : '') +
                              '.');
                    } catch (e) {
                      setState(() => stremioNote = '$e');
                    }
                  },
                  child: const Text('Pull add-ons'),
                ),
              ]),
              if (stremioNote != null)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(stremioNote!, style: hint)),
            ]),
          ),
        ),
        const SizedBox(height: 20),
        const Text('STORAGE', style: TextStyle(fontSize: 12, letterSpacing: 1.5)),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: TextField(
                  controller: dirCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Download folder',
                      helperText:
                          'New downloads are saved here. Empty = default.'),
                  onChanged: (v) => Db.setSetting('download_dir', v.trim()),
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton.tonal(
                  onPressed: () async {
                    final dir = await getDirectoryPath();
                    if (dir != null && dir.isNotEmpty) {
                      dirCtrl.text = dir;
                      Db.setSetting('download_dir', dir);
                      setState(() => storageNote = 'New downloads will go to ' + dir);
                    }
                  },
                  child: const Text('Browse…'),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: TextField(
                  controller: cacheCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Streaming cache folder',
                      helperText:
                          'Disk buffer for streaming. Empty = default.'),
                  onChanged: (v) => Db.setSetting('cache_dir', v.trim()),
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton.tonal(
                  onPressed: () async {
                    final dir = await getDirectoryPath();
                    if (dir != null && dir.isNotEmpty) {
                      cacheCtrl.text = dir;
                      Db.setSetting('cache_dir', dir);
                      setState(() =>
                          storageNote = 'Streaming cache will use ' + dir);
                    }
                  },
                  child: const Text('Browse…'),
                ),
              ),
            ]),
            if (storageNote != null)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(storageNote!, style: hint))),
            ]),
          ),
        ),
        const SizedBox(height: 20),
                const Text('PROFILE', style: TextStyle(fontSize: 12, letterSpacing: 1.5)),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  'Move SkiffBox between devices: export writes one file (and '
                  'copies it to your clipboard) containing your add-ons, '
                  'library, watch progress, settings, and your Trakt login '
                  'tokens - importing on another device signs you in '
                  'automatically. Treat the file like a password.',
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
                          profileNote = 'Profile saved to $path (and copied to clipboard).');
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
                        setState(() => profileNote = msg);
                      } catch (e) {
                        setState(() => error = '$e');
                      }
                    }
                  },
                  child: const Text('Import profile'),
                ),
              ]),
              if (profileNote != null)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(profileNote!, style: hint)),
            ]),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
