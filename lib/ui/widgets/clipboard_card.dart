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
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          color: _isHovered ? AppTheme.darkCardHover : AppTheme.darkCard,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _isHovered ? AppTheme.glassBorderHover : AppTheme.glassBorder,
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: InkWell(
          onTap: _handleCopy,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Header Row
                Row(
                  children: [
                    // Device Origin Pill
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F1016),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: AppTheme.glassBorder),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            deviceIcon,
                            size: 12,
                            color: const Color(0xFF8E93A4),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            deviceLabel,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF8E93A4),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),

                    // Content Type Pill
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F1016),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: AppTheme.glassBorder),
                      ),
                      child: Text(
                        contentType.name.toUpperCase(),
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF8E93A4),
                          letterSpacing: 0.2,
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
                      style: const TextStyle(fontSize: 11, color: Color(0xFF525768), fontFamily: 'monospace'),
                    ),
                    const SizedBox(width: 8),

                    // Copy button with checkmark morph
                    IconButton(
                      icon: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        child: _copied
                            ? const Icon(Icons.check_rounded, key: ValueKey('copied'), size: 16, color: AppTheme.successColor)
                            : const Icon(Icons.copy_rounded, key: ValueKey('copy'), size: 15, color: Color(0xFF64748B)),
                      ),
                      splashRadius: 16,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: _handleCopy,
                      tooltip: _copied ? 'Copied!' : 'Copy',
                    ),
                    const SizedBox(width: 6),

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
                const SizedBox(height: 10),

                // Content Snippet
                Container(
                  width: double.infinity,
                  padding: isCode || isUrl
                      ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
                      : EdgeInsets.zero,
                  decoration: isCode || isUrl
                      ? BoxDecoration(
                          color: const Color(0xFF090A0D),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFF1E222E)),
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
                      color: isUrl ? const Color(0xFF60A5FA) : const Color(0xFFEDEDED),
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
                            size: 15,
                            color: const Color(0xFF8E93A4),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _expanded ? 'Show less' : 'Show full content',
                            style: const TextStyle(
                              color: Color(0xFF8E93A4),
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _ContentType { url, json, code, text }
