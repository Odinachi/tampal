import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../constants/app_constants.dart';

class SettingsService {
  final SharedPreferences _prefs;

  SettingsService(this._prefs);

  static Future<SettingsService> init() async {
    final prefs = await SharedPreferences.getInstance();
    final service = SettingsService(prefs);
    await service._ensureDeviceId();
    return service;
  }

  /// Ensure a permanent UUID exists for this device
  Future<void> _ensureDeviceId() async {
    if (_prefs.getString(AppConstants.prefDeviceId) == null) {
      final newId = const Uuid().v4();
      await _prefs.setString(AppConstants.prefDeviceId, newId);
    }
    if (_prefs.getString(AppConstants.prefDeviceName) == null) {
      await _prefs.setString(AppConstants.prefDeviceName, defaultDeviceName);
    }
  }

  String get deviceId => _prefs.getString(AppConstants.prefDeviceId) ?? const Uuid().v4();

  String get deviceName => _prefs.getString(AppConstants.prefDeviceName) ?? defaultDeviceName;

  Future<void> setDeviceName(String name) async {
    await _prefs.setString(AppConstants.prefDeviceName, name.trim());
  }

  int get retentionLimit => _prefs.getInt(AppConstants.prefRetentionLimit) ?? AppConstants.defaultRetentionLimit;

  Future<void> setRetentionLimit(int limit) async {
    await _prefs.setInt(AppConstants.prefRetentionLimit, limit);
  }

  int get retentionDays => _prefs.getInt(AppConstants.prefRetentionDays) ?? AppConstants.defaultRetentionDays;

  Future<void> setRetentionDays(int days) async {
    await _prefs.setInt(AppConstants.prefRetentionDays, days);
  }

  bool get autoSync => _prefs.getBool(AppConstants.prefAutoSync) ?? true;

  Future<void> setAutoSync(bool enabled) async {
    await _prefs.setBool(AppConstants.prefAutoSync, enabled);
  }

  int get serverPort => _prefs.getInt(AppConstants.prefServerPort) ?? AppConstants.defaultPort;

  Future<void> setServerPort(int port) async {
    await _prefs.setInt(AppConstants.prefServerPort, port);
  }

  String? get lastPairedHost => _prefs.getString(AppConstants.prefLastPairedHost);

  int? get lastPairedPort => _prefs.getInt(AppConstants.prefLastPairedPort);

  Future<void> saveLastPairedPeer(String host, int port) async {
    await _prefs.setString(AppConstants.prefLastPairedHost, host);
    await _prefs.setInt(AppConstants.prefLastPairedPort, port);
  }

  String get platformName {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  bool get isDesktop => !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
  bool get isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  String get defaultDeviceName {
    if (kIsWeb) return 'Web Browser';
    if (Platform.isAndroid) return 'Android Device';
    if (Platform.isIOS) return 'iOS Device';
    if (Platform.isMacOS) return 'Mac Desktop';
    if (Platform.isWindows) return 'Windows PC';
    if (Platform.isLinux) return 'Linux Workstation';
    return 'ClipSync Node';
  }
}
