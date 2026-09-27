import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/clipboard_entry.dart';
import '../models/device_info.dart';
import '../models/sync_message.dart';
import 'socket_framing.dart';

typedef OnMessageReceived = void Function(SyncConnection connection, SyncMessage message);
typedef OnConnectionClosed = void Function(SyncConnection connection);

class SyncConnection {
  final Socket socket;
  final bool isIncoming;
  PeerDevice? peerDevice;

  final OnMessageReceived onMessage;
  final OnConnectionClosed onClosed;

  StreamSubscription<String>? _subscription;
  Timer? _pingTimer;
  bool _isDisposed = false;

  SyncConnection({
    required this.socket,
    required this.isIncoming,
    required this.onMessage,
    required this.onClosed,
    this.peerDevice,
  }) {
    _init();
  }

  void _init() {
    _subscription = SocketMessageFramer.frameStream(socket).listen(
      (line) {
        _handleRawLine(line);
      },
      onError: (error) {
        debugPrint('[SyncConnection] Socket error: $error');
        dispose();
      },
      onDone: () {
        debugPrint('[SyncConnection] Socket closed by remote host');
        dispose();
      },
      cancelOnError: true,
    );

    // Keepalive ping every 30 seconds
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      sendMessage(SyncMessage(type: SyncMessageType.ping, data: {}));
    });
  }

  void _handleRawLine(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) {
        final message = SyncMessage.fromJson(decoded);
        if (message.type == SyncMessageType.ping) {
          sendMessage(SyncMessage(type: SyncMessageType.pong, data: {}));
          return;
        } else if (message.type == SyncMessageType.pong) {
          return;
        }
        onMessage(this, message);
      }
    } catch (e) {
      debugPrint('[SyncConnection] Error decoding line: $e -> $line');
    }
  }

  /// Send a structured [SyncMessage] over the socket
  void sendMessage(SyncMessage message) {
    if (_isDisposed) return;
    try {
      final jsonStr = jsonEncode(message.toJson());
      SocketMessageFramer.sendMessage(socket, jsonStr);
    } catch (e) {
      debugPrint('[SyncConnection] Error sending message: $e');
      dispose();
    }
  }

  /// Send a clipboard payload directly matching the specified format:
  /// {
  ///   "id": "uuid",
  ///   "device_id": "uuid",
  ///   "content_type": "text",
  ///   "content": "...",
  ///   "timestamp": "ISO8601"
  /// }
  void sendEntryPayload(ClipboardEntry entry) {
    if (_isDisposed) return;
    try {
      final jsonStr = jsonEncode(entry.toSyncJson());
      SocketMessageFramer.sendMessage(socket, jsonStr);
    } catch (e) {
      debugPrint('[SyncConnection] Error sending entry: $e');
      dispose();
    }
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _pingTimer?.cancel();
    _subscription?.cancel();
    try {
      socket.destroy();
    } catch (_) {}
    onClosed(this);
  }

  String get remoteAddress => socket.remoteAddress.address;
  int get remotePort => socket.remotePort;
}
