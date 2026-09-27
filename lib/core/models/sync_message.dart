import 'dart:convert';
import 'clipboard_entry.dart';

/// Message types for the sync protocol
enum SyncMessageType {
  handshake,      // Sent immediately upon connection: { device_id, device_name, latest_timestamp }
  syncRequest,    // Request entries newer than timestamp: { since: "timestamp" }
  syncResponse,   // Response list of entries: { entries: [...] }
  pushEntry,      // Single clipboard push: { entry: {...} } or raw entry format
  ping,           // Keepalive ping
  pong,           // Keepalive pong
}

class HandshakePayload {
  final String deviceId;
  final String deviceName;
  final String platform;
  final DateTime? latestTimestamp;

  HandshakePayload({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    this.latestTimestamp,
  });

  Map<String, dynamic> toJson() => {
    'device_id': deviceId,
    'device_name': deviceName,
    'platform': platform,
    'latest_timestamp': latestTimestamp?.toIso8601String(),
  };

  factory HandshakePayload.fromJson(Map<String, dynamic> json) => HandshakePayload(
    deviceId: json['device_id'] as String,
    deviceName: (json['device_name'] as String?) ?? 'Unknown Device',
    platform: (json['platform'] as String?) ?? 'unknown',
    latestTimestamp: json['latest_timestamp'] != null
        ? DateTime.tryParse(json['latest_timestamp'] as String)
        : null,
  );
}

class SyncMessage {
  final SyncMessageType type;
  final Map<String, dynamic> data;

  SyncMessage({
    required this.type,
    required this.data,
  });

  /// Create handshake message
  factory SyncMessage.handshake(HandshakePayload handshake) {
    return SyncMessage(
      type: SyncMessageType.handshake,
      data: handshake.toJson(),
    );
  }

  /// Create sync request message asking for missing entries since a given timestamp
  factory SyncMessage.syncRequest({DateTime? since}) {
    return SyncMessage(
      type: SyncMessageType.syncRequest,
      data: {
        'since': since?.toIso8601String(),
      },
    );
  }

  /// Create sync response message with missing entries
  factory SyncMessage.syncResponse(List<ClipboardEntry> entries) {
    return SyncMessage(
      type: SyncMessageType.syncResponse,
      data: {
        'entries': entries.map((e) => e.toSyncJson()).toList(),
      },
    );
  }

  /// Create push message for a single new entry
  factory SyncMessage.pushEntry(ClipboardEntry entry) {
    return SyncMessage(
      type: SyncMessageType.pushEntry,
      data: entry.toSyncJson(),
    );
  }

  /// Serialize message to JSON map
  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'data': data,
    };
  }

  /// Encode to JSON string
  String encode() => jsonEncode(toJson());

  /// Decode incoming JSON map.
  /// Handles both protocol wrapper:
  /// {"type": "pushEntry", "data": {...}}
  /// and direct raw sync payload as specified:
  /// {"id": "uuid", "device_id": "uuid", "content_type": "text", "content": "...", "timestamp": "ISO8601"}
  factory SyncMessage.fromJson(Map<String, dynamic> map) {
    // If raw entry payload directly received
    if (map.containsKey('id') && map.containsKey('content') && map.containsKey('device_id')) {
      return SyncMessage(
        type: SyncMessageType.pushEntry,
        data: map,
      );
    }

    final typeStr = map['type'] as String? ?? '';
    final data = (map['data'] as Map<String, dynamic>?) ?? map;

    switch (typeStr) {
      case 'handshake':
        return SyncMessage(type: SyncMessageType.handshake, data: data);
      case 'syncRequest':
      case 'sync_request':
        return SyncMessage(type: SyncMessageType.syncRequest, data: data);
      case 'syncResponse':
      case 'sync_response':
        return SyncMessage(type: SyncMessageType.syncResponse, data: data);
      case 'pushEntry':
      case 'push_entry':
        return SyncMessage(type: SyncMessageType.pushEntry, data: data);
      case 'ping':
        return SyncMessage(type: SyncMessageType.ping, data: data);
      case 'pong':
        return SyncMessage(type: SyncMessageType.pong, data: data);
      default:
        return SyncMessage(type: SyncMessageType.pushEntry, data: data);
    }
  }
}
