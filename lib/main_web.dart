import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
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
      title: 'ClipSync Web Hub',
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

enum _FilterCategory { all, links, code, text }

class _WebHomeScreenState extends ConsumerState<WebHomeScreen> with SingleTickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _composerController = TextEditingController();
  final TextEditingController _serverUrlController = TextEditingController();

  List<ClipboardEntry> _entries = [];
  bool _isSearching = false;
  String _searchQuery = '';
  _FilterCategory _currentFilter = _FilterCategory.all;
  bool _isLoading = false;
  bool _isSending = false;
  bool _isConnected = false;
  String? _errorMessage;
  Timer? _pollingTimer;

  late String _serverUrl;

  @override
  void initState() {
    super.initState();
    final host = (Uri.base.host.isNotEmpty && Uri.base.host != '0.0.0.0')
        ? Uri.base.host
        : 'localhost';
    _serverUrl = 'http://$host:${AppConstants.defaultWebPort}';
    _serverUrlController.text = _serverUrl;

    _fetchEntries();

    // Auto-poll every 3 seconds for real-time live sync
    _pollingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_isLoading && !_isSending) {
        _fetchEntries(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _searchController.dispose();
    _composerController.dispose();
    _serverUrlController.dispose();
    super.dispose();
  }

  Future<void> _fetchEntries({bool silent = false}) async {
    if (!silent) {
      setState(() => _isLoading = true);
    }

    try {
      final queryParam = _searchQuery.isNotEmpty ? '?q=${Uri.encodeComponent(_searchQuery)}' : '';
      final uri = Uri.parse('$_serverUrl/api/entries$queryParam');
      final res = await http.get(uri).timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        final List<dynamic> jsonList = jsonDecode(res.body) as List<dynamic>;
        final loaded = jsonList
            .map((e) => ClipboardEntry.fromSyncJson(e as Map<String, dynamic>))
            .toList();

        if (mounted) {
          setState(() {
            _entries = loaded;
            _isConnected = true;
            _errorMessage = null;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _isConnected = false;
            _errorMessage = 'Server status ${res.statusCode}';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnected = false;
          _errorMessage = 'Desktop server offline at $_serverUrl';
        });
      }
    } finally {
      if (!silent && mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _sendText() async {
    final text = _composerController.text.trim();
    if (text.isEmpty) return;

    setState(() => _isSending = true);

    try {
      final uri = Uri.parse('$_serverUrl/api/send');
      final res = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'content': text}),
      ).timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        _composerController.clear();
        await Clipboard.setData(ClipboardData(text: text));
        await _fetchEntries(silent: true);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: AppTheme.surfaceDark,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: AppTheme.successColor),
              ),
              content: Row(
                children: [
                  const Icon(Icons.check_circle_rounded, color: AppTheme.successColor, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Pushed to Mac & Android: "${text.length > 30 ? '${text.substring(0, 30)}...' : text}"',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: AppTheme.errorColor,
              content: Text('Failed to push text (HTTP ${res.statusCode})'),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppTheme.errorColor,
            content: Text('Connection error: $e'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  Future<void> _pasteFromSystemClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null && data!.text!.isNotEmpty) {
        _composerController.text = data.text!;
        setState(() {});
      }
    } catch (_) {}
  }

  Future<void> _deleteEntry(String id) async {
    try {
      final uri = Uri.parse('$_serverUrl/api/entries/$id');
      await http.delete(uri).timeout(const Duration(seconds: 3));
      setState(() {
        _entries.removeWhere((e) => e.id == id);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Entry removed across devices')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }

  void _showServerConfigDialog() {
    _serverUrlController.text = _serverUrl;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.darkCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.glassBorder),
        ),
        title: const Row(
          children: [
            Icon(Icons.hub_rounded, color: AppTheme.accentColor),
            SizedBox(width: 10),
            Text('ClipSync Hub Connection'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the address of the ClipSync Desktop server on your Wi-Fi network:',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _serverUrlController,
              decoration: const InputDecoration(
                labelText: 'Server Address',
                hintText: 'http://localhost:42881 or http://192.168.1.X:42881',
                prefixIcon: Icon(Icons.link_rounded, color: Color(0xFF94A3B8)),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Check your Mac or PC ClipSync app under "Web Dashboard" to find your active Wi-Fi address.',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
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
              final newUrl = _serverUrlController.text.trim();
              if (newUrl.isNotEmpty) {
                Navigator.pop(ctx);
                setState(() {
                  _serverUrl = newUrl.endsWith('/') ? newUrl.substring(0, newUrl.length - 1) : newUrl;
                });
                _fetchEntries();
              }
            },
            child: const Text('Connect & Sync'),
          ),
        ],
      ),
    );
  }

  List<ClipboardEntry> _getFilteredEntries() {
    var result = _entries;

    // 1. Text search
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      result = result.where((e) => e.content.toLowerCase().contains(q)).toList();
    }

    // 2. Category filter
    switch (_currentFilter) {
      case _FilterCategory.links:
        result = result.where((e) => e.content.startsWith('http://') || e.content.startsWith('https://')).toList();
        break;
      case _FilterCategory.code:
        result = result.where((e) {
          final c = e.content;
          return (c.startsWith('{') && c.endsWith('}')) ||
              (c.startsWith('[') && c.endsWith(']')) ||
              (c.contains('\n') && (c.contains('class ') || c.contains('def ') || c.contains('function ') || c.contains('import ')));
        }).toList();
        break;
      case _FilterCategory.text:
        result = result.where((e) {
          final c = e.content;
          final isLink = c.startsWith('http://') || c.startsWith('https://');
          final isCode = (c.startsWith('{') && c.endsWith('}')) || (c.contains('class ') || c.contains('def '));
          return !isLink && !isCode;
        }).toList();
        break;
      case _FilterCategory.all:
        break;
    }

    return result;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _getFilteredEntries();
    final linkCount = _entries.where((e) => e.content.startsWith('http://') || e.content.startsWith('https://')).length;
    final codeCount = _entries.where((e) => e.content.contains('class ') || e.content.contains('def ') || e.content.startsWith('{')).length;

    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      body: Stack(
        children: [
          // Background ambient gradient glow
          Positioned(
            top: -120,
            left: 0,
            right: 0,
            height: 380,
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.8),
                  radius: 1.1,
                  colors: [
                    AppTheme.primaryColor.withValues(alpha: 0.18),
                    AppTheme.accentColor.withValues(alpha: 0.08),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // Main Content Layout
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  // Top Modern Navigation Header
                  _buildHeader(),
                  const SizedBox(height: 8),

                  // Hub Connection & Latency Strip
                  _buildConnectionStrip(),
                  const SizedBox(height: 12),

                  // Floating 10x Push Composer
                  _buildComposer(),
                  const SizedBox(height: 12),

                  // Filter Categories & Search Bar
                  _buildFilterBar(linkCount, codeCount),
                  const SizedBox(height: 8),

                  // Clipboard Cards Feed
                  Expanded(
                    child: filtered.isEmpty
                        ? (_isLoading
                            ? const Center(
                                child: CircularProgressIndicator(color: AppTheme.accentColor),
                              )
                            : EmptyStateView(
                                title: _searchQuery.isNotEmpty ? 'No matching entries' : 'Clipboard is empty',
                                message: _isConnected
                                    ? 'Copy text on any device, or use the composer above to push new text.'
                                    : 'Make sure your ClipSync desktop app is running on your Mac/PC.',
                                icon: Icons.content_paste_off_rounded,
                                actionLabel: _isConnected ? null : 'Check Connection',
                                onAction: _isConnected ? null : _showServerConfigDialog,
                              ))
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 24),
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final entry = filtered[index];
                              return ClipboardCard(
                                entry: entry,
                                isLocal: entry.deviceId.contains('web'),
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
                                onDelete: () => _deleteEntry(entry.id),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              gradient: AppTheme.cyanGradient,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primaryColor.withValues(alpha: 0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: const Icon(Icons.copy_all_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'ClipSync',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppTheme.primaryLight.withValues(alpha: 0.3)),
                    ),
                    child: const Text(
                      'WEB HUB',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.primaryLight,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ],
              ),
              const Text(
                'Cross-Device Wi-Fi Clipboard Synchronization',
                style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
              ),
            ],
          ),
          const Spacer(),
          // Refresh Button
          IconButton(
            icon: _isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accentColor),
                  )
                : const Icon(Icons.refresh_rounded, color: Color(0xFF94A3B8)),
            tooltip: 'Sync now',
            onPressed: () => _fetchEntries(),
          ),
          const SizedBox(width: 4),
          // Server Settings
          IconButton(
            icon: const Icon(Icons.dns_rounded, color: Color(0xFF94A3B8)),
            tooltip: 'Server connection',
            onPressed: _showServerConfigDialog,
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionStrip() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _isConnected
              ? AppTheme.successColor.withValues(alpha: 0.3)
              : AppTheme.errorColor.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _isConnected ? AppTheme.successColor : AppTheme.errorColor,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: (_isConnected ? AppTheme.successColor : AppTheme.errorColor).withValues(alpha: 0.5),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _isConnected
                  ? 'Connected to Hub: $_serverUrl • ${_entries.length} items synced'
                  : (_errorMessage ?? 'Connecting to $_serverUrl...'),
              style: TextStyle(
                fontSize: 12,
                color: _isConnected ? const Color(0xFFE2E8F0) : const Color(0xFFF87171),
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: _showServerConfigDialog,
            child: const Text('Change Hub', style: TextStyle(fontSize: 12, color: AppTheme.accentColor)),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.glassBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.send_rounded, size: 16, color: AppTheme.accentColor),
              const SizedBox(width: 8),
              const Text(
                'Push to All Connected Devices',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Colors.white),
              ),
              const Spacer(),
              // Keyboard shortcut badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: const Text(
                  '⌘ + Enter',
                  style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: Color(0xFF94A3B8)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _composerController,
            maxLines: 3,
            style: const TextStyle(fontSize: 14, height: 1.45),
            decoration: InputDecoration(
              hintText: 'Type or paste anything here to sync to your Mac and Android phone...',
              filled: true,
              fillColor: const Color(0xFF0B101B),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppTheme.glassBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppTheme.glassBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppTheme.primaryLight, width: 1.5),
              ),
              contentPadding: const EdgeInsets.all(14),
            ),
            onSubmitted: (_) => _sendText(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // Paste button
              OutlinedButton.icon(
                icon: const Icon(Icons.content_paste_rounded, size: 14),
                label: const Text('Paste'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                onPressed: _pasteFromSystemClipboard,
              ),
              const SizedBox(width: 8),
              if (_composerController.text.isNotEmpty)
                TextButton(
                  onPressed: () {
                    _composerController.clear();
                    setState(() {});
                  },
                  child: const Text('Clear', style: TextStyle(color: Color(0xFF64748B), fontSize: 12)),
                ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _isSending ? null : _sendText,
                icon: _isSending
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.rocket_launch_rounded, size: 15),
                label: const Text('Push to Devices'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  backgroundColor: AppTheme.primaryColor,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar(int linkCount, int codeCount) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // Filter Chips
          _buildFilterChip('All', '${_entries.length}', _FilterCategory.all),
          const SizedBox(width: 8),
          _buildFilterChip('🔗 Links', '$linkCount', _FilterCategory.links),
          const SizedBox(width: 8),
          _buildFilterChip('💻 Code', '$codeCount', _FilterCategory.code),
          const SizedBox(width: 8),
          _buildFilterChip('📝 Notes', '${_entries.length - linkCount - codeCount}', _FilterCategory.text),
          const Spacer(),

          // Search Field
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: _isSearching ? 220 : 38,
            height: 38,
            child: _isSearching
                ? TextField(
                    controller: _searchController,
                    autofocus: true,
                    style: const TextStyle(fontSize: 13, color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Search...',
                      prefixIcon: const Icon(Icons.search_rounded, size: 16, color: Color(0xFF94A3B8)),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.close_rounded, size: 16, color: Color(0xFF94A3B8)),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                            _isSearching = false;
                          });
                        },
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    onChanged: (val) => setState(() => _searchQuery = val),
                  )
                : IconButton(
                    icon: const Icon(Icons.search_rounded, size: 20, color: Color(0xFF94A3B8)),
                    tooltip: 'Search history',
                    onPressed: () => setState(() => _isSearching = true),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, String count, _FilterCategory category) {
    final isSelected = _currentFilter == category;
    return InkWell(
      onTap: () => setState(() => _currentFilter = category),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primaryColor.withValues(alpha: 0.2)
              : AppTheme.darkCard,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? AppTheme.primaryLight : AppTheme.glassBorder,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? Colors.white : const Color(0xFF94A3B8),
              ),
            ),
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppTheme.primaryColor
                    : const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                count,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isSelected ? Colors.white : const Color(0xFF64748B),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
