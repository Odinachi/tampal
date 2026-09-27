import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../database/clipboard_database.dart';
import '../models/clipboard_entry.dart';
import '../network/sync_service.dart';
import '../services/settings_service.dart';

class ClipboardWatcher with WidgetsBindingObserver {
  final SettingsService settings;
  final ClipboardDatabase db;
  final SyncService syncService;

  Timer? _pollingTimer;
  String? _lastKnownContent;
  final Set<String> _ignoredContents = {};
  bool _isWatching = false;
  String? _pendingRemoteText;

  final _newEntryController = StreamController<ClipboardEntry>.broadcast();

  ClipboardWatcher({
    required this.settings,
    required this.db,
    required this.syncService,
  }) {
    // Register callback so when remote peer pushes clipboard,
    // the watcher suppresses echo loops
    syncService.onRemoteClipboardApplied = ignoreContent;
    syncService.onPendingClipboardContent = (text) {
      _pendingRemoteText = text;
    };
  }

  Stream<ClipboardEntry> get newEntryStream => _newEntryController.stream;
  bool get isWatching => _isWatching;

  /// Start watching the system clipboard
  Future<void> start({Duration interval = const Duration(milliseconds: 750)}) async {
    if (_isWatching) return;
    _isWatching = true;

    // Register lifecycle observer to check clipboard instantly when app resumes
    WidgetsBinding.instance.addObserver(this);

    // Initial check: if system clipboard has text not yet in DB, record and sync it!
    await checkClipboard(force: true);

    _pollingTimer = Timer.periodic(interval, (_) => checkClipboard());
  }

  /// Stop watching
  void stop() {
    _isWatching = false;
    _pollingTimer?.cancel();
    _pollingTimer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onResumed();
    }
  }

  Future<void> _onResumed() async {
    // 1. Check local clipboard first in case the user copied something in another app
    var entry = await checkClipboard();

    // 2. On Android, window focus is granted asynchronously after onResume.
    // If not captured immediately, retry after 200ms and 500ms
    if (entry == null) {
      await Future.delayed(const Duration(milliseconds: 200));
      entry = await checkClipboard();
    }
    if (entry == null) {
      await Future.delayed(const Duration(milliseconds: 300));
      entry = await checkClipboard();
    }

    // 3. Only apply pending remote clipboard if user didn't copy anything new locally
    if (entry == null && _pendingRemoteText != null) {
      final text = _pendingRemoteText!;
      _pendingRemoteText = null;
      try {
        ignoreContent(text);
        await Clipboard.setData(ClipboardData(text: text));
        debugPrint('[ClipboardWatcher] Applied pending remote clipboard text on resume');
      } catch (e) {
        debugPrint('[ClipboardWatcher] Failed applying pending remote clipboard text on resume: $e');
      }
    }
  }

  /// Force read current system clipboard and push it to all connected peers
  Future<ClipboardEntry?> pushCurrentClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;

      if (text == null || text.trim().isEmpty) {
        return null;
      }

      _lastKnownContent = text;

      final entry = ClipboardEntry.create(
        deviceId: settings.deviceId,
        content: text,
      );

      // Save to SQLite
      await db.insertEntry(
        entry,
        maxEntries: settings.retentionLimit,
        maxDays: settings.retentionDays,
      );

      // Push to connected peers
      await syncService.pushLocalEntry(entry);

      // Emit to UI
      _newEntryController.add(entry);

      debugPrint('[ClipboardWatcher] Force pushed current clipboard: "${text.length > 30 ? '${text.substring(0, 30)}...' : text}"');
      return entry;
    } catch (e) {
      debugPrint('[ClipboardWatcher] Error pushing current clipboard: $e');
      return null;
    }
  }

  /// Mark content to be ignored from local push (used when peer pushes remote entry)
  void ignoreContent(String content) {
    _ignoredContents.add(content);
    _lastKnownContent = content;
    // Expire from set after 5 seconds to prevent unbounded growth
    Timer(const Duration(seconds: 5), () {
      _ignoredContents.remove(content);
    });
  }

  /// Check clipboard manually or on timer tick.
  /// If [force] is true, checks against database even if text == _lastKnownContent.
  Future<ClipboardEntry?> checkClipboard({bool force = false}) async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;

      if (text == null || text.trim().isEmpty) {
        return null;
      }

      // Check if this content was pushed by peer
      if (_ignoredContents.contains(text)) {
        _ignoredContents.remove(text);
        _lastKnownContent = text;
        return null;
      }

      // If not forced, check if text is identical to last known
      if (!force && text == _lastKnownContent) {
        return null;
      }

      // New local clipboard entry detected!
      _lastKnownContent = text;

      final entry = ClipboardEntry.create(
        deviceId: settings.deviceId,
        content: text,
      );

      // Save to SQLite
      await db.insertEntry(
        entry,
        maxEntries: settings.retentionLimit,
        maxDays: settings.retentionDays,
      );

      // Push to connected peers
      await syncService.pushLocalEntry(entry);

      // Emit to UI
      _newEntryController.add(entry);

      debugPrint('[ClipboardWatcher] Captured and pushed new entry: "${text.length > 30 ? '${text.substring(0, 30)}...' : text}"');
      return entry;
    } catch (e) {
      // System clipboard may be temporarily locked or busy
      return null;
    }
  }

  /// Copy an existing entry back to the system clipboard
  Future<void> copyToClipboard(ClipboardEntry entry) async {
    _lastKnownContent = entry.content;
    ignoreContent(entry.content);
    await Clipboard.setData(ClipboardData(text: entry.content));
  }

  void dispose() {
    stop();
    _newEntryController.close();
  }
}
