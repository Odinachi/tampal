import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/models/clipboard_entry.dart';
import '../theme/app_theme.dart';

class ClipboardCard extends StatefulWidget {
  final ClipboardEntry entry;
  final bool isLocal;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  const ClipboardCard({
    super.key,
    required this.entry,
    required this.isLocal,
    required this.onCopy,
    required this.onDelete,
  });

  @override
  State<ClipboardCard> createState() => _ClipboardCardState();
}

class _ClipboardCardState extends State<ClipboardCard> {
  bool _copied = false;
  bool _expanded = false;
  bool _isHovered = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  void _handleCopy() {
    widget.onCopy();
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final difference = now.difference(dt.toLocal());

    if (difference.inSeconds < 45) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      return DateFormat('MMM d, h:mm a').format(dt.toLocal());
    }
  }

  _ContentType _detectContentType(String content) {
    final trimmed = content.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return _ContentType.url;
    }
    if ((trimmed.startsWith('{') && trimmed.endsWith('}')) ||
        (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
      return _ContentType.json;
    }
    if (trimmed.contains('\n') &&
        (trimmed.contains('class ') ||
            trimmed.contains('def ') ||
            trimmed.contains('function ') ||
            trimmed.contains('const ') ||
            trimmed.contains('import ') ||
            trimmed.contains('return '))) {
      return _ContentType.code;
    }
    return _ContentType.text;
  }

  @override
  Widget build(BuildContext context) {
    final contentType = _detectContentType(widget.entry.content);
    final isUrl = contentType == _ContentType.url;
    final isCode = contentType == _ContentType.code || contentType == _ContentType.json;
    final isLong = widget.entry.content.length > 160 || widget.entry.content.split('\n').length > 3;

    // Device identification
    final deviceId = widget.entry.deviceId.toLowerCase();
    final isWeb = deviceId.contains('web');
    final isAndroid = deviceId.contains('android') || deviceId.contains('mobile');
    final deviceLabel = widget.isLocal
        ? 'This Device'
        : (isWeb ? 'Web' : (isAndroid ? 'Android' : 'Desktop'));
    final deviceIcon = widget.isLocal
        ? Icons.devices_rounded
        : (isWeb
            ? Icons.language_rounded
            : (isAndroid ? Icons.phone_android_rounded : Icons.laptop_mac_rounded));

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: _isHovered ? AppTheme.darkCardHover : AppTheme.darkCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _isHovered
                ? AppTheme.primaryColor.withValues(alpha: 0.5)
                : AppTheme.glassBorder,
            width: _isHovered ? 1.5 : 1,
          ),
          boxShadow: _isHovered
              ? [
                  BoxShadow(
                    color: AppTheme.primaryColor.withValues(alpha: 0.12),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: InkWell(
          onTap: _handleCopy,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Header Row
                Row(
                  children: [
                    // Device Origin Pill
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: widget.isLocal
                            ? AppTheme.primaryColor.withValues(alpha: 0.15)
                            : AppTheme.accentColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            deviceIcon,
                            size: 13,
                            color: widget.isLocal ? AppTheme.primaryLight : AppTheme.accentColor,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            deviceLabel,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: widget.isLocal ? AppTheme.primaryLight : AppTheme.accentColor,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Content Type Pill
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: contentType == _ContentType.url
                            ? AppTheme.accentColor.withValues(alpha: 0.12)
                            : (isCode
                                ? AppTheme.violetColor.withValues(alpha: 0.12)
                                : const Color(0xFF334155).withValues(alpha: 0.5)),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        contentType.name.toUpperCase(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: contentType == _ContentType.url
                              ? AppTheme.accentColor
                              : (isCode ? AppTheme.violetColor : const Color(0xFF94A3B8)),
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Timestamp
                    Text(
                      _formatTimestamp(widget.entry.createdAt),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF64748B),
                        fontWeight: FontWeight.w500,
                      ),
                    ),

                    const Spacer(),

                    // Character count
                    Text(
                      '${widget.entry.content.length} chars',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF475569), fontFamily: 'monospace'),
                    ),
                    const SizedBox(width: 8),

                    // Delete button
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, size: 16),
                      color: const Color(0xFF64748B),
                      splashRadius: 16,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: widget.onDelete,
                      tooltip: 'Delete entry',
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Content Snippet
                Container(
                  width: double.infinity,
                  padding: isCode || isUrl
                      ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
                      : EdgeInsets.zero,
                  decoration: isCode || isUrl
                      ? BoxDecoration(
                          color: const Color(0xFF0C101A),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF1E283D)),
                        )
                      : null,
                  child: Text(
                    widget.entry.content,
                    maxLines: _expanded ? null : (isCode ? 5 : 4),
                    overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: isCode || isUrl ? 13 : 14,
                      height: 1.5,
                      fontFamily: isCode || isUrl ? 'monospace' : null,
                      color: isUrl ? AppTheme.accentColor : const Color(0xFFF1F5F9),
                    ),
                  ),
                ),

                if (isLong) ...[
                  const SizedBox(height: 6),
                  GestureDetector(
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                            size: 16,
                            color: AppTheme.accentColor,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _expanded ? 'Show less' : 'Show full content',
                            style: const TextStyle(
                              color: AppTheme.accentColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 12),
                const Divider(color: Color(0xFF1E293B), height: 1),
                const SizedBox(height: 8),

                // Bottom Action Bar: 1-click Copy feedback
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Click card to copy',
                      style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _copied
                            ? AppTheme.successColor.withValues(alpha: 0.15)
                            : AppTheme.primaryColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _copied
                              ? AppTheme.successColor.withValues(alpha: 0.4)
                              : AppTheme.primaryColor.withValues(alpha: 0.2),
                        ),
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: _copied
                            ? const Row(
                                key: ValueKey('copied'),
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.check_rounded, size: 14, color: AppTheme.successColor),
                                  SizedBox(width: 4),
                                  Text(
                                    'COPIED',
                                    style: TextStyle(
                                      color: AppTheme.successColor,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              )
                            : const Row(
                                key: ValueKey('copy'),
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.copy_rounded, size: 13, color: AppTheme.primaryLight),
                                  SizedBox(width: 4),
                                  Text(
                                    'COPY',
                                    style: TextStyle(
                                      color: AppTheme.primaryLight,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _ContentType { url, json, code, text }
