import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/database/clipboard_database.dart';
import 'core/providers/clipsync_providers.dart';
import 'core/services/settings_service.dart';
import 'ui/screens/history_screen.dart';
import 'ui/theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize SQLite for mobile
  ClipboardDatabase.initializePlatform();

  // Initialize preferences and settings
  final settings = await SettingsService.init();

  // Initialize database
  final db = ClipboardDatabase.instance;
  // Ensure database is opened and schema initialized
  await db.database;

  // Run initial retention pruning
  await db.enforceRetention(
    maxEntries: settings.retentionLimit,
    maxDays: settings.retentionDays,
  );

  // Set system UI overlay style
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppTheme.darkBg,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(
    ProviderScope(
      overrides: [
        settingsServiceProvider.overrideWithValue(settings),
      ],
      child: const ClipSyncMobileApp(),
    ),
  );
}

class ClipSyncMobileApp extends ConsumerStatefulWidget {
  const ClipSyncMobileApp({super.key});

  @override
  ConsumerState<ClipSyncMobileApp> createState() => _ClipSyncMobileAppState();
}

class _ClipSyncMobileAppState extends ConsumerState<ClipSyncMobileApp> {
  @override
  void initState() {
    super.initState();
    _startMobileServices();
  }

  Future<void> _startMobileServices() async {
    // 1. Start clipboard watcher
    final watcher = ref.read(clipboardWatcherProvider);
    await watcher.start();

    // 2. Start mDNS discovery to look for desktop peers
    final discovery = ref.read(discoveryServiceProvider);
    await discovery.startDiscovery();
    // Also advertise self so desktop or other devices can discover this mobile device
    await discovery.startBroadcasting();

    // 3. Auto-connect to last paired peer if configured
    final settings = ref.read(settingsServiceProvider);
    if (settings.autoSync && settings.lastPairedHost != null && settings.lastPairedPort != null) {
      debugPrint('[ClipSyncMobile] Auto-connecting to last paired peer: ${settings.lastPairedHost}:${settings.lastPairedPort}');
      ref.read(syncServiceProvider).connectToPeer(
        settings.lastPairedHost!,
        settings.lastPairedPort!,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClipSync Mobile',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const HistoryScreen(),
    );
  }
}
