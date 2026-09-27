import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../clipboard/clipboard_watcher.dart';
import '../constants/app_constants.dart';
import '../database/clipboard_database.dart';
import '../models/clipboard_entry.dart';
import '../network/sync_service.dart';
import '../services/settings_service.dart';

class WebServer {
  final SettingsService settings;
  final ClipboardDatabase db;
  final SyncService syncService;
  final ClipboardWatcher? watcher;

  HttpServer? _server;
  final List<WebSocket> _wsClients = [];
  StreamSubscription? _syncSubscription;
  StreamSubscription? _watcherSubscription;
  bool _isRunning = false;

  WebServer({
    required this.settings,
    required this.db,
    required this.syncService,
    this.watcher,
  });

  bool get isRunning => _isRunning;
  int get port => settings.webPort;
  int get clientCount => _wsClients.length;

  /// Retrieves the active local network IPv4 address (e.g., 192.168.1.X)
  Future<String?> getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Get the full browser URL for accessing the web portal
  Future<String> getPortalUrl() async {
    final ip = await getLocalIp();
    return 'http://${ip ?? 'localhost'}:$port';
  }

  /// Open the web portal in the default system browser
  Future<void> openBrowser() async {
    final url = await getPortalUrl();
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', url]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [url]);
      }
    } catch (e) {
      debugPrint('[WebServer] Could not launch browser: $e');
    }
  }

  /// Start the embedded HTTP and WebSocket server
  Future<bool> start({int? port}) async {
    if (_isRunning) return true;
    final listenPort = port ?? settings.webPort;

    try {
      _server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        listenPort,
        shared: true,
      );

      _isRunning = true;
      debugPrint('[WebServer] ClipSync Web Portal running at http://0.0.0.0:$listenPort');

      // Listen for incoming HTTP & WebSocket requests
      _server!.listen(_handleRequest, onError: (e) {
        debugPrint('[WebServer] Server error: $e');
      });

      // Listen to new entries from remote sync or local watcher and broadcast to browsers
      _syncSubscription = syncService.entryReceivedStream.listen((entry) {
        broadcastEntry(entry);
      });

      if (watcher != null) {
        _watcherSubscription = watcher!.newEntryStream.listen((entry) {
          broadcastEntry(entry);
        });
      }

      return true;
    } catch (e) {
      debugPrint('[WebServer] Failed to start web server on port $listenPort: $e');
      _isRunning = false;
      return false;
    }
  }

  /// Stop the web server
  Future<void> stop() async {
    _isRunning = false;
    await _syncSubscription?.cancel();
    _syncSubscription = null;
    await _watcherSubscription?.cancel();
    _watcherSubscription = null;

    for (final ws in List.of(_wsClients)) {
      try {
        await ws.close();
      } catch (_) {}
    }
    _wsClients.clear();

    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
    }
    debugPrint('[WebServer] Web server stopped');
  }

  /// Broadcast a new clipboard entry to all connected browser WebSocket clients
  void broadcastEntry(ClipboardEntry entry) {
    if (_wsClients.isEmpty) return;

    final payload = jsonEncode({
      'type': 'new_entry',
      'entry': entry.toSyncJson(),
    });

    for (final ws in List.of(_wsClients)) {
      try {
        ws.add(payload);
      } catch (e) {
        _wsClients.remove(ws);
      }
    }
  }

  /// Handle incoming HTTP and WebSocket requests
  Future<void> _handleRequest(HttpRequest request) async {
    // CORS headers
    request.response.headers.set('Access-Control-Allow-Origin', '*');
    request.response.headers.set('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
    request.response.headers.set('Access-Control-Allow-Headers', 'Content-Type');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    final path = request.uri.path;

    // 1. WebSocket endpoint (/ws)
    if (path == '/ws') {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        try {
          final socket = await WebSocketTransformer.upgrade(request);
          _wsClients.add(socket);
          debugPrint('[WebServer] WebSocket client connected. Active: ${_wsClients.length}');

          // Send current entries as initial state
          final initialEntries = await db.getEntries(limit: 50);
          socket.add(jsonEncode({
            'type': 'init',
            'entries': initialEntries.map((e) => e.toSyncJson()).toList(),
            'server_name': settings.deviceName,
            'client_count': _wsClients.length,
          }));

          socket.listen(
            (data) {
              _handleWsMessage(socket, data);
            },
            onDone: () {
              _wsClients.remove(socket);
              debugPrint('[WebServer] WebSocket client disconnected. Remaining: ${_wsClients.length}');
            },
            onError: (err) {
              _wsClients.remove(socket);
            },
          );
        } catch (e) {
          debugPrint('[WebServer] WebSocket upgrade error: $e');
        }
      }
      return;
    }

    // 2. REST API: GET /api/entries
    if (path == '/api/entries' && request.method == 'GET') {
      final query = request.uri.queryParameters['q'];
      final entries = await db.getEntries(limit: 50, searchQuery: query);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(entries.map((e) => e.toSyncJson()).toList()));
      await request.response.close();
      return;
    }

    // 3. REST API: POST /api/send (push text from webpage to devices)
    if (path == '/api/send' && request.method == 'POST') {
      try {
        final bodyStr = await utf8.decodeStream(request);
        final body = jsonDecode(bodyStr) as Map<String, dynamic>;
        final content = (body['content'] as String?)?.trim() ?? '';

        if (content.isNotEmpty) {
          final entry = ClipboardEntry.create(
            deviceId: 'web-client',
            content: content,
          );

          // Save locally
          await db.insertEntry(
            entry,
            maxEntries: settings.retentionLimit,
            maxDays: settings.retentionDays,
          );

          // Update desktop system clipboard
          try {
            await Clipboard.setData(ClipboardData(text: content));
          } catch (_) {}

          // Push to mobile and other connected desktop peers
          await syncService.pushLocalEntry(entry);

          // Broadcast to other open browser tabs
          broadcastEntry(entry);

          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'status': 'ok', 'entry': entry.toSyncJson()}));
        } else {
          request.response.statusCode = HttpStatus.badRequest;
          request.response.write(jsonEncode({'error': 'Content cannot be empty'}));
        }
      } catch (e) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write(jsonEncode({'error': e.toString()}));
      }
      await request.response.close();
      return;
    }

    // 4. REST API: DELETE /api/entries/:id
    if (path.startsWith('/api/entries/') && request.method == 'DELETE') {
      final id = path.replaceFirst('/api/entries/', '');
      await db.deleteEntry(id);
      
      // Broadcast deletion event to browsers
      for (final ws in List.of(_wsClients)) {
        try {
          ws.add(jsonEncode({'type': 'delete_entry', 'id': id}));
        } catch (_) {}
      }

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'status': 'deleted', 'id': id}));
      await request.response.close();
      return;
    }

    // 5. REST API: GET /api/status
    if (path == '/api/status') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'app_name': AppConstants.appName,
        'device_name': settings.deviceName,
        'device_id': settings.deviceId,
        'platform': settings.platformName,
        'port': settings.serverPort,
        'web_port': settings.webPort,
        'active_peer': syncService.activePeer?.toJson(),
        'connected_peers': syncService.connections.length,
        'ws_clients': _wsClients.length,
      }));
      await request.response.close();
      return;
    }

    // 6. Web Dashboard UI: GET / or /index.html or /portal.html
    if (path == '/' || path == '/index.html' || path == '/portal.html') {
      request.response.headers.contentType = ContentType('text', 'html', charset: 'utf-8');
      request.response.write(_buildDashboardHtml());
      await request.response.close();
      return;
    }

    // 7. Static assets from web/ directory (e.g. /favicon.png, /manifest.json, /icons/...)
    final webDir = Directory('web');
    if (webDir.existsSync()) {
      final sanitizedPath = path.startsWith('/') ? path.substring(1) : path;
      final file = File('web/$sanitizedPath');
      if (file.existsSync()) {
        final ext = sanitizedPath.split('.').last.toLowerCase();
        if (ext == 'png') {
          request.response.headers.contentType = ContentType('image', 'png');
        } else if (ext == 'json') {
          request.response.headers.contentType = ContentType.json;
        } else if (ext == 'html') {
          request.response.headers.contentType = ContentType.html;
        } else if (ext == 'js') {
          request.response.headers.contentType = ContentType('application', 'javascript');
        } else if (ext == 'css') {
          request.response.headers.contentType = ContentType('text', 'css');
        }
        await file.openRead().pipe(request.response);
        return;
      }
    }

    // 404 Fallback
    request.response.statusCode = HttpStatus.notFound;
    request.response.write('Not Found');
    await request.response.close();
  }

  void _handleWsMessage(WebSocket socket, dynamic data) {
    try {
      final json = jsonDecode(data as String) as Map<String, dynamic>;
      final type = json['type'] as String?;

      if (type == 'ping') {
        socket.add(jsonEncode({'type': 'pong'}));
      }
    } catch (_) {}
  }

  /// Generates the modern, dark-mode, glassmorphic Single Page Application HTML/CSS/JS
  String _buildDashboardHtml() {
    return '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ClipSync Web Portal</title>
  <meta name="description" content="Real-time Wi-Fi clipboard synchronization dashboard for ClipSync.">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg-dark: #0B0F19;
      --card-bg: #151C2C;
      --card-hover: #1A2337;
      --border-color: rgba(255, 255, 255, 0.08);
      --border-active: rgba(99, 102, 241, 0.4);
      --primary: #6366F1;
      --primary-hover: #4F46E5;
      --accent: #06B6D4;
      --success: #10B981;
      --error: #EF4444;
      --text-main: #F1F5F9;
      --text-muted: #94A3B8;
      --text-sub: #64748B;
    }

    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
    }

    body {
      background-color: var(--bg-dark);
      color: var(--text-main);
      font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      overflow-x: hidden;
    }

    /* Ambient background gradient glow */
    body::before {
      content: '';
      position: fixed;
      top: -150px;
      left: 50%;
      transform: translateX(-50%);
      width: 700px;
      height: 400px;
      background: radial-gradient(circle, rgba(99, 102, 241, 0.12) 0%, rgba(6, 182, 212, 0.05) 50%, transparent 70%);
      pointer-events: none;
      z-index: 0;
    }

    header {
      position: sticky;
      top: 0;
      z-index: 50;
      backdrop-filter: blur(16px);
      -webkit-backdrop-filter: blur(16px);
      background: rgba(11, 15, 25, 0.85);
      border-bottom: 1px solid var(--border-color);
      padding: 14px 24px;
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .brand {
      display: flex;
      align-items: center;
      gap: 12px;
    }

    .brand-icon {
      width: 36px;
      height: 36px;
      background: linear-gradient(135deg, var(--primary), var(--accent));
      border-radius: 10px;
      display: flex;
      align-items: center;
      justify-content: center;
      box-shadow: 0 4px 12px rgba(99, 102, 241, 0.3);
    }

    .brand-icon svg {
      width: 20px;
      height: 20px;
      fill: #ffffff;
    }

    .brand-text h1 {
      font-size: 1.15rem;
      font-weight: 700;
      letter-spacing: -0.02em;
      background: linear-gradient(to right, #FFFFFF, #CBD5E1);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
    }

    .brand-text span {
      font-size: 0.75rem;
      color: var(--text-sub);
    }

    .header-actions {
      display: flex;
      align-items: center;
      gap: 12px;
    }

    .pill-badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 5px 12px;
      border-radius: 20px;
      font-size: 0.78rem;
      font-weight: 600;
      border: 1px solid var(--border-color);
      background: rgba(255, 255, 255, 0.03);
    }

    .pill-badge.connected {
      color: var(--success);
      border-color: rgba(16, 185, 129, 0.3);
      background: rgba(16, 185, 129, 0.1);
    }

    .pill-badge.disconnected {
      color: var(--error);
      border-color: rgba(239, 68, 68, 0.3);
      background: rgba(239, 68, 68, 0.1);
    }

    .dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: currentColor;
      box-shadow: 0 0 8px currentColor;
    }

    main {
      flex: 1;
      max-width: 960px;
      width: 100%;
      margin: 0 auto;
      padding: 24px 20px 60px;
      position: relative;
      z-index: 10;
    }

    /* Send Box Section */
    .composer-card {
      background: var(--card-bg);
      border: 1px solid var(--border-color);
      border-radius: 16px;
      padding: 16px;
      margin-bottom: 24px;
      box-shadow: 0 10px 30px rgba(0, 0, 0, 0.25);
      transition: border-color 0.2s, box-shadow 0.2s;
    }

    .composer-card:focus-within {
      border-color: var(--primary);
      box-shadow: 0 10px 30px rgba(99, 102, 241, 0.15);
    }

    .composer-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 10px;
    }

    .composer-title {
      font-size: 0.85rem;
      font-weight: 600;
      color: var(--text-muted);
      display: flex;
      align-items: center;
      gap: 6px;
    }

    .composer-title svg {
      width: 16px;
      height: 16px;
      fill: var(--primary);
    }

    .composer-card textarea {
      width: 100%;
      background: rgba(11, 15, 25, 0.6);
      border: 1px solid var(--border-color);
      border-radius: 10px;
      padding: 12px 14px;
      color: var(--text-main);
      font-family: inherit;
      font-size: 0.95rem;
      resize: vertical;
      min-height: 80px;
      outline: none;
      transition: border-color 0.2s;
    }

    .composer-card textarea:focus {
      border-color: rgba(99, 102, 241, 0.6);
    }

    .composer-footer {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-top: 12px;
    }

    .shortcut-hint {
      font-size: 0.75rem;
      color: var(--text-sub);
    }

    .btn-send {
      background: linear-gradient(135deg, var(--primary), var(--primary-hover));
      color: white;
      border: none;
      border-radius: 10px;
      padding: 8px 18px;
      font-size: 0.88rem;
      font-weight: 600;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 8px;
      transition: transform 0.15s, box-shadow 0.15s, opacity 0.15s;
    }

    .btn-send:hover {
      transform: translateY(-1px);
      box-shadow: 0 4px 14px rgba(99, 102, 241, 0.4);
    }

    .btn-send:active {
      transform: translateY(0);
    }

    .btn-send svg {
      width: 16px;
      height: 16px;
      fill: currentColor;
    }

    .btn-secondary {
      background: rgba(255, 255, 255, 0.05);
      color: var(--text-main);
      border: 1px solid var(--border-color);
      border-radius: 10px;
      padding: 8px 14px;
      font-size: 0.85rem;
      font-weight: 600;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      transition: background 0.15s, border-color 0.15s;
    }

    .btn-secondary:hover {
      background: rgba(255, 255, 255, 0.1);
      border-color: rgba(255, 255, 255, 0.2);
    }

    .btn-secondary svg {
      width: 14px;
      height: 14px;
      fill: currentColor;
    }

    .composer-actions {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    /* Category Filters */
    .category-filters {
      display: flex;
      gap: 8px;
      margin-bottom: 16px;
      overflow-x: auto;
      padding-bottom: 2px;
    }

    .filter-pill {
      background: var(--card-bg);
      border: 1px solid var(--border-color);
      color: var(--text-muted);
      border-radius: 8px;
      padding: 6px 12px;
      font-size: 0.82rem;
      font-weight: 500;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      transition: all 0.15s ease;
      white-space: nowrap;
    }

    .filter-pill:hover {
      border-color: var(--primary);
      color: var(--text-main);
    }

    .filter-pill.active {
      background: rgba(99, 102, 241, 0.15);
      border-color: var(--primary);
      color: #ffffff;
      font-weight: 700;
    }

    .count-badge {
      background: rgba(0, 0, 0, 0.4);
      padding: 1px 6px;
      border-radius: 10px;
      font-size: 0.72rem;
      font-weight: 700;
      color: var(--text-sub);
    }

    .filter-pill.active .count-badge {
      background: var(--primary);
      color: #ffffff;
    }

    /* Search & Filter Header */
    .controls-bar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 16px;
      gap: 12px;
      flex-wrap: wrap;
    }

    .search-wrapper {
      position: relative;
      flex: 1;
      min-width: 240px;
    }

    .search-wrapper input {
      width: 100%;
      background: var(--card-bg);
      border: 1px solid var(--border-color);
      border-radius: 12px;
      padding: 10px 14px 10px 38px;
      color: var(--text-main);
      font-size: 0.88rem;
      outline: none;
      transition: border-color 0.2s;
    }

    .search-wrapper input:focus {
      border-color: var(--primary);
    }

    .search-icon {
      position: absolute;
      left: 12px;
      top: 50%;
      transform: translateY(-50%);
      width: 16px;
      height: 16px;
      fill: var(--text-sub);
    }

    .stats-count {
      font-size: 0.82rem;
      color: var(--text-sub);
      font-weight: 500;
    }

    /* Clipboard Cards Feed */
    .feed {
      display: flex;
      flex-direction: column;
      gap: 12px;
    }

    .entry-card {
      background: var(--card-bg);
      border: 1px solid var(--border-color);
      border-radius: 14px;
      padding: 16px;
      transition: border-color 0.2s, transform 0.2s, background-color 0.2s;
      position: relative;
      cursor: pointer;
    }

    .entry-card:hover {
      background: var(--card-hover);
      border-color: var(--border-active);
      transform: translateY(-2px);
    }

    .entry-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 10px;
    }

    .entry-meta {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .device-badge {
      font-size: 0.72rem;
      font-weight: 600;
      padding: 2px 8px;
      border-radius: 6px;
      text-transform: uppercase;
      letter-spacing: 0.03em;
    }

    .device-badge.macos, .device-badge.desktop {
      background: rgba(99, 102, 241, 0.15);
      color: #A5B4FC;
    }

    .device-badge.android, .device-badge.mobile {
      background: rgba(6, 182, 212, 0.15);
      color: #67E8F9;
    }

    .device-badge.web-client {
      background: rgba(16, 185, 129, 0.15);
      color: #6EE7B7;
    }

    .type-badge {
      font-size: 0.68rem;
      font-weight: 700;
      padding: 2px 7px;
      border-radius: 6px;
      letter-spacing: 0.04em;
    }

    .type-badge.type-links {
      background: rgba(6, 182, 212, 0.15);
      color: #38BDF8;
      border: 1px solid rgba(6, 182, 212, 0.3);
    }

    .type-badge.type-code {
      background: rgba(245, 158, 11, 0.15);
      color: #FCD34D;
      border: 1px solid rgba(245, 158, 11, 0.3);
    }

    .type-badge.type-text {
      background: rgba(148, 163, 184, 0.12);
      color: #CBD5E1;
      border: 1px solid rgba(148, 163, 184, 0.2);
    }

    .timestamp {
      font-size: 0.75rem;
      color: var(--text-sub);
    }

    .entry-actions {
      display: flex;
      align-items: center;
      gap: 6px;
    }

    .action-btn {
      background: transparent;
      border: none;
      color: var(--text-sub);
      cursor: pointer;
      padding: 6px;
      border-radius: 8px;
      display: flex;
      align-items: center;
      justify-content: center;
      transition: color 0.15s, background-color 0.15s, transform 0.15s;
    }

    .action-btn:hover {
      color: var(--text-main);
      background: rgba(255, 255, 255, 0.06);
    }

    .action-btn.copy-btn:hover {
      color: #38BDF8;
      background: rgba(6, 182, 212, 0.12);
    }

    .action-btn.delete-btn:hover {
      color: var(--error);
      background: rgba(239, 68, 68, 0.1);
    }

    .action-btn svg {
      width: 16px;
      height: 16px;
      fill: currentColor;
    }

    .entry-content {
      font-size: 0.92rem;
      line-height: 1.5;
      color: var(--text-main);
      word-break: break-word;
      white-space: pre-wrap;
      max-height: 160px;
      overflow-y: hidden;
      position: relative;
    }

    .entry-content.monospace {
      font-family: 'JetBrains Mono', monospace;
      font-size: 0.85rem;
      color: #A5F3FC;
      background: rgba(11, 15, 25, 0.4);
      padding: 8px 10px;
      border-radius: 8px;
    }

    .entry-footer {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-top: 10px;
      font-size: 0.75rem;
      color: var(--text-sub);
    }

    .click-hint {
      display: flex;
      align-items: center;
      gap: 4px;
      color: var(--primary);
      opacity: 0;
      transition: opacity 0.2s;
    }

    .entry-card:hover .click-hint {
      opacity: 1;
    }

    /* Empty state */
    .empty-state {
      text-align: center;
      padding: 60px 20px;
      background: var(--card-bg);
      border: 1px dashed var(--border-color);
      border-radius: 16px;
      margin-top: 12px;
    }

    .empty-icon {
      width: 48px;
      height: 48px;
      margin: 0 auto 16px;
      fill: var(--text-sub);
      opacity: 0.6;
    }

    .empty-title {
      font-size: 1.05rem;
      font-weight: 600;
      color: var(--text-main);
      margin-bottom: 6px;
    }

    .empty-subtitle {
      font-size: 0.85rem;
      color: var(--text-muted);
      max-width: 360px;
      margin: 0 auto;
    }

    /* Toast Notification */
    .toast {
      position: fixed;
      bottom: 24px;
      right: 24px;
      background: #1E293B;
      border: 1px solid rgba(99, 102, 241, 0.4);
      color: white;
      padding: 12px 18px;
      border-radius: 12px;
      font-size: 0.85rem;
      font-weight: 500;
      display: flex;
      align-items: center;
      gap: 8px;
      box-shadow: 0 10px 25px rgba(0, 0, 0, 0.5);
      transform: translateY(100px);
      opacity: 0;
      transition: transform 0.25s cubic-bezier(0.16, 1, 0.3, 1), opacity 0.25s;
      z-index: 100;
    }

    .toast.show {
      transform: translateY(0);
      opacity: 1;
    }

    .toast-icon {
      width: 16px;
      height: 16px;
      fill: var(--success);
    }
  </style>
</head>
<body>

  <!-- Top Header Navigation -->
  <header>
    <div class="brand">
      <div class="brand-icon">
        <svg viewBox="0 0 24 24"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg>
      </div>
      <div class="brand-text">
        <h1 id="app-title">ClipSync Portal</h1>
        <span id="server-meta">Connecting to desktop server...</span>
      </div>
    </div>

    <div class="header-actions">
      <div id="connection-badge" class="pill-badge disconnected">
        <div class="dot"></div>
        <span id="connection-status-text">Disconnected</span>
      </div>
    </div>
  </header>

  <!-- Main App Layout -->
  <main>
    <!-- Push Text Section -->
    <section class="composer-card">
      <div class="composer-header">
        <div class="composer-title">
          <svg viewBox="0 0 24 24"><path d="M2.01 21L23 12 2.01 3 2 10l15 2-15 2z"/></svg>
          Send to All Connected Devices
        </div>
      </div>
      <textarea id="send-input" placeholder="Type or paste text here to immediately push to your Mac & Android phone..." rows="3"></textarea>
      <div class="composer-footer">
        <span class="shortcut-hint">Press <strong>Cmd/Ctrl + Enter</strong> to send</span>
        <div class="composer-actions">
          <button id="paste-btn" class="btn-secondary" onclick="pasteFromClipboard()">
            <svg viewBox="0 0 24 24"><path d="M19 2h-4.18C14.4.84 13.3 0 12 0c-1.3 0-2.4.84-2.82 2H5c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-7 0c.55 0 1 .45 1 1s-.45 1-1 1-1-.45-1-1 .45-1 1-1zm7 18H5V4h2v3h10V4h2v16z"/></svg>
            Paste
          </button>
          <button id="send-btn" class="btn-send">
            <svg viewBox="0 0 24 24"><path d="M2.01 21L23 12 2.01 3 2 10l15 2-15 2z"/></svg>
            Send to Devices
          </button>
        </div>
      </div>
    </section>

    <!-- Category Filter Bar -->
    <div class="category-filters">
      <button class="filter-pill active" data-filter="all" onclick="setCategoryFilter('all')">
        All <span id="count-all" class="count-badge">0</span>
      </button>
      <button class="filter-pill" data-filter="links" onclick="setCategoryFilter('links')">
        🔗 Links <span id="count-links" class="count-badge">0</span>
      </button>
      <button class="filter-pill" data-filter="code" onclick="setCategoryFilter('code')">
        💻 Code <span id="count-code" class="count-badge">0</span>
      </button>
      <button class="filter-pill" data-filter="text" onclick="setCategoryFilter('text')">
        📝 Notes <span id="count-text" class="count-badge">0</span>
      </button>
    </div>

    <!-- Controls Bar -->
    <div class="controls-bar">
      <div class="search-wrapper">
        <svg class="search-icon" viewBox="0 0 24 24"><path d="M15.5 14h-.79l-.28-.27A6.471 6.471 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z"/></svg>
        <input type="text" id="search-input" placeholder="Search clipboard entries..." autocomplete="off">
      </div>
      <div id="stats-counter" class="stats-count">Loading history...</div>
    </div>

    <!-- Live Clipboard Entries Feed -->
    <section id="entries-feed" class="feed">
      <!-- Cards rendered dynamically via JS -->
    </section>

    <!-- Empty State View -->
    <div id="empty-state" class="empty-state" style="display: none;">
      <svg class="empty-icon" viewBox="0 0 24 24"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-5 14H7v-2h7v2zm3-4H7v-2h10v2zm0-4H7V7h10v2z"/></svg>
      <div class="empty-title">No clipboard items found</div>
      <div class="empty-subtitle">Copy text on your Mac or Android phone, or use the send box above to get started.</div>
    </div>
  </main>

  <!-- Toast Notification -->
  <div id="toast" class="toast">
    <svg class="toast-icon" viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
    <span id="toast-text">Copied to clipboard!</span>
  </div>

  <script>
    let entries = [];
    let currentFilter = 'all';
    let ws = null;
    let reconnectInterval = 2500;

    const feedEl = document.getElementById('entries-feed');
    const emptyStateEl = document.getElementById('empty-state');
    const searchInput = document.getElementById('search-input');
    const sendInput = document.getElementById('send-input');
    const sendBtn = document.getElementById('send-btn');
    const badgeEl = document.getElementById('connection-badge');
    const statusTextEl = document.getElementById('connection-status-text');
    const statsCounter = document.getElementById('stats-counter');
    const serverMeta = document.getElementById('server-meta');
    const toast = document.getElementById('toast');
    const toastText = document.getElementById('toast-text');

    function showToast(message) {
      toastText.textContent = message;
      toast.classList.add('show');
      setTimeout(() => {
        toast.classList.remove('show');
      }, 2000);
    }

    function getItemType(content) {
      if (!content) return 'text';
      const c = content.trim();
      if (c.startsWith('http://') || c.startsWith('https://')) return 'links';
      if ((c.includes('{') && c.includes('}')) || (c.includes('[') && c.includes(']')) ||
          c.includes('function') || c.includes('class ') || c.includes('const ') ||
          c.includes('let ') || c.includes('import ') || c.includes('void ') ||
          c.includes('def ') || c.includes('SELECT ') || c.includes('<html') ||
          c.includes('=>') || c.includes(';')) {
        return 'code';
      }
      return 'text';
    }

    function setCategoryFilter(filter) {
      currentFilter = filter;
      document.querySelectorAll('.filter-pill').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.filter === filter);
      });
      renderEntries();
    }

    async function pasteFromClipboard() {
      try {
        const text = await navigator.clipboard.readText();
        if (text) {
          sendInput.value = text;
          sendInput.focus();
          showToast('Pasted from clipboard!');
        }
      } catch (err) {
        showToast('Clipboard read access not granted');
      }
    }

    function formatTime(isoString) {
      try {
        const dt = new Date(isoString);
        const diffMs = Date.now() - dt.getTime();
        const diffSec = Math.floor(diffMs / 1000);
        const diffMin = Math.floor(diffSec / 60);
        const diffHrs = Math.floor(diffMin / 60);

        if (diffSec < 30) return 'Just now';
        if (diffSec < 60) return diffSec + 's ago';
        if (diffMin < 60) return diffMin + 'm ago';
        if (diffHrs < 24) return diffHrs + 'h ago';
        return dt.toLocaleDateString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
      } catch (_) {
        return 'Recently';
      }
    }

    function renderEntries() {
      const q = searchInput.value.toLowerCase().trim();

      // Update badge counts across all entries
      const allCount = entries.length;
      const linksCount = entries.filter(e => getItemType(e.content) === 'links').length;
      const codeCount = entries.filter(e => getItemType(e.content) === 'code').length;
      const textCount = entries.filter(e => getItemType(e.content) === 'text').length;

      const countAllEl = document.getElementById('count-all');
      const countLinksEl = document.getElementById('count-links');
      const countCodeEl = document.getElementById('count-code');
      const countTextEl = document.getElementById('count-text');

      if (countAllEl) countAllEl.textContent = allCount;
      if (countLinksEl) countLinksEl.textContent = linksCount;
      if (countCodeEl) countCodeEl.textContent = codeCount;
      if (countTextEl) countTextEl.textContent = textCount;

      let filtered = entries;
      if (currentFilter !== 'all') {
        filtered = filtered.filter(e => getItemType(e.content) === currentFilter);
      }
      if (q) {
        filtered = filtered.filter(e => e.content && e.content.toLowerCase().includes(q));
      }

      statsCounter.textContent = filtered.length + ' item' + (filtered.length === 1 ? '' : 's');

      if (filtered.length === 0) {
        feedEl.innerHTML = '';
        emptyStateEl.style.display = 'block';
        return;
      }

      emptyStateEl.style.display = 'none';

      feedEl.innerHTML = filtered.map(item => {
        const itemType = getItemType(item.content);
        const isUrl = itemType === 'links';
        const isCode = itemType === 'code';
        const typeBadge = isUrl ? '🔗 LINK' : (isCode ? '💻 CODE' : '📝 TEXT');
        const badgeClass = item.device_id.includes('web') ? 'web-client' : (item.device_id.includes('android') ? 'android' : 'macos');
        const badgeLabel = item.device_id.includes('web') ? 'Web Portal' : (item.device_id.includes('android') ? 'Android' : 'Desktop');

        return `
          <article class="entry-card" data-id="\${item.id}" onclick="copyEntryById('\${item.id}')">
            <div class="entry-header">
              <div class="entry-meta">
                <span class="device-badge \${badgeClass}">\${badgeLabel}</span>
                <span class="type-badge type-\${itemType}">\${typeBadge}</span>
                <span class="timestamp">\${formatTime(item.timestamp || item.created_at)}</span>
              </div>
              <div class="entry-actions">
                <button class="action-btn copy-btn" title="Copy to clipboard" onclick="copyEntryBtn(event, '\${item.id}')">
                  <svg viewBox="0 0 24 24"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg>
                </button>
                <button class="action-btn delete-btn" title="Delete entry" onclick="deleteEntry(event, '\${item.id}')">
                  <svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
                </button>
              </div>
            </div>
            <div class="entry-content \${isUrl || isCode ? 'monospace' : ''}">\${escapeHtml(item.content)}</div>
            <div class="entry-footer">
              <span>\${item.content ? item.content.length : 0} characters</span>
              <span class="click-hint">Click card to copy</span>
            </div>
          </article>
        `;
      }).join('');
    }

    function escapeHtml(text) {
      if (!text) return '';
      return text
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#039;");
    }

    async function copyEntryById(id) {
      const item = entries.find(e => e.id === id);
      if (item && item.content) {
        await copyText(item.content);
      }
    }

    async function copyEntryBtn(event, id) {
      event.stopPropagation();
      await copyEntryById(id);
    }

    async function copyText(text) {
      try {
        await navigator.clipboard.writeText(text);
        showToast('Copied to clipboard!');
      } catch (err) {
        showToast('Failed to copy: ' + err);
      }
    }

    async function deleteEntry(event, id) {
      event.stopPropagation();
      try {
        await fetch('/api/entries/' + id, { method: 'DELETE' });
        entries = entries.filter(e => e.id !== id);
        renderEntries();
        showToast('Entry deleted');
      } catch (e) {
        showToast('Error deleting entry');
      }
    }

    async function sendText() {
      const text = sendInput.value.trim();
      if (!text) return;

      sendBtn.disabled = true;
      try {
        const res = await fetch('/api/send', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ content: text }),
        });

        if (res.ok) {
          sendInput.value = '';
          showToast('Sent to all connected devices!');
        } else {
          showToast('Failed to send text');
        }
      } catch (e) {
        showToast('Error sending text: ' + e);
      } finally {
        sendBtn.disabled = false;
      }
    }

    function connectWebSocket() {
      const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      const url = proto + '//' + window.location.host + '/ws';

      ws = new WebSocket(url);

      ws.onopen = () => {
        badgeEl.className = 'pill-badge connected';
        statusTextEl.textContent = 'Live Synced';
      };

      ws.onmessage = (event) => {
        try {
          const msg = JSON.parse(event.data);
          if (msg.type === 'init') {
            entries = msg.entries || [];
            if (msg.server_name) {
              serverMeta.textContent = 'Hosted by ' + msg.server_name + ' • Port ' + window.location.port;
            }
            renderEntries();
          } else if (msg.type === 'new_entry') {
            const entry = msg.entry;
            // Prevent duplicate entries by ID
            if (!entries.some(e => e.id === entry.id)) {
              entries.unshift(entry);
              renderEntries();
              showToast('New clipboard item received!');
            }
          } else if (msg.type === 'delete_entry') {
            entries = entries.filter(e => e.id !== msg.id);
            renderEntries();
          }
        } catch (e) {
          console.error('[ClipSync Web] Error parsing message:', e);
        }
      };

      ws.onclose = () => {
        badgeEl.className = 'pill-badge disconnected';
        statusTextEl.textContent = 'Reconnecting...';
        setTimeout(connectWebSocket, reconnectInterval);
      };

      ws.onerror = () => {
        ws.close();
      };
    }

    async function loadEntriesFromRest() {
      try {
        const res = await fetch('/api/entries');
        if (res.ok) {
          const data = await res.json();
          if (Array.isArray(data)) {
            entries = data;
            renderEntries();
          }
        }
      } catch (e) {
        console.warn('Initial REST load error:', e);
      }
    }

    // Keyboard Shortcuts
    sendInput.addEventListener('keydown', (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
        e.preventDefault();
        sendText();
      }
    });

    sendBtn.addEventListener('click', sendText);
    searchInput.addEventListener('input', renderEntries);

    // Initial load: fetch immediately via REST and establish live WebSocket sync
    loadEntriesFromRest();
    connectWebSocket();
  </script>
</body>
</html>
''';
  }
}
