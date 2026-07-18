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
  await windowManager.setTitle('SkiffBox');
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
    // SkiffBox palette: deep navy sea, cyan water, orange hull.
    const bg = Color(0xFF0A1522);
    const panel = Color(0xFF122036);
    const orange = Color(0xFFF4791F);
    const cyan = Color(0xFF35D6E8);
    return MaterialApp(
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
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WindowListener {
  int index = 0;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  /// Windows sometimes leaves the Flutter surface stale after maximize /
  /// restore (the "frozen until I resize by hand" effect). Nudging the
  /// engine to paint a couple of frames snaps it back instantly.
  void _repaintKick() {
    WidgetsBinding.instance.scheduleForcedFrame();
    Future.delayed(const Duration(milliseconds: 60),
        () => WidgetsBinding.instance.scheduleForcedFrame());
    Future.delayed(const Duration(milliseconds: 250),
        () => WidgetsBinding.instance.scheduleForcedFrame());
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
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: index,
            onDestinationSelected: (i) => setState(() => index = i),
            labelType: NavigationRailLabelType.all,
            leading: Padding(
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
