import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'core/models/clipboard_entry.dart';
import 'core/providers/tampal_providers.dart';
import 'ui/theme/app_theme.dart';
import 'ui/widgets/clipboard_card.dart';
import 'ui/widgets/empty_state.dart';
import 'webrtc/tampal_webrtc.dart';

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
  final TextEditingController _roomCodeController = TextEditingController();

  // ignore: prefer_final_fields — reassigned in setState
  List<ClipboardEntry> _entries = [];
  bool _isSearching = false;
  String _searchQuery = '';
  _FilterCategory _currentFilter = _FilterCategory.all;
  bool _isSending = false;
  Timer? _pollingTimer;

  // WebRTC P2P
  late TampalWebRTC _rtc;
  WebRtcState _rtcState = WebRtcState.idle;
  String _roomCode = '';
  StreamSubscription<WebRtcState>? _rtcStateSub;
  StreamSubscription<Map<String, dynamic>>? _rtcMessageSub;

  bool get _isConnected => _rtcState == WebRtcState.connected;

  @override
  void initState() {
    super.initState();

    // Determine signaling base URL (Vercel origin or localhost for dev)
    final uri = Uri.base;
    final signalBase = (uri.scheme == 'https' || uri.host.endsWith('.vercel.app'))
        ? uri.origin
        : 'http://localhost:3000'; // local dev fallback

    _rtc = TampalWebRTC(signalBase: signalBase);

    _rtcStateSub = _rtc.stateStream.listen((state) {
      if (mounted) setState(() => _rtcState = state);
    });

    _rtcMessageSub = _rtc.messageStream.listen((msg) {
      if (msg['type'] == 'entry') {
        try {
          final data = msg['data'] as Map<String, dynamic>;
          if (data['type'] == 'delete') {
            final id = data['id'] as String?;
            if (id != null && mounted) {
              setState(() => _entries.removeWhere((e) => e.id == id));
            }
            return;
          }
          final entry = ClipboardEntry.fromSyncJson(data);
          if (mounted) {
            setState(() {
              // Prepend and deduplicate by id
              _entries.removeWhere((e) => e.id == entry.id);
              _entries.insert(0, entry);
            });
          }
        } catch (_) {}
      }
    });

    // Auto-join if page was opened via a scanned QR link: ?join=XXXX
    final joinCode = uri.queryParameters['join'];
    if (joinCode != null && RegExp(r'^\d{4}$').hasMatch(joinCode)) {
      // Slight delay to let Flutter finish building
      Future.microtask(() => _rtc.joinWithAnswer(joinCode));
    }
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _rtcStateSub?.cancel();
    _rtcMessageSub?.cancel();
    _rtc.dispose();
    _searchController.dispose();
    _composerController.dispose();
    _roomCodeController.dispose();
    super.dispose();
  }

  /// Generate a random 4-digit pairing room code
  String _generateRoomCode() {
    final rng = Random.secure();
    return (1000 + rng.nextInt(9000)).toString();
  }

  void _sendText() {
    final text = _composerController.text.trim();
    if (text.isEmpty) return;
    if (!_isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppTheme.errorColor,
          content: Text('Not connected to a peer. Tap \'P2P Connect\' to pair.'),
        ),
      );
      return;
    }
    setState(() => _isSending = true);
    try {
      final entry = ClipboardEntry.create(deviceId: 'web-self', content: text);
      final sent = _rtc.sendEntry(entry.toSyncJson());
      if (sent) {
        _composerController.clear();
        setState(() {
          _entries.insert(0, entry);
        });
        Clipboard.setData(ClipboardData(text: text));
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
                    'Sent P2P: "${text.length > 30 ? '${text.substring(0, 30)}...' : text}"',
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
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: AppTheme.errorColor,
            content: Text('Could not send — DataChannel not open yet.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
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

  void _deleteEntry(String id) {
    setState(() => _entries.removeWhere((e) => e.id == id));
    // Notify peer to also remove (best-effort)
    _rtc.sendEntry({'type': 'delete', 'id': id});
  }

  Future<void> _showP2PConnectDialog() async {
    // Generate a new room code each time the dialog opens
    _roomCode = _generateRoomCode();
    _roomCodeController.clear();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final joinCodeController = TextEditingController();
    bool dialogDismissed = false;
    Timer? autoCloseTimer;

    void safelyCloseDialog(BuildContext dialogCtx) {
      if (dialogDismissed) return;
      dialogDismissed = true;
      autoCloseTimer?.cancel();
      if (dialogCtx.mounted && Navigator.of(dialogCtx, rootNavigator: true).canPop()) {
        Navigator.of(dialogCtx, rootNavigator: true).pop();
      }
    }

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        bool isHosting = false;
        return StatefulBuilder(
        builder: (ctx, setDlgState) {

          // Listen to RTC state changes to update the dialog
          void onRtcState(WebRtcState s) {
            if (dialogDismissed || !ctx.mounted) return;
            setDlgState(() {});
            // Auto-close dialog safely once when peer connects
            if (s == WebRtcState.connected) {
              autoCloseTimer?.cancel();
              autoCloseTimer = Timer(const Duration(milliseconds: 700), () {
                safelyCloseDialog(ctx);
              });
            }
          }

          // ── Waiting / Hosting screen ────────────────────────────────────
          Widget buildHostingScreen() {
            final rtcState = _rtcState;
            final Color statusColor;
            final String statusLabel;
            final bool spinning;
            switch (rtcState) {
              case WebRtcState.waiting:
                statusColor = const Color(0xFFF59E0B);
                statusLabel = 'Waiting for peer to scan\u2026';
                spinning = true;
              case WebRtcState.connecting:
                statusColor = const Color(0xFFF59E0B);
                statusLabel = 'Peer found \u2014 establishing link\u2026';
                spinning = true;
              case WebRtcState.connected:
                statusColor = AppTheme.successColor;
                statusLabel = 'Connected! \u2714';
                spinning = false;
              default:
                statusColor = AppTheme.errorColor;
                statusLabel = 'Something went wrong. Try again.';
                spinning = false;
            }

            final joinUrl = '${Uri.base.origin}/?join=$_roomCode';

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Status pill
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: statusColor.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (spinning)
                        SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.8,
                            color: statusColor,
                          ),
                        )
                      else
                        Icon(Icons.check_circle_rounded, color: statusColor, size: 13),
                      const SizedBox(width: 7),
                      Text(
                        statusLabel,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: statusColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                // QR Code
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: QrImageView(
                    data: joinUrl,
                    version: QrVersions.auto,
                    size: 180,
                    backgroundColor: Colors.white,
                    padding: const EdgeInsets.all(10),
                  ),
                ),
                const SizedBox(height: 16),
                // 4-digit code blocks
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: _roomCode.split('').map((digit) => Container(
                    width: 42,
                    height: 50,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E222E) : Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.accentColor.withValues(alpha: 0.6)),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.accentColor.withValues(alpha: 0.1),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      digit,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'monospace',
                        color: AppTheme.accentColor,
                      ),
                    ),
                  )).toList(),
                ),
                const SizedBox(height: 12),
                Text(
                  'Scan the QR or enter the code on the other device',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                  ),
                ),
              ],
            );
          }

          // ── Pair screen (initial) ───────────────────────────────────────
          Widget buildPairScreen() {
            return SizedBox(
              width: 340,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // HOST side preview
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF0F1016) : const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: isDark ? AppTheme.glassBorder : AppTheme.lightBorder),
                    ),
                    child: Column(
                      children: [
                        Text(
                          'On this device \u2014 Share this code',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: QrImageView(
                            data: '${Uri.base.origin}/?join=$_roomCode',
                            version: QrVersions.auto,
                            size: 140,
                            backgroundColor: Colors.white,
                            padding: const EdgeInsets.all(8),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: _roomCode.split('').map((digit) => Container(
                            width: 36,
                            height: 42,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF1E222E) : Colors.white,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: AppTheme.accentColor.withValues(alpha: 0.5)),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              digit,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                fontFamily: 'monospace',
                                color: AppTheme.accentColor,
                              ),
                            ),
                          )).toList(),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Tap \u201cHost Session\u201d to activate',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Divider(color: isDark ? AppTheme.glassBorder : AppTheme.lightBorder),
                  const SizedBox(height: 12),
                  // JOINER side
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'On the other device \u2014 Enter their code',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: joinCodeController,
                              maxLength: 4,
                              keyboardType: TextInputType.number,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                fontFamily: 'monospace',
                                letterSpacing: 6,
                                color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                              ),
                              decoration: InputDecoration(
                                hintText: '0000',
                                hintStyle: TextStyle(
                                  color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                                  letterSpacing: 6,
                                ),
                                counterText: '',
                                filled: true,
                                fillColor: isDark ? const Color(0xFF0F1016) : const Color(0xFFF3F4F6),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightBorder),
                                ),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: () async {
                              final code = joinCodeController.text.trim();
                              if (code.length == 4) {
                                safelyCloseDialog(ctx);
                                await _rtc.joinWithAnswer(code);
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.accentColor,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            ),
                            child: const Text('Join', style: TextStyle(fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            );
          }

          return AlertDialog(
            backgroundColor: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightBorder),
            ),
            title: Row(
              children: [
                const Icon(Icons.wifi_tethering_rounded, color: AppTheme.accentColor),
                const SizedBox(width: 10),
                Text(
                  isHosting ? 'Waiting for Peer\u2026' : 'P2P Browser Connect',
                  style: TextStyle(
                    color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            content: isHosting ? buildHostingScreen() : buildPairScreen(),
            actions: isHosting
                ? [
                    TextButton(
                      onPressed: () {
                        safelyCloseDialog(ctx);
                        _rtc.close();
                      },
                      child: Text(
                        'Cancel',
                        style: TextStyle(color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary),
                      ),
                    ),
                  ]
                : [
                    TextButton(
                      onPressed: () => safelyCloseDialog(ctx),
                      child: Text(
                        'Cancel',
                        style: TextStyle(color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary),
                      ),
                    ),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.wifi_tethering_rounded, size: 15),
                      label: const Text('Host Session'),
                      onPressed: () async {
                        setDlgState(() => isHosting = true);
                        _rtcStateSub?.cancel();
                        _rtcStateSub = _rtc.stateStream.listen((s) {
                          if (mounted) setState(() => _rtcState = s);
                          onRtcState(s);
                        });
                        await _rtc.createOffer(_roomCode);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isDark ? Colors.white : const Color(0xFF111827),
                        foregroundColor: isDark ? const Color(0xFF0C0D11) : Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ],
          );
        },
        );
      },
    );

    dialogDismissed = true;
    autoCloseTimer?.cancel();
    joinCodeController.dispose();

    // Restore standard stream subscription without reference to dialog context
    _rtcStateSub?.cancel();
    _rtcStateSub = _rtc.stateStream.listen((state) {
      if (mounted) setState(() => _rtcState = state);
    });
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
                    ? EmptyStateView(
                            title: _searchQuery.isNotEmpty ? 'No matching entries' : 'No clipboard history',
                            message: _isConnected
                                ? 'Type in the composer above and hit Broadcast to send P2P.'
                                : 'Tap the Wi-Fi icon in the header to pair with another browser.',
                            icon: Icons.content_paste_off_rounded,
                            actionLabel: _isConnected ? null : 'Connect P2P',
                            onAction: _isConnected ? null : _showP2PConnectDialog,
                    )
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
                'Local Wi-Fi Clipboard Network',
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
            icon: Icon(
                    Icons.refresh_rounded,
                    color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                    size: 19,
                  ),
            tooltip: 'Refresh',
            onPressed: () => setState(() {}),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(
                _isConnected ? Icons.wifi_tethering_rounded : Icons.wifi_tethering_off_rounded,
                key: ValueKey(_isConnected),
                color: _isConnected
                    ? AppTheme.successColor
                    : (isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary),
                size: 19,
              ),
            ),
            tooltip: _isConnected ? 'P2P Connected — tap to disconnect' : 'Connect P2P',
            onPressed: _isConnected
                ? () { _rtc.close(); setState(() {}); }
                : _showP2PConnectDialog,
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionStrip(bool isDark) {
    // Map WebRTC state to color + label
    final Color dotColor;
    final String statusLabel;
    switch (_rtcState) {
      case WebRtcState.connected:
        dotColor = AppTheme.successColor;
        statusLabel = 'P2P connected • ${_entries.length} items';
      case WebRtcState.waiting:
        dotColor = const Color(0xFFF59E0B);
        statusLabel = 'Waiting for peer to join…';
      case WebRtcState.connecting:
        dotColor = const Color(0xFFF59E0B);
        statusLabel = 'Establishing secure P2P link…';
      case WebRtcState.error:
        dotColor = AppTheme.errorColor;
        statusLabel = 'Connection failed. Try pairing again.';
      case WebRtcState.disconnected:
        dotColor = AppTheme.errorColor;
        statusLabel = 'Peer disconnected.';
      case WebRtcState.idle:
        dotColor = isDark ? const Color(0xFF3B4258) : const Color(0xFFD1D5DB);
        statusLabel = 'No peer — tap ‘P2P Connect’ to pair browsers';
    }

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
          // Pulsing dot for transitional states
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              statusLabel,
              style: TextStyle(
                fontSize: 12,
                color: _isConnected
                    ? (isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary)
                    : (_rtcState == WebRtcState.error || _rtcState == WebRtcState.disconnected
                        ? AppTheme.errorColor
                        : (isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary)),
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
            onPressed: _isConnected
                ? () { _rtc.close(); setState(() {}); }
                : _showP2PConnectDialog,
            child: Text(
              _isConnected ? 'Disconnect' : 'Connect',
              style: TextStyle(
                fontSize: 12,
                color: _isConnected ? AppTheme.errorColor : (isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary),
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
              hintText: _isConnected
                  ? 'Type or paste to send P2P to your connected browser…'
                  : 'Connect a peer first (tap the Wi-Fi icon above)…',
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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? const Color(0xFF1E222E) : Colors.white)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          boxShadow: isSelected && !isDark
              ? [const BoxShadow(color: Color(0x0F000000), blurRadius: 2, offset: Offset(0, 1))]
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
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: isSelected
                    ? (isDark ? const Color(0xFF2B3040) : const Color(0xFFE5E7EB))
                    : (isDark ? const Color(0xFF151821) : const Color(0xFFF3F4F6)),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                count,
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: 'monospace',
                  color: isSelected
                      ? (isDark ? AppTheme.accentColor : AppTheme.primaryColor)
                      : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
