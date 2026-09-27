class AppConstants {
  static const String appName = 'ClipSync';
  static const String serviceType = '_clipsync._tcp';
  static const int defaultPort = 42880;
  static const int defaultWebPort = 42881;
  static const String databaseName = 'clipsync.db';
  static const int defaultRetentionLimit = 100;
  static const int defaultRetentionDays = 7;
  
  // Storage keys
  static const String prefDeviceId = 'clipsync_device_id';
  static const String prefDeviceName = 'clipsync_device_name';
  static const String prefRetentionLimit = 'clipsync_retention_limit';
  static const String prefRetentionDays = 'clipsync_retention_days';
  static const String prefAutoSync = 'clipsync_auto_sync';
  static const String prefServerPort = 'clipsync_server_port';
  static const String prefWebPort = 'clipsync_web_port';
  static const String prefWebEnabled = 'clipsync_web_enabled';
  static const String prefLastPairedHost = 'clipsync_last_paired_host';
  static const String prefLastPairedPort = 'clipsync_last_paired_port';
}
