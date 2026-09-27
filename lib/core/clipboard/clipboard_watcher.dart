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

  final _newEntryController = StreamController<ClipboardEntry>.broadcast();

  ClipboardWatcher({
    required this.settings,
    required this.db,
    required this.syncService,
  }) {
    // Register callback so when remote peer pushes clipboard,
    // the watcher suppresses echo loops
    syncService.onRemoteClipboardApplied = ignoreContent;
  }

  Stream<ClipboardEntry> get newEntryStream => _newEntryController.stream;
  bool get isWatching => _isWatching;

  /// Start watching the system clipboard
  Future<void> start({Duration interval = const Duration(milliseconds: 750)}) async {
    if (_isWatching) return;
    _isWatching = true;

    // Register lifecycle observer to check clipboard instantly when app resumes
    WidgetsBinding.instance.addObserver(this);

    // Initialize with current clipboard content so existing text is not treated as a new copy
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null) {
        _lastKnownContent = data!.text;
      }
    } catch (_) {}

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
      // Immediate check when coming to foreground
      checkClipboard();
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

  /// Check clipboard manually or on timer tick
  Future<ClipboardEntry?> checkClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;

      if (text == null || text.trim().isEmpty) {
        return null;
      }

      // Check if text is identical to last known
      if (text == _lastKnownContent) {
        return null;
      }

      // Check if this content was pushed by peer
      if (_ignoredContents.contains(text)) {
        _ignoredContents.remove(text);
        _lastKnownContent = text;
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

      return entry;
    } catch (e) {
      // System clipboard may be temporarily locked or busy
      return null;
    }
  }

  /// Copy an existing entry back to the system clipboard
  Future<void> copyToClipboard(ClipboardEntry entry) async {
    _lastKnownContent = entry.content;
    await Clipboard.setData(ClipboardData(text: entry.content));
  }

  void dispose() {
    stop();
    _newEntryController.close();
  }
}
