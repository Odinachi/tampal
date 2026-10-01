import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'core/constants/app_constants.dart';
import 'core/models/clipboard_entry.dart';
import 'core/providers/tampal_providers.dart';
import 'ui/theme/app_theme.dart';
import 'ui/widgets/clipboard_card.dart';
import 'ui/widgets/empty_state.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const ProviderScope(
      child: TampalWebApp(),
    ),
  );
}

class TampalWebApp extends ConsumerWidget {
  const TampalWebApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(appThemeModeProvider);

    return MaterialApp(
      title: 'Tampal',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
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
          final isDark = Theme.of(context).brightness == Brightness.dark;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: isDark ? AppTheme.surfaceDark : Colors.white,
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
                      'Pushed to all devices: "${text.length > 30 ? '${text.substring(0, 30)}...' : text}"',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                      ),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightBorder),
        ),
        title: Row(
          children: [
            const Icon(Icons.hub_rounded, color: AppTheme.accentColor),
            const SizedBox(width: 10),
            Text(
              'Tampal Hub Connection',
              style: TextStyle(
                color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter the address of the Tampal Desktop server on your Wi-Fi network:',
              style: TextStyle(
                color: isDark ? const Color(0xFF94A3B8) : AppTheme.lightTextSecondary,
                fontSize: 13,
                height: 1.4,
              ),
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
            Text(
              'Check your Mac or PC Tampal app under "Web Dashboard" to find your active Wi-Fi address.',
              style: TextStyle(
                color: isDark ? const Color(0xFF64748B) : AppTheme.lightTextMuted,
                fontSize: 11,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : AppTheme.lightTextSecondary),
            ),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? AppTheme.darkBg : AppTheme.lightBg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            children: [
              const SizedBox(height: 12),
              // Top Clean Navigation Header
              _buildHeader(isDark),
              const SizedBox(height: 6),

              // Hub Connection Status Strip
              _buildConnectionStrip(isDark),
              const SizedBox(height: 12),

              // Raycast Command Broadcast Box
              _buildComposer(isDark),
              const SizedBox(height: 12),

              // Clean Segmented Tabs & Search
              _buildFilterBar(linkCount, codeCount, isDark),
              const SizedBox(height: 8),

              // Clipboard Feed
              Expanded(
                child: filtered.isEmpty
                    ? (_isLoading
                        ? const Center(
                            child: CircularProgressIndicator(color: AppTheme.primaryColor),
                          )
                        : EmptyStateView(
                            title: _searchQuery.isNotEmpty ? 'No matching entries' : 'No clipboard history',
                            message: _isConnected
                                ? 'Copies from any connected device will sync automatically.'
                                : 'Ensure Tampal desktop app is running on your Mac/PC.',
                            icon: Icons.content_paste_off_rounded,
                            actionLabel: _isConnected ? null : 'Configure Hub',
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
                                    content: Text('Copied'),
                                    duration: Duration(milliseconds: 1500),
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
    );
  }

  Widget _buildHeader(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: isDark ? AppTheme.glassBorder : AppTheme.lightBorder),
            ),
            child: Icon(
              Icons.sync_alt_rounded,
              color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
              size: 16,
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tampal',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                  letterSpacing: -0.2,
                ),
              ),
              Text(
                'Local Clipboard Network',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                ),
              ),
            ],
          ),
          const Spacer(),
          // Theme Toggle Button
          IconButton(
            icon: Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
              size: 19,
            ),
            tooltip: isDark ? 'Switch to Light mode' : 'Switch to Dark mode',
            onPressed: () {
              ref.read(appThemeModeProvider.notifier).toggle();
            },
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: _isLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryColor),
                  )
                : Icon(
                    Icons.refresh_rounded,
                    color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                    size: 19,
                  ),
            tooltip: 'Sync now',
            onPressed: () => _fetchEntries(),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: Icon(
              Icons.tune_rounded,
              color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
              size: 19,
            ),
            tooltip: 'Hub settings',
            onPressed: _showServerConfigDialog,
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionStrip(bool isDark) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.surfaceDark : AppTheme.surfaceLight,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: isDark ? AppTheme.glassBorder : AppTheme.lightBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: _isConnected ? AppTheme.successColor : AppTheme.errorColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _isConnected
                  ? 'Connected to Hub ($_serverUrl) • ${_entries.length} items synced'
                  : (_errorMessage ?? 'Connecting to $_serverUrl...'),
              style: TextStyle(
                fontSize: 12,
                color: _isConnected
                    ? (isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary)
                    : const Color(0xFFF87171),
                fontWeight: FontWeight.w400,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: _showServerConfigDialog,
            child: Text(
              'Configure',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(bool isDark) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDark ? AppTheme.glassBorder : AppTheme.lightBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _composerController,
            minLines: 2,
            maxLines: 4,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.45,
              color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
            ),
            decoration: InputDecoration(
              hintText: 'Type or paste to broadcast across your devices...',
              hintStyle: TextStyle(
                color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                fontSize: 13,
              ),
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
            onSubmitted: (_) => _sendText(),
          ),
          const SizedBox(height: 8),
          Divider(
            color: isDark ? const Color(0xFF191C26) : const Color(0xFFE5E7EB),
            height: 1,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // Shortcut hint
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F1016) : const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: isDark ? AppTheme.glassBorder : AppTheme.lightBorder),
                ),
                child: Text(
                  '⌘ Enter',
                  style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'to broadcast',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                ),
              ),
              const Spacer(),
              // Paste button
              OutlinedButton.icon(
                icon: const Icon(Icons.content_paste_rounded, size: 13),
                label: const Text('Paste'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  side: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightBorder),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  foregroundColor: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                  textStyle: const TextStyle(fontSize: 12),
                ),
                onPressed: _pasteFromSystemClipboard,
              ),
              const SizedBox(width: 8),
              if (_composerController.text.isNotEmpty) ...[
                TextButton(
                  onPressed: () {
                    _composerController.clear();
                    setState(() {});
                  },
                  child: Text(
                    'Clear',
                    style: TextStyle(
                      color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
              ],
              ElevatedButton(
                onPressed: _isSending ? null : _sendText,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  backgroundColor: isDark ? Colors.white : const Color(0xFF111827),
                  foregroundColor: isDark ? const Color(0xFF0C0D11) : Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
                child: _isSending
                    ? SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: isDark ? const Color(0xFF0C0D11) : Colors.white,
                        ),
                      )
                    : const Text(
                        'Broadcast',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar(int linkCount, int codeCount, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // Clean Segmented Tabs
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F1016) : const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: isDark ? AppTheme.glassBorder : AppTheme.lightBorder),
            ),
            child: Row(
              children: [
                _buildSegmentTab('All', '${_entries.length}', _FilterCategory.all, isDark),
                _buildSegmentTab('Links', '$linkCount', _FilterCategory.links, isDark),
                _buildSegmentTab('Code', '$codeCount', _FilterCategory.code, isDark),
                _buildSegmentTab('Text', '${_entries.length - linkCount - codeCount}', _FilterCategory.text, isDark),
              ],
            ),
          ),
          const Spacer(),

          // Clean Search Field
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: _isSearching ? 200 : 34,
            height: 32,
            child: _isSearching
                ? TextField(
                    controller: _searchController,
                    autofocus: true,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Search...',
                      hintStyle: TextStyle(
                        fontSize: 12,
                        color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                      ),
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        size: 14,
                        color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                      ),
                      suffixIcon: IconButton(
                        icon: Icon(
                          Icons.close_rounded,
                          size: 14,
                          color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                            _isSearching = false;
                          });
                        },
                      ),
                      filled: true,
                      fillColor: isDark ? const Color(0xFF0F1016) : const Color(0xFFF3F4F6),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightBorder),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightBorder),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(
                          color: isDark ? AppTheme.glassBorderHover : AppTheme.primaryColor,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                    ),
                    onChanged: (val) => setState(() => _searchQuery = val),
                  )
                : IconButton(
                    icon: Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: 'Search',
                    onPressed: () => setState(() => _isSearching = true),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentTab(String label, String count, _FilterCategory category, bool isDark) {
    final isSelected = _currentFilter == category;
    return InkWell(
      onTap: () => setState(() => _currentFilter = category),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? AppTheme.darkCard : Colors.white)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          boxShadow: isSelected && !isDark
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected
                    ? (isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary)
                    : (isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary),
              ),
            ),
            const SizedBox(width: 5),
            Text(
              count,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
                color: isSelected
                    ? (isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary)
                    : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
