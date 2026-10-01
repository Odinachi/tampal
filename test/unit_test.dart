import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tampal/core/constants/app_constants.dart';
import 'package:tampal/core/models/clipboard_entry.dart';
import 'package:tampal/core/models/device_info.dart';
import 'package:tampal/core/models/sync_message.dart';

void main() {
  group('ClipboardEntry Model Tests', () {
    test('ClipboardEntry creates, serializes to SQLite map, and restores', () {
      final now = DateTime.utc(2026, 9, 27, 12, 0, 0);
      final entry = ClipboardEntry(
        id: 'test-uuid-1234',
        deviceId: 'device-abc',
        contentType: 'text',
        content: 'Hello World! Tampal test.',
        createdAt: now,
      );

      final map = entry.toMap();
      expect(map['id'], 'test-uuid-1234');
      expect(map['device_id'], 'device-abc');
      expect(map['content_type'], 'text');
      expect(map['content'], 'Hello World! Tampal test.');
      expect(map['created_at'], now.toIso8601String());

      final restored = ClipboardEntry.fromMap(map);
      expect(restored.id, entry.id);
      expect(restored.deviceId, entry.deviceId);
      expect(restored.content, entry.content);
      expect(restored.createdAt, entry.createdAt);
    });

    test('ClipboardEntry matches required socket sync payload JSON format', () {
      final now = DateTime.utc(2026, 9, 27, 14, 30, 0);
      final entry = ClipboardEntry(
        id: 'uuid-5678',
        deviceId: 'uuid-device-99',
        contentType: 'text',
        content: 'https://flutter.dev',
        createdAt: now,
      );

      final syncJson = entry.toSyncJson();
      expect(syncJson['id'], 'uuid-5678');
      expect(syncJson['device_id'], 'uuid-device-99');
      expect(syncJson['content_type'], 'text');
      expect(syncJson['content'], 'https://flutter.dev');
      expect(syncJson['timestamp'], now.toIso8601String());

      final parsed = ClipboardEntry.fromSyncJson(syncJson);
      expect(parsed.id, entry.id);
      expect(parsed.content, entry.content);
      expect(parsed.deviceId, entry.deviceId);
      expect(parsed.createdAt, entry.createdAt);
    });
  });

  group('SyncMessage Protocol Tests', () {
    test('Handshake message correctly serializes and deserializes', () {
      final handshake = HandshakePayload(
        deviceId: 'dev-1',
        deviceName: 'MacBook Pro',
        platform: 'macos',
        latestTimestamp: DateTime.utc(2026, 9, 27, 10, 0, 0),
      );

      final msg = SyncMessage.handshake(handshake);
      final encoded = msg.encode();
      final decodedMap = jsonDecode(encoded) as Map<String, dynamic>;
      final restored = SyncMessage.fromJson(decodedMap);

      expect(restored.type, SyncMessageType.handshake);
      final payload = HandshakePayload.fromJson(restored.data);
      expect(payload.deviceId, 'dev-1');
      expect(payload.deviceName, 'MacBook Pro');
      expect(payload.platform, 'macos');
      expect(payload.latestTimestamp, DateTime.utc(2026, 9, 27, 10, 0, 0));
    });

    test('SyncRequest and SyncResponse serialization', () {
      final now = DateTime.utc(2026, 9, 27, 15, 0, 0);
      final req = SyncMessage.syncRequest(since: now);
      expect(req.type, SyncMessageType.syncRequest);
      expect(req.data['since'], now.toIso8601String());

      final entry = ClipboardEntry.create(deviceId: 'dev-1', content: 'Sync Item');
      final resp = SyncMessage.syncResponse([entry]);
      expect(resp.type, SyncMessageType.syncResponse);
      final list = resp.data['entries'] as List;
      expect(list.length, 1);
    });

    test('Raw socket payload directly parses as pushEntry', () {
      final rawMap = {
        'id': 'uuid-123',
        'device_id': 'device-peer',
        'content_type': 'text',
        'content': 'Direct raw payload test',
        'timestamp': DateTime.utc(2026, 9, 27, 16, 0, 0).toIso8601String(),
      };

      final msg = SyncMessage.fromJson(rawMap);
      expect(msg.type, SyncMessageType.pushEntry);
      final entry = ClipboardEntry.fromSyncJson(msg.data);
      expect(entry.content, 'Direct raw payload test');
    });

    test('Batch syncResponse correctly packages and parses multiple entries', () {
      final entry1 = ClipboardEntry.create(deviceId: 'dev-1', content: 'Item 1');
      final entry2 = ClipboardEntry.create(deviceId: 'dev-2', content: 'Item 2');
      final resp = SyncMessage.syncResponse([entry1, entry2]);
      final encoded = resp.encode();
      final decodedMap = jsonDecode(encoded) as Map<String, dynamic>;
      final restored = SyncMessage.fromJson(decodedMap);

      expect(restored.type, SyncMessageType.syncResponse);
      final entriesRaw = restored.data['entries'] as List;
      expect(entriesRaw.length, 2);
      final parsedEntries = entriesRaw
          .map((e) => ClipboardEntry.fromSyncJson(e as Map<String, dynamic>))
          .toList();
      expect(parsedEntries[0].content, 'Item 1');
      expect(parsedEntries[1].content, 'Item 2');
    });
  });

  group('PeerDevice Model Tests', () {
    test('PeerDevice serializes and deserializes correctly', () {
      final peer = PeerDevice(
        id: 'peer-42',
        name: 'Pixel 8',
        host: '192.168.1.150',
        port: 42880,
        platform: 'android',
        lastSeen: DateTime.utc(2026, 9, 27, 12, 0, 0),
        isConnected: true,
      );

      final json = peer.toJson();
      final fromJson = PeerDevice.fromJson(json);
      expect(fromJson.id, peer.id);
      expect(fromJson.name, peer.name);
      expect(fromJson.host, peer.host);
      expect(fromJson.port, peer.port);
      expect(fromJson.platform, peer.platform);
      expect(fromJson.isConnected, true);
    });
  });

  group('Web Dashboard Configuration Tests', () {
    test('Default ports and constants are valid', () {
      expect(AppConstants.defaultPort, 42880);
      expect(AppConstants.defaultWebPort, 42881);
      expect(AppConstants.serviceType, '_tampal._tcp');
    });
  });
}
