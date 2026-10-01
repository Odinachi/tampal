import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/clipboard_entry.dart';
import '../../core/providers/tampal_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/clipboard_card.dart';
import '../widgets/connection_badge.dart';
import '../widgets/empty_state.dart';
import 'pairing_screen.dart';
import 'settings_screen.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;
  bool _isSyncing = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _triggerSyncNow() async {
    setState(() => _isSyncing = true);
    final syncService = ref.read(syncServiceProvider);
    final watcher = ref.read(clipboardWatcherProvider);
    final entry = await watcher.pushCurrentClipboard();
    await syncService.syncNow(watcher: watcher);
    await ref.read(clipboardHistoryProvider.notifier).loadEntries();
    if (mounted) {
      final msg = entry != null
          ? 'Synced clipboard: "${entry.content.length > 25 ? '${entry.content.substring(0, 25)}...' : entry.content}"'
          : 'Clipboard synchronized with peers';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
        ),
      );
      setState(() => _isSyncing = false);
    }
  }

  void _showSendTextDialog() {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.darkCard,
        title: const Text('Send to Peer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Type or paste text to send immediately to connected devices:',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: textController,
              autofocus: true,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'Enter text to sync...',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
          ElevatedButton(
            onPressed: () async {
              final text = textController.text.trim();
              if (text.isNotEmpty) {
                Navigator.pop(ctx);
                final settings = ref.read(settingsServiceProvider);
                final entry = ClipboardEntry.create(
                  deviceId: settings.deviceId,
                  content: text,
                );
                await ref.read(clipboardDatabaseProvider).insertEntry(entry);
                await ref.read(syncServiceProvider).pushLocalEntry(entry);
                await Clipboard.setData(ClipboardData(text: text));
                await ref.read(clipboardHistoryProvider.notifier).loadEntries();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Sent: "${text.length > 25 ? '${text.substring(0, 25)}...' : text}"'),
                    ),
                  );
                }
              }
            },
            child: const Text('Send & Copy'),
          ),
        ],
      ),
    );
  }

  void _confirmClearAll() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.darkCard,
        title: const Text('Clear History'),
        content: const Text('Are you sure you want to delete all saved clipboard entries? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.errorColor),
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(clipboardHistoryProvider.notifier).clearHistory();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Clipboard history cleared')),
              );
            },
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
  }

  Future<void> _showWebPortalDialog() async {
    final webServer = ref.read(webServerProvider);
    final portalUrl = await webServer.getPortalUrl();
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.darkCard,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.language_rounded, color: AppTheme.primaryLight, size: 20),
            ),
            const SizedBox(width: 12),
            const Text('Web Dashboard', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Access, search, and copy clipboard history in real-time from any browser on your Wi-Fi network:',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.link_rounded, color: AppTheme.accentColor, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SelectableText(
                      portalUrl,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    tooltip: 'Copy URL',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: portalUrl));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Web Portal URL copied to clipboard!')),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: webServer.isRunning ? AppTheme.successColor : AppTheme.errorColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  webServer.isRunning
                      ? 'Server Active (Port ${webServer.port}) • ${webServer.clientCount} browser(s)'
                      : 'Server Stopped',
                  style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.open_in_browser_rounded, size: 18),
            label: const Text('Open Browser'),
            onPressed: () async {
              Navigator.pop(ctx);
              await webServer.openBrowser();
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final historyAsync = ref.watch(clipboardHistoryProvider);
    final syncStatus = ref.watch(syncStatusProvider).value ?? ref.watch(syncServiceProvider).status;
    final activePeer = ref.watch(activePeerProvider).value ?? ref.watch(syncServiceProvider).activePeer;
    final settings = ref.watch(settingsServiceProvider);

    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Search clipboard entries...',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF94A3B8)),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8)),
                    onPressed: () {
                      _searchController.clear();
                      ref.read(historySearchQueryProvider.notifier).state = '';
                      setState(() => _isSearching = false);
                    },
                  ),
                ),
                onChanged: (val) {
                  ref.read(historySearchQueryProvider.notifier).state = val;
                },
              )
            : Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppTheme.primaryColor, AppTheme.accentColor],
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.sync_alt_rounded, color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 10),
                  const Text('Tampal'),
                ],
              ),
        actions: [
          if (!_isSearching) ...[
            // Theme toggle button
            IconButton(
              icon: Icon(
                Theme.of(context).brightness == Brightness.dark
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
              ),
              tooltip: Theme.of(context).brightness == Brightness.dark
                  ? 'Switch to Light Mode'
                  : 'Switch to Dark Mode',
              onPressed: () {
                ref.read(appThemeModeProvider.notifier).toggle();
              },
            ),
            // Search toggle
            IconButton(
              icon: const Icon(Icons.search_rounded),
              tooltip: 'Search history',
              onPressed: () => setState(() => _isSearching = true),
            ),
            // Send / Paste new text directly
            IconButton(
              icon: const Icon(Icons.add_circle_outline_rounded),
              tooltip: 'Send text to peer',
              onPressed: _showSendTextDialog,
            ),
            // Sync now button (manual sync trigger)
            IconButton(
              icon: _isSyncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accentColor),
                    )
                  : const Icon(Icons.sync_rounded),
              tooltip: 'Sync Now',
              onPressed: _triggerSyncNow,
            ),
            // Web Dashboard button
            IconButton(
              icon: const Icon(Icons.language_rounded),
              tooltip: 'Web Dashboard',
              onPressed: _showWebPortalDialog,
            ),
            // Pairing / Devices button
            IconButton(
              icon: const Icon(Icons.devices_rounded),
              tooltip: 'Paired Devices',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PairingScreen()),
                );
              },
            ),
            // Settings button
            IconButton(
              icon: const Icon(Icons.settings_rounded),
              tooltip: 'Settings',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
            ),
            // Clear all
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded),
              tooltip: 'Clear All',
              onPressed: _confirmClearAll,
            ),
          ],
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                ConnectionBadge(
                  status: syncStatus,
                  peerName: activePeer?.name,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const PairingScreen()),
                    );
                  },
                ),
                const Spacer(),
                historyAsync.when(
                  data: (entries) => Text(
                    '${entries.length} items',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                  ),
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
      body: historyAsync.when(
        data: (entries) {
          if (entries.isEmpty) {
            return EmptyStateView(
              title: _searchController.text.isNotEmpty
                  ? 'No matching entries'
                  : 'No clipboard history yet',
              message: _searchController.text.isNotEmpty
                  ? 'Try searching with different keywords.'
                  : 'Copy text anywhere on this device or a connected peer to see it synchronized automatically.',
              actionLabel: 'Sync Now',
              onAction: _triggerSyncNow,
            );
          }

          return RefreshIndicator(
            onRefresh: () async {
              await ref.read(clipboardHistoryProvider.notifier).loadEntries();
            },
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                final isLocal = entry.deviceId == settings.deviceId;

                return ClipboardCard(
                  key: ValueKey(entry.id),
                  entry: entry,
                  isLocal: isLocal,
                  onCopy: () {
                    ref.read(clipboardHistoryProvider.notifier).copyEntryToClipboard(entry);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Copied to clipboard: "${entry.content.length > 25 ? '${entry.content.substring(0, 25)}...' : entry.content}"',
                        ),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                  onDelete: () {
                    ref.read(clipboardHistoryProvider.notifier).deleteEntry(entry.id);
                  },
                );
              },
            ),
          );
        },
        loading: () => const Center(
          child: CircularProgressIndicator(color: AppTheme.primaryColor),
        ),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Error loading clipboard history: $err',
              style: const TextStyle(color: AppTheme.errorColor),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppTheme.primaryColor,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.sync_rounded),
        label: const Text('Sync Now'),
        onPressed: _triggerSyncNow,
      ),
    );
  }
}
