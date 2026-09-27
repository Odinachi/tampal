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
  final TextEditingController _composerController = TextEditingController();
  final TextEditingController _serverUrlController = TextEditingController();

  List<ClipboardEntry> _entries = [];
  bool _isSearching = false;
  String _searchQuery = '';
  bool _isLoading = false;
  bool _isSending = false;
  bool _isConnected = false;
  String? _errorMessage;
  Timer? _pollingTimer;

  late String _serverUrl;

  @override
  void initState() {
    super.initState();
    // Default to the same host that served the page, or localhost
    final host = (Uri.base.host.isNotEmpty && Uri.base.host != '0.0.0.0')
        ? Uri.base.host
        : 'localhost';
    _serverUrl = 'http://$host:${AppConstants.defaultWebPort}';
    _serverUrlController.text = _serverUrl;

    _fetchEntries();

    // Poll every 3 seconds for real-time synchronization
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
            _errorMessage = 'Server returned status ${res.statusCode}';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnected = false;
          _errorMessage = 'Could not connect to ClipSync server at $_serverUrl';
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
              backgroundColor: AppTheme.successColor,
              content: Text('Pushed to Mac & Android: "${text.length > 25 ? '${text.substring(0, 25)}...' : text}"'),
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

  Future<void> _deleteEntry(String id) async {
    try {
      final uri = Uri.parse('$_serverUrl/api/entries/$id');
      await http.delete(uri).timeout(const Duration(seconds: 3));
      setState(() {
        _entries.removeWhere((e) => e.id == id);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Entry deleted across devices')),
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
        title: const Row(
          children: [
            Icon(Icons.dns_rounded, color: AppTheme.accentColor),
            SizedBox(width: 10),
            Text('ClipSync Server URL'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the address of the ClipSync Desktop server on your Wi-Fi network:',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _serverUrlController,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'e.g. http://localhost:42881 or http://192.168.1.X:42881',
                prefixIcon: Icon(Icons.link_rounded, color: Color(0xFF94A3B8)),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Tip: Check the desktop app under "Web Dashboard" to see the active address.',
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
            child: const Text('Connect'),
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
                      _fetchEntries();
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
                  const Text('ClipSync Web'),
                ],
              ),
        actions: [
          if (!_isSearching) ...[
            IconButton(
              icon: const Icon(Icons.search_rounded),
              tooltip: 'Search history',
              onPressed: () => setState(() => _isSearching = true),
            ),
            IconButton(
              icon: _isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accentColor),
                    )
                  : const Icon(Icons.refresh_rounded),
              tooltip: 'Refresh entries',
              onPressed: () => _fetchEntries(),
            ),
            IconButton(
              icon: const Icon(Icons.settings_ethernet_rounded),
              tooltip: 'Server Connection',
              onPressed: _showServerConfigDialog,
            ),
          ],
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            children: [
              // Connection Status Bar
              Container(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _isConnected ? AppTheme.successColor : AppTheme.errorColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _isConnected
                            ? 'Connected to $_serverUrl (${_entries.length} items)'
                            : (_errorMessage ?? 'Connecting to $_serverUrl...'),
                        style: TextStyle(
                          fontSize: 12,
                          color: _isConnected ? const Color(0xFFF1F5F9) : const Color(0xFFF87171),
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: _showServerConfigDialog,
                      child: const Text('Change', style: TextStyle(fontSize: 12, color: AppTheme.accentColor)),
                    ),
                  ],
                ),
              ),

              // Instant Push Composer
              Container(
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.darkCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.send_rounded, size: 16, color: AppTheme.accentColor),
                        SizedBox(width: 8),
                        Text(
                          'Push Text to Connected Devices',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _composerController,
                      maxLines: 2,
                      decoration: InputDecoration(
                        hintText: 'Type or paste text here to immediately sync to Mac & Android...',
                        filled: true,
                        fillColor: const Color(0xFF0F172A),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      onSubmitted: (_) => _sendText(),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Updates desktop clipboard & phone',
                          style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
                        ),
                        ElevatedButton.icon(
                          onPressed: _isSending ? null : _sendText,
                          icon: _isSending
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.send_rounded, size: 14),
                          label: const Text('Push to Devices'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Entries Feed
              Expanded(
                child: filtered.isEmpty
                    ? (_isLoading
                        ? const Center(child: CircularProgressIndicator(color: AppTheme.accentColor))
                        : EmptyStateView(
                            title: _searchQuery.isNotEmpty ? 'No matches found' : 'No clipboard entries yet',
                            message: _isConnected
                                ? 'Copy text on your Mac or Android phone, or use the composer above!'
                                : 'Make sure the ClipSync desktop app is running on your Mac/PC.',
                            icon: Icons.content_paste_off_rounded,
                            actionLabel: _isConnected ? null : 'Check Connection',
                            onAction: _isConnected ? null : _showServerConfigDialog,
                          ))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final entry = filtered[index];
                          return ClipboardCard(
                            entry: entry,
                            isLocal: entry.deviceId == 'web-client' || entry.deviceId == 'web-browser',
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
    );
  }
}
