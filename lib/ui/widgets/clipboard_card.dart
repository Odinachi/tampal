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

  @override
  Widget build(BuildContext context) {
    final isUrl = widget.entry.content.startsWith('http://') ||
        widget.entry.content.startsWith('https://');

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        onTap: _handleCopy,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: Badge, Timestamp, Action Buttons
              Row(
                children: [
                  // Local vs Synced Badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: widget.isLocal
                          ? AppTheme.primaryColor.withValues(alpha: 0.15)
                          : AppTheme.accentColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          widget.isLocal ? Icons.smartphone_rounded : Icons.cloud_sync_rounded,
                          size: 12,
                          color: widget.isLocal ? AppTheme.primaryLight : AppTheme.accentColor,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          widget.isLocal ? 'This Device' : 'Synced',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: widget.isLocal ? AppTheme.primaryLight : AppTheme.accentColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _formatTimestamp(widget.entry.createdAt),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  const Spacer(),
                  // Character count
                  Text(
                    '${widget.entry.content.length} chars',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF475569)),
                  ),
                  const SizedBox(width: 8),
                  // Delete button
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    color: const Color(0xFF64748B),
                    splashRadius: 18,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: widget.onDelete,
                    tooltip: 'Delete entry',
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Content snippet
              GestureDetector(
                onLongPress: () => setState(() => _expanded = !_expanded),
                child: Text(
                  widget.entry.content,
                  maxLines: _expanded ? null : 4,
                  overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    fontFamily: isUrl ? 'monospace' : null,
                    color: isUrl ? AppTheme.accentColor : const Color(0xFFF1F5F9),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Bottom tap to copy bar
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.entry.content.length > 200 && !_expanded
                        ? 'Tap to copy • Long press to expand'
                        : 'Tap to copy back to clipboard',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: _copied
                        ? const Row(
                            key: ValueKey('copied'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.check_circle_rounded, size: 16, color: AppTheme.successColor),
                              SizedBox(width: 4),
                              Text(
                                'Copied!',
                                style: TextStyle(
                                  color: AppTheme.successColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          )
                        : const Row(
                            key: ValueKey('copy'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.copy_rounded, size: 14, color: AppTheme.primaryLight),
                              SizedBox(width: 4),
                              Text(
                                'Copy',
                                style: TextStyle(
                                  color: AppTheme.primaryLight,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
