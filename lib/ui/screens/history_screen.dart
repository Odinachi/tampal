import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/clipsync_providers.dart';
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
    await syncService.syncNow();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sync requested from peer'),
          duration: Duration(seconds: 1),
        ),
      );
      setState(() => _isSyncing = false);
    }
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
                    child: const Icon(Icons.copy_rounded, color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 10),
                  const Text('ClipSync'),
                ],
              ),
        actions: [
          if (!_isSearching) ...[
            // Search toggle
            IconButton(
              icon: const Icon(Icons.search_rounded),
              tooltip: 'Search history',
              onPressed: () => setState(() => _isSearching = true),
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
