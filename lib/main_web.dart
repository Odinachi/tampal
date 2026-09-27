import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/constants/app_constants.dart';
import 'core/models/clipboard_entry.dart';
import 'ui/theme/app_theme.dart';
import 'ui/widgets/clipboard_card.dart';
import 'ui/widgets/empty_state.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const ProviderScope(
      child: ClipSyncWebApp(),
    ),
  );
}

class ClipSyncWebApp extends StatelessWidget {
  const ClipSyncWebApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClipSync Web',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const WebHomeScreen(),
    );
  }
}

class WebHomeScreen extends ConsumerStatefulWidget {
  const WebHomeScreen({super.key});

  @override
  ConsumerState<WebHomeScreen> createState() => _WebHomeScreenState();
}

class _WebHomeScreenState extends ConsumerState<WebHomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _textController = TextEditingController();
  final List<ClipboardEntry> _entries = [];
  bool _isSearching = false;
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _addLocalEntry(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final entry = ClipboardEntry.create(
      deviceId: 'web-browser',
      content: trimmed,
    );

    setState(() {
      _entries.insert(0, entry);
    });

    await Clipboard.setData(ClipboardData(text: trimmed));
    _textController.clear();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Copied and added to clipboard: "${trimmed.length > 25 ? '${trimmed.substring(0, 25)}...' : trimmed}"'),
          backgroundColor: AppTheme.successColor,
        ),
      );
    }
  }

  void _showAddDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.darkCard,
        title: const Row(
          children: [
            Icon(Icons.add_circle_outline_rounded, color: AppTheme.accentColor),
            SizedBox(width: 10),
            Text('Add & Copy Text'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter text to copy to your clipboard and save to history:',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _textController,
              autofocus: true,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'Paste or type text here...',
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
            onPressed: () {
              Navigator.pop(ctx);
              _addLocalEntry(_textController.text);
            },
            child: const Text('Copy to Clipboard'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _searchQuery.isEmpty
        ? _entries
        : _entries.where((e) => e.content.toLowerCase().contains(_searchQuery.toLowerCase())).toList();

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
                  prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF94A3B8)),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8)),
                    onPressed: () {
                      _searchController.clear();
                      setState(() {
                        _searchQuery = '';
                        _isSearching = false;
                      });
                    },
                  ),
                ),
                onChanged: (val) {
                  setState(() => _searchQuery = val);
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
                  const Text('${AppConstants.appName} Web'),
                ],
              ),
        actions: [
          if (!_isSearching) ...[
            IconButton(
              icon: const Icon(Icons.search_rounded),
              tooltip: 'Search',
              onPressed: () => setState(() => _isSearching = true),
            ),
            IconButton(
              icon: const Icon(Icons.add_circle_outline_rounded),
              tooltip: 'Add Entry',
              onPressed: _showAddDialog,
            ),
            if (_entries.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.delete_sweep_rounded),
                tooltip: 'Clear History',
                onPressed: () {
                  setState(() => _entries.clear());
                },
              ),
          ],
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            children: [
              // Info banner for web users
              Container(
                margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.darkCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.25)),
                ),
                child: Row(
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
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ClipSync Web Portal',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'For full real-time Wi-Fi synchronization with your desktop node, open http://<desktop-ip>:42881 in your browser.',
                            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? EmptyStateView(
                        title: _searchQuery.isNotEmpty ? 'No matches found' : 'No clipboard entries yet',
                        message: _searchQuery.isNotEmpty
                            ? 'Try a different search query'
                            : 'Click the + button to add and copy text in your browser',
                        icon: Icons.content_paste_off_rounded,
                        actionLabel: _searchQuery.isNotEmpty ? null : 'Add New Entry',
                        onAction: _searchQuery.isNotEmpty ? null : _showAddDialog,
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final entry = filtered[index];
                          return ClipboardCard(
                            entry: entry,
                            isLocal: true,
                            onCopy: () async {
                              await Clipboard.setData(ClipboardData(text: entry.content));
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Copied to system clipboard!'),
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                              }
                            },
                            onDelete: () {
                              setState(() {
                                _entries.removeWhere((e) => e.id == entry.id);
                              });
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddDialog,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Entry'),
      ),
    );
  }
}
