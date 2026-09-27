import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../clipboard/clipboard_watcher.dart';
import '../database/clipboard_database.dart';
import '../models/clipboard_entry.dart';
import '../models/device_info.dart';
import '../network/discovery_service.dart';
import '../network/sync_service.dart';
import '../network/web_server.dart';
import '../services/settings_service.dart';

// -------------------------------------------------------------
// Core Services Providers (initialized at startup in entry points)
// -------------------------------------------------------------

final settingsServiceProvider = Provider<SettingsService>((ref) {
  throw UnimplementedError('settingsServiceProvider must be overridden in ProviderScope');
});

final clipboardDatabaseProvider = Provider<ClipboardDatabase>((ref) {
  return ClipboardDatabase.instance;
});

final syncServiceProvider = Provider<SyncService>((ref) {
  final settings = ref.watch(settingsServiceProvider);
  final db = ref.watch(clipboardDatabaseProvider);
  final syncService = SyncService(settings: settings, db: db);
  ref.onDispose(() => syncService.dispose());
  return syncService;
});

final discoveryServiceProvider = Provider<DiscoveryService>((ref) {
  final settings = ref.watch(settingsServiceProvider);
  final discovery = DiscoveryService(
    currentDeviceId: settings.deviceId,
    currentDeviceName: settings.deviceName,
    currentPlatform: settings.platformName,
    port: settings.serverPort,
  );
  ref.onDispose(() => discovery.dispose());
  return discovery;
});

final clipboardWatcherProvider = Provider<ClipboardWatcher>((ref) {
  final settings = ref.watch(settingsServiceProvider);
  final db = ref.watch(clipboardDatabaseProvider);
  final syncService = ref.watch(syncServiceProvider);
  final watcher = ClipboardWatcher(
    settings: settings,
    db: db,
    syncService: syncService,
  );
  ref.onDispose(() => watcher.dispose());
  return watcher;
});

final webServerProvider = Provider<WebServer>((ref) {
  final settings = ref.watch(settingsServiceProvider);
  final db = ref.watch(clipboardDatabaseProvider);
  final syncService = ref.watch(syncServiceProvider);
  final watcher = ref.watch(clipboardWatcherProvider);
  final server = WebServer(
    settings: settings,
    db: db,
    syncService: syncService,
    watcher: watcher,
  );
  ref.onDispose(() => server.stop());
  return server;
});

final webPortalUrlProvider = FutureProvider<String>((ref) async {
  final server = ref.watch(webServerProvider);
  return await server.getPortalUrl();
});

// -------------------------------------------------------------
// UI State & Streams
// -------------------------------------------------------------

/// Current connection status
final syncStatusProvider = StreamProvider<SyncStatus>((ref) {
  final syncService = ref.watch(syncServiceProvider);
  return syncService.statusStream;
});

/// Currently connected/active peer
final activePeerProvider = StreamProvider<PeerDevice?>((ref) {
  final syncService = ref.watch(syncServiceProvider);
  return syncService.activePeerStream;
});

/// Discovered mDNS peers
final discoveredPeersProvider = StreamProvider<List<PeerDevice>>((ref) {
  final discovery = ref.watch(discoveryServiceProvider);
  return discovery.peersStream;
});

/// Search query state for history list
final historySearchQueryProvider = StateProvider<String>((ref) => '');

/// Clipboard History StateNotifier
class ClipboardHistoryNotifier extends StateNotifier<AsyncValue<List<ClipboardEntry>>> {
  final ClipboardDatabase db;
  final SettingsService settings;
  final ClipboardWatcher watcher;
  final SyncService syncService;

  StreamSubscription? _watcherSub;
  StreamSubscription? _syncSub;
  String _currentQuery = '';

  ClipboardHistoryNotifier({
    required this.db,
    required this.settings,
    required this.watcher,
    required this.syncService,
  }) : super(const AsyncValue.loading()) {
    _init();
  }

  void _init() {
    loadEntries();

    // Listen to local copies
    _watcherSub = watcher.newEntryStream.listen((_) {
      loadEntries();
    });

    // Listen to remote received entries
    _syncSub = syncService.entryReceivedStream.listen((_) {
      loadEntries();
    });
  }

  Future<void> loadEntries([String? query]) async {
    _currentQuery = query ?? _currentQuery;
    try {
      final entries = await db.getEntries(
        limit: settings.retentionLimit,
        searchQuery: _currentQuery,
      );
      state = AsyncValue.data(entries);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> copyEntryToClipboard(ClipboardEntry entry) async {
    await watcher.copyToClipboard(entry);
  }

  Future<void> deleteEntry(String id) async {
    await db.deleteEntry(id);
    await loadEntries();
  }

  Future<void> clearHistory() async {
    await db.clearAll();
    await loadEntries();
  }

  @override
  void dispose() {
    _watcherSub?.cancel();
    _syncSub?.cancel();
    super.dispose();
  }
}

final clipboardHistoryProvider =
    StateNotifierProvider<ClipboardHistoryNotifier, AsyncValue<List<ClipboardEntry>>>((ref) {
  final db = ref.watch(clipboardDatabaseProvider);
  final settings = ref.watch(settingsServiceProvider);
  final watcher = ref.watch(clipboardWatcherProvider);
  final syncService = ref.watch(syncServiceProvider);

  final notifier = ClipboardHistoryNotifier(
    db: db,
    settings: settings,
    watcher: watcher,
    syncService: syncService,
  );

  // Re-filter when search query changes
  ref.listen<String>(historySearchQueryProvider, (_, nextQuery) {
    notifier.loadEntries(nextQuery);
  });

  return notifier;
});
