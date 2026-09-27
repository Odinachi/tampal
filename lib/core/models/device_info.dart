class PeerDevice {
  final String id;
  final String name;
  final String host;
  final int port;
  final String platform;
  final DateTime lastSeen;
  final bool isConnected;
  final bool isPaired;

  const PeerDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.platform = 'unknown',
    required this.lastSeen,
    this.isConnected = false,
    this.isPaired = false,
  });

  PeerDevice copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? platform,
    DateTime? lastSeen,
    bool? isConnected,
    bool? isPaired,
  }) {
    return PeerDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      platform: platform ?? this.platform,
      lastSeen: lastSeen ?? this.lastSeen,
      isConnected: isConnected ?? this.isConnected,
      isPaired: isPaired ?? this.isPaired,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'platform': platform,
    'last_seen': lastSeen.toIso8601String(),
    'is_connected': isConnected,
    'is_paired': isPaired,
  };

  factory PeerDevice.fromJson(Map<String, dynamic> json) => PeerDevice(
    id: json['id'] as String,
    name: json['name'] as String,
    host: json['host'] as String,
    port: json['port'] as int,
    platform: (json['platform'] as String?) ?? 'unknown',
    lastSeen: DateTime.tryParse(json['last_seen'] as String? ?? '') ?? DateTime.now(),
    isConnected: json['is_connected'] as bool? ?? false,
    isPaired: json['is_paired'] as bool? ?? false,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeerDevice && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'PeerDevice(id: $id, name: $name, host: $host, port: $port, connected: $isConnected)';
}
