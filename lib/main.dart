import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'screens/addons_screen.dart';
import 'screens/home_screen.dart';
import 'screens/discover_screen.dart';
import 'screens/downloads_screen.dart';
import 'screens/library_screen.dart';
import 'screens/settings_screen.dart';
import 'services/db.dart';
import 'services/trakt.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized(); // window control (fullscreen etc.)
  windowManager.waitUntilReadyToShow().then((_) async {
    await windowManager.setTitle('Skiff');
  });
  // Prefer the full mpv engine shipped by the cloud build (complete codec
  // support: TrueHD, DTS variants, everything). If the folder is missing,
  // media_kit silently uses its own bundled engine instead.
  await Db.init();
  // One engine, loaded once, shared by the Dart side and the native texture
  // plugins alike. The cloud build replaces the DLL next to skiff.exe with a
  // full-codec build, so ALL components use the same upgraded engine -
  // loading a second copy via the libmpv: parameter is what caused the
  // native crashes (handles from one engine passed into the other).
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
    const bg = Color(0xFF0D1015);
    const panel = Color(0xFF151A21);
    const accent = Color(0xFFE8B15C);
    return MaterialApp(
      title: 'Skiff',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          onPrimary: Color(0xFF201502),
          surface: panel,
        ),
        cardColor: panel,
        dividerColor: const Color(0xFF242D39),
        useMaterial3: true,
      ),
      home: const Shell(),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int index = 0;

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
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: index,
            onDestinationSelected: (i) => setState(() => index = i),
            labelType: NavigationRailLabelType.all,
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('SKIFF',
                  style: TextStyle(
                      color: Color(0xFFE8B15C),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 3)),
            ),
            destinations: const [
              NavigationRailDestination(
                  icon: Icon(Icons.home_outlined), label: Text('Home')),
              NavigationRailDestination(
                  icon: Icon(Icons.video_library_outlined), label: Text('Library')),
              NavigationRailDestination(
                  icon: Icon(Icons.explore_outlined), label: Text('Discover')),
              NavigationRailDestination(
                  icon: Icon(Icons.download_outlined), label: Text('Downloads')),
              NavigationRailDestination(
                  icon: Icon(Icons.extension_outlined), label: Text('Add-ons')),
              NavigationRailDestination(
                  icon: Icon(Icons.settings_outlined), label: Text('Settings')),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: screens[index]),
        ],
      ),
    );
  }
}
