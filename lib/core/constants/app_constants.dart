class AppConstants {
  static const String appName = 'Tampal';
  static const String serviceType = '_tampal._tcp';
  static const int defaultPort = 42880;
  static const int defaultWebPort = 42881;
  static const String databaseName = 'tampal.db';
  static const int defaultRetentionLimit = 100;
  static const int defaultRetentionDays = 7;
  
  // Storage keys
  static const String prefDeviceId = 'tampal_device_id';
  static const String prefDeviceName = 'tampal_device_name';
  static const String prefRetentionLimit = 'tampal_retention_limit';
  static const String prefRetentionDays = 'tampal_retention_days';
  static const String prefAutoSync = 'tampal_auto_sync';
  static const String prefServerPort = 'tampal_server_port';
  static const String prefWebPort = 'tampal_web_port';
  static const String prefWebEnabled = 'tampal_web_enabled';
  static const String prefLastPairedHost = 'tampal_last_paired_host';
  static const String prefLastPairedPort = 'tampal_last_paired_port';
}
