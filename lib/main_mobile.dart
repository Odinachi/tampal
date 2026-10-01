import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/database/clipboard_database.dart';
import 'core/providers/tampal_providers.dart';
import 'core/services/settings_service.dart';
import 'main_web.dart' as web;
import 'ui/screens/history_screen.dart';
import 'ui/theme/app_theme.dart';

void main() async {
  if (kIsWeb) {
    web.main();
    return;
  }

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
      child: const TampalMobileApp(),
    ),
  );
}

class TampalMobileApp extends ConsumerStatefulWidget {
  const TampalMobileApp({super.key});

  @override
  ConsumerState<TampalMobileApp> createState() => _TampalMobileAppState();
}

class _TampalMobileAppState extends ConsumerState<TampalMobileApp> {
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
      debugPrint('[TampalMobile] Auto-connecting to last paired peer: ${settings.lastPairedHost}:${settings.lastPairedPort}');
      final success = await ref.read(syncServiceProvider).connectToPeer(
        settings.lastPairedHost!,
        settings.lastPairedPort!,
      );
      if (success) {
        await ref.read(syncServiceProvider).syncNow(watcher: watcher);
        await ref.read(clipboardHistoryProvider.notifier).loadEntries();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(appThemeModeProvider);

    return MaterialApp(
      title: 'Tampal Mobile',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      home: const HistoryScreen(),
    );
  }
}
