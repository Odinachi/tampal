import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'core/database/clipboard_database.dart';
import 'core/providers/clipsync_providers.dart';
import 'core/services/settings_service.dart';
import 'ui/screens/history_screen.dart';
import 'ui/theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize SQLite FFI for desktop (Windows / macOS / Linux)
  ClipboardDatabase.initializePlatform();

  // Configure desktop window properties
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    try {
      await windowManager.ensureInitialized();
      const windowOptions = WindowOptions(
        size: Size(980, 680),
        minimumSize: Size(720, 500),
        center: true,
        backgroundColor: Colors.transparent,
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.normal,
        title: 'ClipSync Desktop',
      );
      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      });
    } catch (e) {
      debugPrint('[ClipSyncDesktop] Window manager setup warning: $e');
    }
  }

  // Initialize settings
  final settings = await SettingsService.init();

  // Initialize database
  final db = ClipboardDatabase.instance;
  await db.database;

  // Run initial retention pruning
  await db.enforceRetention(
    maxEntries: settings.retentionLimit,
    maxDays: settings.retentionDays,
  );

  runApp(
    ProviderScope(
      overrides: [
        settingsServiceProvider.overrideWithValue(settings),
      ],
      child: const ClipSyncDesktopApp(),
    ),
  );
}

class ClipSyncDesktopApp extends ConsumerStatefulWidget {
  const ClipSyncDesktopApp({super.key});

  @override
  ConsumerState<ClipSyncDesktopApp> createState() => _ClipSyncDesktopAppState();
}

class _ClipSyncDesktopAppState extends ConsumerState<ClipSyncDesktopApp> {
  @override
  void initState() {
    super.initState();
    _startDesktopServices();
  }

  Future<void> _startDesktopServices() async {
    final settings = ref.read(settingsServiceProvider);

    // 1. Desktop acts as the primary TCP server listening on fixed port
    final syncService = ref.read(syncServiceProvider);
    await syncService.startServer(port: settings.serverPort);

    // 2. Start mDNS advertisement so mobile devices immediately discover this desktop
    final discovery = ref.read(discoveryServiceProvider);
    await discovery.startBroadcasting();
    await discovery.startDiscovery();

    // 3. Start clipboard polling / hook
    final watcher = ref.read(clipboardWatcherProvider);
    await watcher.start();

    // 4. Start local web portal
    if (settings.webEnabled) {
      final webServer = ref.read(webServerProvider);
      await webServer.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClipSync Desktop',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const HistoryScreen(),
    );
  }
}
