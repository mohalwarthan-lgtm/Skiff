import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'screens/addons_screen.dart';
import 'screens/home_screen.dart';
import 'screens/player_screen.dart';
import 'screens/discover_screen.dart';
import 'screens/downloads_screen.dart';
import 'screens/library_screen.dart';
import 'screens/settings_screen.dart';
import 'services/db.dart';
import 'services/trakt.dart';

/// One-time copy of app data from the old skiff folder after the rename.
Future<void> _migrateOldSkiffData() async {
  try {
    final cur = await getApplicationSupportDirectory();
    if (!cur.path.contains('skiffbox')) return;
    final hasData = await cur
        .list()
        .where((e) => !e.path.endsWith('.tmp'))
        .isEmpty
        .then((empty) => !empty);
    if (hasData) return;
    final old = Directory(cur.path.replaceAll('skiffbox', 'skiff'));
    if (!await old.exists()) return;
    await for (final entity in old.list(recursive: true)) {
      final rel = entity.path.substring(old.path.length);
      if (entity is Directory) {
        await Directory(cur.path + rel).create(recursive: true);
      } else if (entity is File) {
        await File(cur.path + rel).parent.create(recursive: true);
        await entity.copy(cur.path + rel);
      }
    }
  } catch (_) {/* migration is best-effort; a fresh start still works */}
}

/// Window management only exists on desktop; mobile builds skip it.
final bool _isDesktop =
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_isDesktop) {
    await windowManager.ensureInitialized(); // window control (fullscreen)
    await windowManager.setTitle('SkiffBox');
    // Intercept close so a mid-episode position reaches Trakt first.
    await windowManager.setPreventClose(true);
  }
  await _migrateOldSkiffData();
  await Db.init();
  // One shared engine; the cloud build swaps in the full-codec DLL.
  MediaKit.ensureInitialized();
  runApp(const SkiffApp());

  // Hands-off Trakt: pull on launch, then every 30 minutes.
  Future<void> sync() async {
    if (Trakt.connected) {
      try {
        await Trakt.pullAll();
      } catch (_) {}
    }
  }

  sync();
  Stream.periodic(const Duration(minutes: 30)).listen((_) => sync());
}

class SkiffApp extends StatelessWidget {
  const SkiffApp({super.key});

  @override
  Widget build(BuildContext context) {
    // SkiffBox palette: deep navy sea, cyan water, orange hull.
    const bg = Color(0xFF0A1522);
    const panel = Color(0xFF122036);
    const orange = Color(0xFFF4791F);
    const cyan = Color(0xFF35D6E8);
    return ValueListenableBuilder<double>(
        valueListenable: Db.uiScale,
        builder: (context, scale, _) => MaterialApp(
          builder: (context, child) => MediaQuery(
            // Scale by REFLOW, not magnification: text and controls grow
            // via the text scaler, poster tiles via the grid (below) -
            // layouts adapt instead of overflowing the window.
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
      title: 'SkiffBox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.dark(
          primary: orange,
          onPrimary: Color(0xFF2A1200),
          secondary: cyan,
          onSecondary: Color(0xFF00252B),
          secondaryContainer: Color(0xFF0F3A44),
          onSecondaryContainer: cyan,
          surface: panel,
        ),
        cardColor: panel,
        dividerColor: const Color(0xFF1C3049),
        useMaterial3: true,
      ),
      home: const Shell(),
    ));
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

const _tabs = <(IconData, String)>[
  (Symbols.home, 'Home'),
  (Symbols.video_library, 'Library'),
  (Symbols.explore, 'Discover'),
  (Symbols.download, 'Downloads'),
  (Symbols.extension, 'Add-ons'),
  (Symbols.settings, 'Settings'),
];

/// Thin icons; filled face only when selected.
NavigationRailDestination _dest(IconData symbol, String label) =>
    NavigationRailDestination(
      icon: Icon(symbol,
          weight: 300, fill: 0, size: 24 * Db.uiScale.value),
      selectedIcon: Icon(symbol, weight: 400, fill: 1),
      label: Text(label),
    );

class _ShellState extends State<Shell> with WindowListener {
  int index = 0;

  @override
  void initState() {
    super.initState();
    if (_isDesktop) windowManager.addListener(this);
  }

  @override
  void dispose() {
    if (_isDesktop) windowManager.removeListener(this);
    super.dispose();
  }

  /// Repaint after maximize/restore - Windows can leave the surface stale.
  void _repaintKick() {
    WidgetsBinding.instance.scheduleForcedFrame();
    Future.delayed(const Duration(milliseconds: 60),
        () => WidgetsBinding.instance.scheduleForcedFrame());
    Future.delayed(const Duration(milliseconds: 250),
        () => WidgetsBinding.instance.scheduleForcedFrame());
  }

  @override
  Future<void> onWindowClose() async {
    // Vanish instantly, flush the playback position to Trakt behind the
    // scenes, then really exit - close feels immediate either way.
    try {
      await windowManager.hide();
    } catch (_) {}
    try {
      await (PlayerFlush.flush?.call() ?? Future.value())
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
    await windowManager.destroy();
  }

  @override
  void onWindowMaximize() => _repaintKick();

  @override
  void onWindowUnmaximize() => _repaintKick();

  @override
  void onWindowRestore() => _repaintKick();

  @override
  void onWindowFocus() => _repaintKick();

  @override
  Widget build(BuildContext context) {
    final screens = const [
      HomeScreen(),
      LibraryScreen(),
      DiscoverScreen(),
      DownloadsScreen(),
      AddonsScreen(),
      SettingsScreen(),
    ];
    // Wide screens: side rail. Phones: bottom tabs.
    final wide = MediaQuery.sizeOf(context).width >= 640;
    if (!wide) {
      return Scaffold(
        body: SafeArea(child: screens[index]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) => setState(() => index = i),
          destinations: [
            for (final d in _tabs)
              NavigationDestination(
                  icon: Icon(d.$1,
                      weight: 300, fill: 0, size: 24 * Db.uiScale.value),
                  selectedIcon: Icon(d.$1, weight: 400, fill: 1),
                  label: d.$2),
          ],
        ),
      );
    }
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 104 * Db.uiScale.value,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(children: [
              Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Column(children: [
                Image.asset('assets/logo.png', width: 44),
                const SizedBox(height: 4),
                const Text('SKIFFBOX',
                    style: TextStyle(
                        color: Color(0xFFF4791F),
                        fontWeight: FontWeight.w700,
                        fontSize: 9,
                        letterSpacing: 2)),
              ]),
            ),
              const SizedBox(height: 6),
              // Box buttons: icon + label share one shape, and the hover
              // highlight covers the whole thing - what you click is what
              // lights up.
              for (var i = 0; i < _tabs.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Material(
                    color: index == i
                        ? const Color(0x2235D6E8)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      hoverColor: const Color(0x1435D6E8),
                      onTap: () => setState(() => index = i),
                      child: SizedBox(
                        width: double.infinity,
                        child: Padding(
                          padding:
                              const EdgeInsets.symmetric(vertical: 10),
                          child: Column(children: [
                            Icon(_tabs[i].$1,
                                weight: 300,
                                fill: 0,
                                size: 24 * Db.uiScale.value,
                                color: index == i
                                    ? const Color(0xFF35D6E8)
                                    : Colors.white70),
                            const SizedBox(height: 4),
                            Text(_tabs[i].$2,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: index == i
                                        ? const Color(0xFF35D6E8)
                                        : Colors.white70)),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: screens[index]),
        ],
      ),
    );
  }
}
