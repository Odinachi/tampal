import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/device_info.dart';
import '../../core/network/sync_service.dart';
import '../../core/providers/clipsync_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/connection_badge.dart';

class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key});

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController = TextEditingController();
  bool _isConnecting = false;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsServiceProvider);
    _ipController.text = settings.lastPairedHost ?? '';
    _portController.text = (settings.lastPairedPort ?? settings.serverPort).toString();

    // Start discovery when entering screen
    ref.read(discoveryServiceProvider).startDiscovery();
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _connectToPeer(String host, int port, {String? name}) async {
    setState(() => _isConnecting = true);
    final syncService = ref.read(syncServiceProvider);
    final success = await syncService.connectToPeer(host, port, peerName: name);

    if (!mounted) return;
    setState(() => _isConnecting = false);
    if (success) {
      final watcher = ref.read(clipboardWatcherProvider);
      await syncService.syncNow(watcher: watcher);
      await ref.read(clipboardHistoryProvider.notifier).loadEntries();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.successColor,
          content: Text('Connected and synced with ${name ?? '$host:$port'}'),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.errorColor,
          content: Text('Failed to connect to $host:$port. Ensure peer is running ClipSync on the same Wi-Fi.'),
        ),
      );
    }
  }

  void _disconnect() {
    ref.read(syncServiceProvider).disconnectAll();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Disconnected from peer')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsServiceProvider);
    final syncService = ref.watch(syncServiceProvider);
    final syncStatus = ref.watch(syncStatusProvider).value ?? syncService.status;
    final activePeer = ref.watch(activePeerProvider).value ?? syncService.activePeer;
    final discoveredPeers = ref.watch(discoveredPeersProvider).value ??
        ref.watch(discoveryServiceProvider).discoveredPeers;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair & Connect'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Restart Discovery',
            onPressed: () {
              final discovery = ref.read(discoveryServiceProvider);
              discovery.stopDiscovery();
              discovery.startDiscovery();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Scanning for devices on Wi-Fi...'), duration: Duration(seconds: 1)),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 1. Current Connection Status Card
          _buildActiveConnectionCard(syncStatus, activePeer),
          const SizedBox(height: 20),

          // 2. Discovered Devices (mDNS / Zeroconf)
          _buildDiscoveredSection(discoveredPeers),
          const SizedBox(height: 20),

          // 3. Manual Direct Connect Card
          _buildManualConnectCard(),
          const SizedBox(height: 20),

          // 4. This Device Information
          _buildThisDeviceInfoCard(settings, syncStatus),
        ],
      ),
    );
  }

  Widget _buildActiveConnectionCard(SyncStatus status, PeerDevice? peer) {
    final isConnected = status == SyncStatus.connected || status == SyncStatus.syncing;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isConnected
                        ? AppTheme.successColor.withValues(alpha: 0.15)
                        : const Color(0xFF334155),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isConnected ? Icons.phonelink_ring_rounded : Icons.phonelink_erase_rounded,
                    color: isConnected ? AppTheme.successColor : const Color(0xFF94A3B8),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isConnected
                            ? (peer?.name ?? 'Connected Device')
                            : (status == SyncStatus.listening
                                ? 'Ready for incoming connections'
                                : 'No Device Connected'),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isConnected && peer != null
                            ? '${peer.host}:${peer.port} • ${peer.platform.toUpperCase()}'
                            : (status == SyncStatus.listening
                                ? 'Listening on port ${_portController.text}'
                                : 'Select a discovered device or connect manually below'),
                        style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                      ),
                    ],
                  ),
                ),
                ConnectionBadge(status: status, peerName: peer?.name),
              ],
            ),
            if (isConnected) ...[
              const SizedBox(height: 16),
              const Divider(color: Color(0xFF334155)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.errorColor,
                      side: const BorderSide(color: AppTheme.errorColor),
                    ),
                    onPressed: _disconnect,
                    icon: const Icon(Icons.link_off_rounded, size: 16),
                    label: const Text('Disconnect'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: () async {
                      await ref.read(syncServiceProvider).syncNow();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Syncing clipboard history...')),
                        );
                      }
                    },
                    icon: const Icon(Icons.sync_rounded, size: 16),
                    label: const Text('Sync Now'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoveredSection(List<PeerDevice> peers) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Discovered Devices',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${peers.length}',
                style: const TextStyle(fontSize: 11, color: AppTheme.primaryLight, fontWeight: FontWeight.bold),
              ),
            ),
            const Spacer(),
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accentColor),
            ),
            const SizedBox(width: 6),
            const Text(
              'Scanning Wi-Fi',
              style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (peers.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.wifi_find_rounded, size: 36, color: Color(0xFF64748B)),
                    SizedBox(height: 12),
                    Text(
                      'No ClipSync devices found yet',
                      style: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFFF1F5F9)),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Make sure your other device is on the same local Wi-Fi network and has ClipSync open.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          ...peers.map((peer) {
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.accentColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    peer.platform == 'macos' || peer.platform == 'windows' || peer.platform == 'linux'
                        ? Icons.desktop_windows_rounded
                        : Icons.phone_android_rounded,
                    color: AppTheme.accentColor,
                    size: 20,
                  ),
                ),
                title: Text(peer.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  '${peer.host}:${peer.port} • ${peer.platform.toUpperCase()}',
                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                ),
                trailing: ElevatedButton(
                  onPressed: _isConnecting ? null : () => _connectToPeer(peer.host, peer.port, name: peer.name),
                  child: const Text('Connect'),
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _buildManualConnectCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.cable_rounded, color: AppTheme.primaryLight, size: 18),
                SizedBox(width: 8),
                Text('Direct Connect', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Connect directly to a peer by entering its local IP address and port.',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _ipController,
                    decoration: const InputDecoration(
                      labelText: 'IP Address',
                      hintText: '192.168.1.100',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      hintText: '42880',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isConnecting
                    ? null
                    : () {
                        final host = _ipController.text.trim();
                        final port = int.tryParse(_portController.text.trim()) ?? 42880;
                        if (host.isNotEmpty) {
                          _connectToPeer(host, port);
                        }
                      },
                icon: _isConnecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.link_rounded, size: 18),
                label: Text(_isConnecting ? 'Connecting...' : 'Connect to Address'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThisDeviceInfoCard(dynamic settings, SyncStatus status) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.info_outline_rounded, color: Color(0xFF94A3B8), size: 18),
                SizedBox(width: 8),
                Text('This Device Information', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              ],
            ),
            const SizedBox(height: 12),
            _infoRow('Device Name', settings.deviceName),
            _infoRow('Platform', settings.platformName.toUpperCase()),
            _infoRow('Listening Port', settings.serverPort.toString()),
            _infoRow('mDNS Service', '_clipsync._tcp'),
            _infoRow('Device ID', settings.deviceId),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12, color: Color(0xFFF1F5F9)),
            ),
          ),
        ],
      ),
    );
  }
}
