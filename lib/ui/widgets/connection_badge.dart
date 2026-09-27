import 'package:flutter/material.dart';
import '../../core/network/sync_service.dart';
import '../theme/app_theme.dart';

class ConnectionBadge extends StatelessWidget {
  final SyncStatus status;
  final String? peerName;
  final VoidCallback? onTap;

  const ConnectionBadge({
    super.key,
    required this.status,
    this.peerName,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Color badgeColor;
    String label;
    IconData icon;

    switch (status) {
      case SyncStatus.connected:
        badgeColor = AppTheme.successColor;
        label = peerName != null ? 'Synced with $peerName' : 'Connected';
        icon = Icons.link_rounded;
        break;
      case SyncStatus.syncing:
        badgeColor = AppTheme.accentColor;
        label = 'Syncing...';
        icon = Icons.sync_rounded;
        break;
      case SyncStatus.listening:
        badgeColor = AppTheme.primaryLight;
        label = 'Listening for peers';
        icon = Icons.wifi_tethering_rounded;
        break;
      case SyncStatus.connecting:
        badgeColor = AppTheme.warningColor;
        label = 'Connecting...';
        icon = Icons.sensors_rounded;
        break;
      case SyncStatus.error:
        badgeColor = AppTheme.errorColor;
        label = 'Connection Error';
        icon = Icons.warning_amber_rounded;
        break;
      case SyncStatus.idle:
      default:
        badgeColor = const Color(0xFF64748B);
        label = 'Not Connected';
        icon = Icons.link_off_rounded;
        break;
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: badgeColor.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: badgeColor.withOpacity(0.3), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: badgeColor,
                boxShadow: [
                  BoxShadow(
                    color: badgeColor.withOpacity(0.6),
                    blurRadius: 6,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(icon, size: 14, color: badgeColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: badgeColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
