import 'dart:async';
import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import '../constants/app_constants.dart';
import '../models/device_info.dart';

class DiscoveryService {
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _discoverySubscription;

  final String currentDeviceId;
  final String currentDeviceName;
  final String currentPlatform;
  final int port;

  final Map<String, PeerDevice> _discoveredPeers = {};
  final _peersController = StreamController<List<PeerDevice>>.broadcast();

  bool _isBroadcasting = false;
  bool _isDiscovering = false;

  DiscoveryService({
    required this.currentDeviceId,
    required this.currentDeviceName,
    required this.currentPlatform,
    required this.port,
  });

  Stream<List<PeerDevice>> get peersStream => _peersController.stream;
  List<PeerDevice> get discoveredPeers => _discoveredPeers.values.toList();
  bool get isBroadcasting => _isBroadcasting;
  bool get isDiscovering => _isDiscovering;

  /// Start mDNS broadcast advertising this ClipSync service on the network
  Future<void> startBroadcasting() async {
    if (_isBroadcasting) return;

    try {
      final service = BonsoirService(
        name: '$currentDeviceName ($currentDeviceId)',
        type: AppConstants.serviceType,
        port: port,
        attributes: {
          'id': currentDeviceId,
          'name': currentDeviceName,
          'platform': currentPlatform,
        },
      );

      _broadcast = BonsoirBroadcast(service: service);
      await _broadcast!.ready;
      await _broadcast!.start();
      _isBroadcasting = true;
      debugPrint('[DiscoveryService] mDNS broadcast started on port $port');
    } catch (e) {
      debugPrint('[DiscoveryService] Broadcast start error: $e');
    }
  }

  /// Stop mDNS advertising
  Future<void> stopBroadcasting() async {
    if (!_isBroadcasting || _broadcast == null) return;
    try {
      await _broadcast!.stop();
      _broadcast = null;
      _isBroadcasting = false;
      debugPrint('[DiscoveryService] mDNS broadcast stopped');
    } catch (e) {
      debugPrint('[DiscoveryService] Broadcast stop error: $e');
    }
  }

  /// Start discovering other ClipSync devices on the local Wi-Fi network
  Future<void> startDiscovery() async {
    if (_isDiscovering) return;

    try {
      _discovery = BonsoirDiscovery(type: AppConstants.serviceType);
      await _discovery!.ready;

      _discoverySubscription = _discovery!.eventStream?.listen((event) {
        _handleDiscoveryEvent(event);
      });

      await _discovery!.start();
      _isDiscovering = true;
      debugPrint('[DiscoveryService] mDNS discovery started');
    } catch (e) {
      debugPrint('[DiscoveryService] Discovery start error: $e');
    }
  }

  void _handleDiscoveryEvent(BonsoirDiscoveryEvent event) {
    if (event.service == null) return;

    if (event.type == BonsoirDiscoveryEventType.discoveryServiceFound) {
      // Resolve service to obtain host IP and port
      try {
        event.service!.resolve(_discovery!.serviceResolver);
      } catch (e) {
        debugPrint('[DiscoveryService] Error triggering resolve: $e');
      }
    } else if (event.type == BonsoirDiscoveryEventType.discoveryServiceResolved) {
      final resolved = event.service as ResolvedBonsoirService;
      final host = resolved.host;
      if (host == null || host.isEmpty) return;

      final attrs = resolved.attributes;
      final peerId = attrs['id'] ?? resolved.name;
      
      // Do not add ourselves
      if (peerId == currentDeviceId) return;

      final peerName = attrs['name'] ?? resolved.name;
      final peerPlatform = attrs['platform'] ?? 'unknown';

      final peer = PeerDevice(
        id: peerId,
        name: peerName,
        host: host,
        port: resolved.port,
        platform: peerPlatform,
        lastSeen: DateTime.now(),
      );

      _discoveredPeers[peer.id] = peer;
      _peersController.add(_discoveredPeers.values.toList());
      debugPrint('[DiscoveryService] Found peer: ${peer.name} at ${peer.host}:${peer.port}');
    } else if (event.type == BonsoirDiscoveryEventType.discoveryServiceLost) {
      final name = event.service?.name;
      _discoveredPeers.removeWhere((id, p) => p.name == name || id == name);
      _peersController.add(_discoveredPeers.values.toList());
    }
  }

  /// Manually add or update a known peer (e.g. from manual IP entry or reconnect)
  void addManualPeer(PeerDevice peer) {
    _discoveredPeers[peer.id] = peer;
    _peersController.add(_discoveredPeers.values.toList());
  }

  /// Stop discovering
  Future<void> stopDiscovery() async {
    if (!_isDiscovering) return;
    try {
      await _discoverySubscription?.cancel();
      _discoverySubscription = null;
      await _discovery?.stop();
      _discovery = null;
      _isDiscovering = false;
      debugPrint('[DiscoveryService] mDNS discovery stopped');
    } catch (e) {
      debugPrint('[DiscoveryService] Discovery stop error: $e');
    }
  }

  /// Dispose discovery and broadcast resources
  Future<void> dispose() async {
    await stopDiscovery();
    await stopBroadcasting();
    await _peersController.close();
  }
}
