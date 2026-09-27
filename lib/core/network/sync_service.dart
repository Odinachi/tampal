import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../database/clipboard_database.dart';
import '../models/clipboard_entry.dart';
import '../models/device_info.dart';
import '../models/sync_message.dart';
import '../services/settings_service.dart';
import 'sync_connection.dart';

enum SyncStatus {
  idle,
  listening,
  connecting,
  connected,
  syncing,
  error,
}

class SyncService {
  final SettingsService settings;
  final ClipboardDatabase db;

  ServerSocket? _serverSocket;
  final List<SyncConnection> _connections = [];
  Timer? _reconnectTimer;

  SyncStatus _status = SyncStatus.idle;
  String? _statusMessage;
  PeerDevice? _activePeer;

  final _statusController = StreamController<SyncStatus>.broadcast();
  final _activePeerController = StreamController<PeerDevice?>.broadcast();
  final _entryReceivedController = StreamController<ClipboardEntry>.broadcast();

  // Internal callback so ClipboardWatcher can update its cache on remote incoming entry
  void Function(String remoteContent)? onRemoteClipboardApplied;
  // Callback when clipboard could not be set immediately (e.g. Android background focus restriction)
  void Function(String pendingContent)? onPendingClipboardContent;

  SyncService({
    required this.settings,
    required this.db,
  });

  SyncStatus get status => _status;
  String? get statusMessage => _statusMessage;
  PeerDevice? get activePeer => _activePeer;
  bool get isConnected => _status == SyncStatus.connected || _status == SyncStatus.syncing;
  List<SyncConnection> get connections => List.unmodifiable(_connections);

  Stream<SyncStatus> get statusStream => _statusController.stream;
  Stream<PeerDevice?> get activePeerStream => _activePeerController.stream;
  Stream<ClipboardEntry> get entryReceivedStream => _entryReceivedController.stream;

  void _setStatus(SyncStatus status, [String? message]) {
    _status = status;
    _statusMessage = message;
    _statusController.add(status);
  }

  void _setActivePeer(PeerDevice? peer) {
    _activePeer = peer;
    _activePeerController.add(peer);
  }

  /// Start TCP ServerSocket on specified or default port (used by Desktop entry point)
  Future<bool> startServer({int? port}) async {
    final listenPort = port ?? settings.serverPort;
    try {
      await stopServer();
      _serverSocket = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        listenPort,
        shared: true,
      );

      _serverSocket!.listen(
        _handleIncomingClient,
        onError: (e) {
          debugPrint('[SyncService] Server error: $e');
          _setStatus(SyncStatus.error, 'Server error: $e');
        },
      );

      debugPrint('[SyncService] TCP Server listening on port $listenPort');
      _setStatus(SyncStatus.listening, 'Listening on port $listenPort');
      return true;
    } catch (e) {
      debugPrint('[SyncService] Failed to bind ServerSocket on port $listenPort: $e');
      _setStatus(SyncStatus.error, 'Failed to start server: $e');
      return false;
    }
  }

  /// Stop TCP ServerSocket
  Future<void> stopServer() async {
    if (_serverSocket != null) {
      await _serverSocket!.close();
      _serverSocket = null;
    }
    for (final conn in List.of(_connections)) {
      conn.dispose();
    }
    _connections.clear();
    _setActivePeer(null);
    _setStatus(SyncStatus.idle);
  }

  /// Handle an incoming socket connection from a peer
  void _handleIncomingClient(Socket clientSocket) {
    debugPrint('[SyncService] Incoming connection from ${clientSocket.remoteAddress.address}:${clientSocket.remotePort}');

    final connection = SyncConnection(
      socket: clientSocket,
      isIncoming: true,
      onMessage: _handleMessage,
      onClosed: _handleConnectionClosed,
    );

    _connections.add(connection);
    _performHandshake(connection);
  }

  /// Connect to a remote peer (used by Mobile entry point or manual connect)
  Future<bool> connectToPeer(String host, int port, {String? peerName}) async {
    // If already connected to this peer, avoid opening duplicate connection
    for (final conn in _connections) {
      final p = conn.peerDevice;
      final connHost = conn.remoteAddress.replaceAll('::ffff:', '');
      final targetHost = host.replaceAll('::ffff:', '');
      if (connHost == targetHost || (p != null && (p.host == host || (peerName != null && p.name == peerName)))) {
        debugPrint('[SyncService] Already connected to $host:$port');
        _setStatus(SyncStatus.connected, 'Connected to ${peerName ?? _activePeer?.name ?? host}');
        return true;
      }
    }

    _setStatus(SyncStatus.connecting, 'Connecting to $host:$port...');
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 7),
      );

      final connection = SyncConnection(
        socket: socket,
        isIncoming: false,
        onMessage: _handleMessage,
        onClosed: _handleConnectionClosed,
        peerDevice: PeerDevice(
          id: host,
          name: peerName ?? 'ClipSync Desktop',
          host: host,
          port: port,
          lastSeen: DateTime.now(),
          isConnected: true,
        ),
      );

      _connections.add(connection);
      await settings.saveLastPairedPeer(host, port);
      _performHandshake(connection);
      return true;
    } catch (e) {
      debugPrint('[SyncService] Failed to connect to $host:$port: $e');
      _setStatus(SyncStatus.error, 'Connection failed: $e');
      _scheduleAutoReconnect();
      return false;
    }
  }

  /// Perform initial handshake on connection
  Future<void> _performHandshake(SyncConnection conn) async {
    final latestLocal = await db.getLatestEntry();
    final handshake = HandshakePayload(
      deviceId: settings.deviceId,
      deviceName: settings.deviceName,
      platform: settings.platformName,
      latestTimestamp: latestLocal?.createdAt,
    );

    conn.sendMessage(SyncMessage.handshake(handshake));
    debugPrint('[SyncService] Sent handshake from ${settings.deviceName} (${settings.deviceId})');
  }

  /// Handle incoming protocol messages
  Future<void> _handleMessage(SyncConnection conn, SyncMessage msg) async {
    switch (msg.type) {
      case SyncMessageType.handshake:
        await _onHandshakeReceived(conn, HandshakePayload.fromJson(msg.data));
        break;
      case SyncMessageType.syncRequest:
        await _onSyncRequestReceived(conn, msg.data);
        break;
      case SyncMessageType.syncResponse:
        await _onSyncResponseReceived(conn, msg.data);
        break;
      case SyncMessageType.pushEntry:
        await _onPushEntryReceived(conn, msg.data);
        break;
      case SyncMessageType.ping:
      case SyncMessageType.pong:
        break;
    }
  }

  /// Process handshake from remote peer
  Future<void> _onHandshakeReceived(SyncConnection conn, HandshakePayload remote) async {
    debugPrint('[SyncService] Received handshake from ${remote.deviceName} (${remote.deviceId}, ${remote.platform})');

    final peer = PeerDevice(
      id: remote.deviceId,
      name: remote.deviceName,
      host: conn.remoteAddress,
      port: conn.remotePort,
      platform: remote.platform,
      lastSeen: DateTime.now(),
      isConnected: true,
      isPaired: true,
    );

    conn.peerDevice = peer;
    _setActivePeer(peer);
    _setStatus(SyncStatus.connected, 'Connected to ${remote.deviceName}');

    // Cancel reconnect attempts once connected
    _reconnectTimer?.cancel();

    // 1. Immediately exchange recent local entries (up to 30) with peer so peers are immediately in sync
    final recentLocal = await db.getEntries(limit: 30);
    if (recentLocal.isNotEmpty) {
      debugPrint('[SyncService] Exchanging ${recentLocal.length} local entries with peer ${remote.deviceName}');
      conn.sendMessage(SyncMessage.syncResponse(recentLocal));
    }

    // 2. Request peer entries missing on our end
    final latestLocal = await db.getLatestEntry();
    conn.sendMessage(SyncMessage.syncRequest(since: latestLocal?.createdAt));
  }

  /// Peer is requesting entries since a timestamp
  Future<void> _onSyncRequestReceived(SyncConnection conn, Map<String, dynamic> data) async {
    final sinceStr = data['since'] as String?;
    List<ClipboardEntry> missing;
    if (sinceStr != null && sinceStr.isNotEmpty) {
      final since = DateTime.tryParse(sinceStr);
      if (since != null) {
        missing = await db.getEntriesSince(since);
      } else {
        missing = await db.getEntries(limit: 30);
      }
    } else {
      missing = await db.getEntries(limit: 30);
    }

    if (missing.isNotEmpty) {
      conn.sendMessage(SyncMessage.syncResponse(missing));
    }
  }

  /// Peer replied with sync entries
  Future<void> _onSyncResponseReceived(SyncConnection conn, Map<String, dynamic> data) async {
    final entriesRaw = data['entries'] as List<dynamic>? ?? [];
    debugPrint('[SyncService] Received sync response with ${entriesRaw.length} entries');

    ClipboardEntry? newestReceived;

    for (final raw in entriesRaw) {
      if (raw is Map<String, dynamic>) {
        try {
          final entry = ClipboardEntry.fromSyncJson(raw);
          // Only process entries from other devices
          if (entry.deviceId == settings.deviceId) continue;

          final inserted = await db.insertEntry(
            entry,
            maxEntries: settings.retentionLimit,
            maxDays: settings.retentionDays,
          );
          if (inserted) {
            _entryReceivedController.add(entry);
          }

          if (newestReceived == null || entry.createdAt.isAfter(newestReceived.createdAt)) {
            newestReceived = entry;
          }
        } catch (e) {
          debugPrint('[SyncService] Error parsing entry from sync response: $e');
        }
      }
    }

    // If entries were received from a remote peer, apply the newest one to the system clipboard
    if (newestReceived != null) {
      try {
        onRemoteClipboardApplied?.call(newestReceived.content);
        await Clipboard.setData(ClipboardData(text: newestReceived.content));
        debugPrint('[SyncService] Updated system clipboard with synced entry: "${newestReceived.content.length > 30 ? '${newestReceived.content.substring(0, 30)}...' : newestReceived.content}"');
      } catch (e) {
        debugPrint('[SyncService] Warning: Could not set system clipboard (app may lack focus): $e');
        onPendingClipboardContent?.call(newestReceived.content);
      }
    }
  }

  /// Real-time entry pushed over socket
  Future<void> _onPushEntryReceived(SyncConnection conn, Map<String, dynamic> data) async {
    try {
      final entry = ClipboardEntry.fromSyncJson(data);

      // Prevent echoing back our own entries
      if (entry.deviceId == settings.deviceId) return;

      debugPrint('[SyncService] Received push entry from ${entry.deviceId}: "${entry.content.length > 30 ? '${entry.content.substring(0, 30)}...' : entry.content}"');

      // 1. Save to local SQLite
      await db.insertEntry(
        entry,
        maxEntries: settings.retentionLimit,
        maxDays: settings.retentionDays,
      );

      // 2. Notify watcher to ignore echoing this exact text
      onRemoteClipboardApplied?.call(entry.content);

      // 3. Set the device's clipboard safely (handles Android background / focus exceptions)
      try {
        await Clipboard.setData(ClipboardData(text: entry.content));
      } catch (e) {
        debugPrint('[SyncService] Warning: Could not set system clipboard (app may lack focus): $e');
        onPendingClipboardContent?.call(entry.content);
      }

      // 4. Always notify UI
      _entryReceivedController.add(entry);
    } catch (e) {
      debugPrint('[SyncService] Error processing push entry: $e');
    }
  }

  /// Push a new local clipboard entry to all connected peers
  Future<void> pushLocalEntry(ClipboardEntry entry) async {
    if (_connections.isEmpty) {
      debugPrint('[SyncService] No active connections to push entry: "${entry.content}"');
      return;
    }

    debugPrint('[SyncService] Pushing entry to ${_connections.length} peer(s): "${entry.content.length > 30 ? '${entry.content.substring(0, 30)}...' : entry.content}"');
    for (final conn in _connections) {
      conn.sendMessage(SyncMessage.pushEntry(entry));
    }
  }

  /// Handle socket closed / disconnected
  void _handleConnectionClosed(SyncConnection conn) {
    _connections.remove(conn);
    debugPrint('[SyncService] Connection closed. Remaining connections: ${_connections.length}');

    if (_connections.isEmpty) {
      _setActivePeer(null);
      if (_serverSocket != null) {
        _setStatus(SyncStatus.listening, 'Listening on port ${settings.serverPort}');
      } else {
        _setStatus(SyncStatus.idle, 'Disconnected');
        _scheduleAutoReconnect();
      }
    }
  }

  /// Disconnect all active connections
  void disconnectAll() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    for (final conn in List.of(_connections)) {
      conn.dispose();
    }
    _connections.clear();
    _setActivePeer(null);
    _setStatus(SyncStatus.idle, 'Disconnected');
  }

  /// Automatic reconnect to last paired host if on mobile client
  void _scheduleAutoReconnect() {
    if (!settings.autoSync || settings.isDesktop) return;
    final lastHost = settings.lastPairedHost;
    final lastPort = settings.lastPairedPort;
    if (lastHost == null || lastPort == null) return;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () async {
      if (_connections.isEmpty && _status != SyncStatus.connecting) {
        debugPrint('[SyncService] Attempting auto-reconnect to $lastHost:$lastPort...');
        await connectToPeer(lastHost, lastPort);
      }
    });
  }

  /// Manual "Sync Now" trigger (useful on iOS or on-demand sync)
  Future<void> syncNow({dynamic watcher}) async {
    // 1. Force push the current system clipboard if watcher is provided
    if (watcher != null) {
      try {
        await watcher.pushCurrentClipboard();
      } catch (e) {
        debugPrint('[SyncService] Error in watcher pushCurrentClipboard: $e');
      }
    }

    if (_connections.isEmpty) {
      final lastHost = settings.lastPairedHost;
      final lastPort = settings.lastPairedPort;
      if (lastHost != null && lastPort != null) {
        await connectToPeer(lastHost, lastPort);
      }
      return;
    }

    _setStatus(SyncStatus.syncing, 'Syncing clipboard...');

    // 2. Exchange recent entries with connected peers
    final recentLocal = await db.getEntries(limit: 30);
    for (final conn in _connections) {
      if (recentLocal.isNotEmpty) {
        conn.sendMessage(SyncMessage.syncResponse(recentLocal));
      }
      conn.sendMessage(SyncMessage.syncRequest());
    }

    await Future.delayed(const Duration(milliseconds: 500));
    _setStatus(SyncStatus.connected, 'Connected to ${_activePeer?.name ?? 'Peer'}');
  }

  Future<void> dispose() async {
    _reconnectTimer?.cancel();
    await stopServer();
    await _statusController.close();
    await _activePeerController.close();
    await _entryReceivedController.close();
  }
}
