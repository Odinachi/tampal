import 'package:uuid/uuid.dart';

class ClipboardEntry {
  final String id;
  final String deviceId;
  final String contentType;
  final String content;
  final DateTime createdAt;

  const ClipboardEntry({
    required this.id,
    required this.deviceId,
    this.contentType = 'text',
    required this.content,
    required this.createdAt,
  });

  /// Factory to generate a new entry with an auto-generated UUID and current time
  factory ClipboardEntry.create({
    required String deviceId,
    required String content,
    String contentType = 'text',
    DateTime? createdAt,
  }) {
    return ClipboardEntry(
      id: const Uuid().v4(),
      deviceId: deviceId,
      contentType: contentType,
      content: content,
      createdAt: createdAt ?? DateTime.now().toUtc(),
    );
  }

  /// Convert SQLite row map to [ClipboardEntry]
  factory ClipboardEntry.fromMap(Map<String, dynamic> map) {
    return ClipboardEntry(
      id: map['id'] as String,
      deviceId: map['device_id'] as String,
      contentType: (map['content_type'] as String?) ?? 'text',
      content: map['content'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  /// Convert [ClipboardEntry] to SQLite row map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'device_id': deviceId,
      'content_type': contentType,
      'content': content,
      'created_at': createdAt.toIso8601String(),
    };
  }

  /// Create from JSON sync payload over the socket:
  /// {
  ///   "id": "uuid",
  ///   "device_id": "uuid",
  ///   "content_type": "text",
  ///   "content": "...",
  ///   "timestamp": "ISO8601"
  /// }
  factory ClipboardEntry.fromSyncJson(Map<String, dynamic> json) {
    return ClipboardEntry(
      id: json['id'] as String,
      deviceId: json['device_id'] as String,
      contentType: (json['content_type'] as String?) ?? 'text',
      content: json['content'] as String,
      createdAt: DateTime.parse((json['timestamp'] ?? json['created_at']) as String),
    );
  }

  /// Convert to JSON sync payload matching the required socket message format
  Map<String, dynamic> toSyncJson() {
    return {
      'id': id,
      'device_id': deviceId,
      'content_type': contentType,
      'content': content,
      'timestamp': createdAt.toIso8601String(),
    };
  }

  ClipboardEntry copyWith({
    String? id,
    String? deviceId,
    String? contentType,
    String? content,
    DateTime? createdAt,
  }) {
    return ClipboardEntry(
      id: id ?? this.id,
      deviceId: deviceId ?? this.deviceId,
      contentType: contentType ?? this.contentType,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClipboardEntry &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() {
    return 'ClipboardEntry(id: $id, deviceId: $deviceId, contentType: $contentType, length: ${content.length}, createdAt: $createdAt)';
  }
}
