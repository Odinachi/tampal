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
  <title>ClipSync — Local Clipboard Sync</title>
  <meta name="description" content="Local Wi-Fi clipboard synchronization dashboard for ClipSync.">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg: #0C0D11;
      --surface: #14151D;
      --surface-hover: #181A23;
      --surface-active: #1D202B;
      --surface-subtle: #0F1016;
      --border: #1E222E;
      --border-hover: #2B3040;
      --border-focus: #3E455B;
      --text-primary: #EDEDED;
      --text-secondary: #8E93A4;
      --text-tertiary: #525768;
      --accent: #3B82F6;
      --accent-hover: #2563EB;
      --success: #10B981;
      --error: #EF4444;
      --radius: 8px;
    }

    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
    }

    body {
      background-color: var(--bg);
      color: var(--text-primary);
      font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      -webkit-font-smoothing: antialiased;
      -moz-osx-font-smoothing: grayscale;
    }

    /* Top Navigation Header */
    header {
      position: sticky;
      top: 0;
      z-index: 40;
      background: rgba(12, 13, 17, 0.92);
      backdrop-filter: blur(12px);
      -webkit-backdrop-filter: blur(12px);
      border-bottom: 1px solid var(--border);
      padding: 12px 24px;
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .brand {
      display: flex;
      align-items: center;
      gap: 10px;
    }

    .brand-mark {
      width: 28px;
      height: 28px;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 6px;
      display: flex;
      align-items: center;
      justify-content: center;
      color: var(--text-primary);
    }

    .brand-mark svg {
      width: 15px;
      height: 15px;
    }

    .brand-meta {
      display: flex;
      align-items: baseline;
      gap: 8px;
    }

    .brand-name {
      font-size: 0.92rem;
      font-weight: 600;
      color: var(--text-primary);
      letter-spacing: -0.01em;
    }

    .brand-sub {
      font-size: 0.75rem;
      color: var(--text-tertiary);
      font-weight: 400;
    }

    .status-badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 4px 10px;
      border-radius: 20px;
      font-size: 0.75rem;
      font-weight: 500;
      border: 1px solid var(--border);
      background: var(--surface-subtle);
      color: var(--text-secondary);
    }

    .status-dot {
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: var(--text-tertiary);
    }

    .status-badge.connected .status-dot {
      background: var(--success);
      box-shadow: 0 0 6px rgba(16, 185, 129, 0.4);
    }

    .status-badge.connected {
      color: var(--text-primary);
    }

    .status-badge.disconnected .status-dot {
      background: var(--error);
    }

    /* Main Container */
    main {
      flex: 1;
      max-width: 820px;
      width: 100%;
      margin: 0 auto;
      padding: 24px 20px 80px;
    }

    /* Raycast-style Command Composer */
    .composer {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 14px 16px;
      margin-bottom: 24px;
      transition: border-color 0.15s, box-shadow 0.15s;
    }

    .composer:focus-within {
      border-color: var(--border-focus);
      box-shadow: 0 4px 20px rgba(0, 0, 0, 0.35);
    }

    .composer textarea {
      width: 100%;
      background: transparent;
      border: none;
      color: var(--text-primary);
      font-family: inherit;
      font-size: 0.92rem;
      line-height: 1.5;
      resize: vertical;
      min-height: 54px;
      outline: none;
    }

    .composer textarea::placeholder {
      color: var(--text-tertiary);
    }

    .composer-bar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-top: 10px;
      padding-top: 10px;
      border-top: 1px solid rgba(255, 255, 255, 0.04);
    }

    .shortcut-tag {
      font-size: 0.72rem;
      color: var(--text-tertiary);
      display: inline-flex;
      align-items: center;
      gap: 4px;
    }

    kbd {
      background: var(--surface-subtle);
      border: 1px solid var(--border);
      border-radius: 4px;
      padding: 1px 5px;
      font-family: inherit;
      font-size: 0.7rem;
      color: var(--text-secondary);
    }

    .composer-actions {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .btn-subtle {
      background: transparent;
      color: var(--text-secondary);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 5px 10px;
      font-size: 0.78rem;
      font-weight: 500;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 5px;
      transition: color 0.15s, border-color 0.15s, background-color 0.15s;
    }

    .btn-subtle:hover {
      color: var(--text-primary);
      background: var(--surface-hover);
      border-color: var(--border-hover);
    }

    .btn-primary {
      background: #FFFFFF;
      color: #0C0D11;
      border: none;
      border-radius: 6px;
      padding: 5px 14px;
      font-size: 0.78rem;
      font-weight: 600;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      transition: opacity 0.15s, transform 0.1s;
    }

    .btn-primary:hover {
      opacity: 0.92;
    }

    .btn-primary:active {
      transform: scale(0.98);
    }

    .btn-primary:disabled {
      opacity: 0.4;
      cursor: not-allowed;
    }

    /* Toolbar: Segmented Tabs & Search */
    .toolbar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      margin-bottom: 16px;
      flex-wrap: wrap;
    }

    .segmented-control {
      display: inline-flex;
      background: var(--surface-subtle);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 2px;
      gap: 2px;
    }

    .segment-tab {
      background: transparent;
      border: none;
      color: var(--text-secondary);
      border-radius: 6px;
      padding: 5px 12px;
      font-size: 0.8rem;
      font-weight: 500;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      transition: color 0.12s, background-color 0.12s;
    }

    .segment-tab:hover {
      color: var(--text-primary);
    }

    .segment-tab.active {
      background: var(--surface);
      color: var(--text-primary);
      box-shadow: 0 1px 3px rgba(0, 0, 0, 0.3);
    }

    .tab-count {
      font-size: 0.72rem;
      color: var(--text-tertiary);
      font-variant-numeric: tabular-nums;
    }

    .segment-tab.active .tab-count {
      color: var(--text-secondary);
    }

    .search-box {
      position: relative;
      min-width: 200px;
      flex: 1;
      max-width: 280px;
    }

    .search-box input {
      width: 100%;
      background: var(--surface-subtle);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 6px 12px 6px 30px;
      color: var(--text-primary);
      font-size: 0.82rem;
      outline: none;
      transition: border-color 0.15s;
    }

    .search-box input::placeholder {
      color: var(--text-tertiary);
    }

    .search-box input:focus {
      border-color: var(--border-focus);
    }

    .search-box svg {
      position: absolute;
      left: 10px;
      top: 50%;
      transform: translateY(-50%);
      width: 13px;
      height: 13px;
      color: var(--text-tertiary);
    }

    /* Clipboard Feed */
    .feed {
      display: flex;
      flex-direction: column;
      gap: 8px;
    }

    .entry-card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 12px 14px;
      transition: background-color 0.15s, border-color 0.15s, transform 0.12s;
      cursor: pointer;
    }

    .entry-card:hover {
      background: var(--surface-hover);
      border-color: var(--border-hover);
    }

    .entry-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 8px;
    }

    .entry-origin {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .device-tag {
      display: inline-flex;
      align-items: center;
      gap: 4px;
      font-size: 0.72rem;
      font-weight: 500;
      color: var(--text-secondary);
    }

    .device-tag svg {
      width: 12px;
      height: 12px;
      color: var(--text-tertiary);
    }

    .type-tag {
      font-size: 0.68rem;
      font-weight: 500;
      padding: 1px 6px;
      border-radius: 4px;
      border: 1px solid var(--border);
      color: var(--text-secondary);
      background: var(--surface-subtle);
    }

    .entry-time {
      font-size: 0.72rem;
      color: var(--text-tertiary);
    }

    .entry-actions {
      display: flex;
      align-items: center;
      gap: 2px;
    }

    .action-btn {
      background: transparent;
      border: none;
      color: var(--text-tertiary);
      cursor: pointer;
      padding: 4px;
      border-radius: 4px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      transition: color 0.15s, background-color 0.15s;
    }

    .action-btn:hover {
      color: var(--text-primary);
      background: rgba(255, 255, 255, 0.06);
    }

    .action-btn.delete-btn:hover {
      color: var(--error);
      background: rgba(239, 68, 68, 0.1);
    }

    .action-btn svg {
      width: 14px;
      height: 14px;
    }

    .entry-body {
      font-size: 0.88rem;
      line-height: 1.5;
      color: var(--text-primary);
      word-break: break-word;
      white-space: pre-wrap;
      max-height: 140px;
      overflow-y: hidden;
    }

    .entry-body.is-code {
      font-family: 'JetBrains Mono', monospace;
      font-size: 0.8rem;
      background: #090A0D;
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 8px 10px;
      color: #E2E8F0;
    }

    .entry-body.is-url {
      color: #60A5FA;
    }

    .entry-footer {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-top: 8px;
      font-size: 0.72rem;
      color: var(--text-tertiary);
    }

    /* Empty state */
    .empty-state {
      text-align: center;
      padding: 48px 16px;
      border: 1px dashed var(--border);
      border-radius: 8px;
      margin-top: 12px;
    }

    .empty-title {
      font-size: 0.88rem;
      font-weight: 500;
      color: var(--text-secondary);
      margin-bottom: 4px;
    }

    .empty-subtitle {
      font-size: 0.78rem;
      color: var(--text-tertiary);
    }

    /* Raycast-style bottom toast */
    .toast {
      position: fixed;
      bottom: 24px;
      left: 50%;
      transform: translateX(-50%) translateY(20px);
      background: #1C1E26;
      border: 1px solid var(--border-hover);
      color: var(--text-primary);
      padding: 8px 14px;
      border-radius: 20px;
      font-size: 0.8rem;
      font-weight: 500;
      display: flex;
      align-items: center;
      gap: 8px;
      box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
      opacity: 0;
      pointer-events: none;
      transition: transform 0.2s cubic-bezier(0.16, 1, 0.3, 1), opacity 0.2s;
      z-index: 100;
    }

    .toast.show {
      transform: translateX(-50%) translateY(0);
      opacity: 1;
    }

    .toast-icon {
      width: 14px;
      height: 14px;
      color: var(--success);
    }
  </style>
</head>
<body>

  <!-- Top Navigation Header -->
  <header>
    <div class="brand">
      <div class="brand-mark">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"></path>
          <rect x="8" y="2" width="8" height="4" rx="1" ry="1"></rect>
        </svg>
      </div>
      <div class="brand-meta">
        <span class="brand-name">ClipSync</span>
        <span id="server-meta" class="brand-sub">Local Network</span>
      </div>
    </div>

    <div class="header-right">
      <div id="connection-badge" class="status-badge disconnected">
        <span class="status-dot"></span>
        <span id="connection-status-text">Connecting</span>
      </div>
    </div>
  </header>

  <!-- Main Workspace -->
  <main>
    <!-- Command Composer -->
    <section class="composer">
      <textarea id="send-input" placeholder="Type or paste to broadcast across your devices..." rows="2"></textarea>
      <div class="composer-bar">
        <div class="shortcut-tag">
          <kbd>⌘</kbd> <kbd>Enter</kbd> <span>to broadcast</span>
        </div>
        <div class="composer-actions">
          <button id="paste-btn" class="btn-subtle" onclick="pasteFromClipboard()">
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"></path><rect x="8" y="2" width="8" height="4" rx="1" ry="1"></rect></svg>
            Paste
          </button>
          <button id="send-btn" class="btn-primary" onclick="sendText()">
            Broadcast
          </button>
        </div>
      </div>
    </section>

    <!-- Toolbar: Clean Segmented Tabs + Search -->
    <div class="toolbar">
      <div class="segmented-control">
        <button class="segment-tab active" data-filter="all" onclick="setCategoryFilter('all')">
          All <span id="count-all" class="tab-count">0</span>
        </button>
        <button class="segment-tab" data-filter="links" onclick="setCategoryFilter('links')">
          Links <span id="count-links" class="tab-count">0</span>
        </button>
        <button class="segment-tab" data-filter="code" onclick="setCategoryFilter('code')">
          Code <span id="count-code" class="tab-count">0</span>
        </button>
        <button class="segment-tab" data-filter="text" onclick="setCategoryFilter('text')">
          Text <span id="count-text" class="tab-count">0</span>
        </button>
      </div>

      <div class="search-box">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line></svg>
        <input type="text" id="search-input" placeholder="Search..." autocomplete="off">
      </div>
    </div>

    <!-- Clipboard Cards Feed -->
    <section id="entries-feed" class="feed">
      <!-- Injected via JavaScript -->
    </section>

    <!-- Empty State -->
    <div id="empty-state" class="empty-state" style="display: none;">
      <div class="empty-title">No clipboard history</div>
      <div class="empty-subtitle">Copies from your devices or this web app will appear automatically.</div>
    </div>
  </main>

  <!-- Bottom Notification Toast -->
  <div id="toast" class="toast">
    <svg class="toast-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polyline points="20 6 9 17 4 12"></polyline></svg>
    <span id="toast-text">Copied</span>
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
    const serverMeta = document.getElementById('server-meta');
    const toast = document.getElementById('toast');
    const toastText = document.getElementById('toast-text');

    function showToast(message) {
      toastText.textContent = message;
      toast.classList.add('show');
      setTimeout(() => {
        toast.classList.remove('show');
      }, 1800);
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
      document.querySelectorAll('.segment-tab').forEach(btn => {
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
          showToast('Pasted');
        }
      } catch (err) {
        showToast('Clipboard access denied');
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
        return dt.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
      } catch (_) {
        return 'Recently';
      }
    }

    function renderEntries() {
      const q = searchInput.value.toLowerCase().trim();

      // Counts for tabs
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
        const typeLabel = isUrl ? 'Link' : (isCode ? 'Code' : 'Text');

        const deviceId = (item.device_id || '').toLowerCase();
        const isWeb = deviceId.includes('web');
        const isAndroid = deviceId.includes('android') || deviceId.includes('mobile');
        const deviceName = isWeb ? 'Web' : (isAndroid ? 'Android' : 'Mac');

        const deviceSvg = isWeb
          ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"></circle><line x1="2" y1="12" x2="22" y2="12"></line><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"></path></svg>'
          : (isAndroid
              ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="5" y="2" width="14" height="20" rx="2" ry="2"></rect><line x1="12" y1="18" x2="12.01" y2="18"></line></svg>'
              : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="3" width="20" height="14" rx="2" ry="2"></rect><line x1="8" y1="21" x2="16" y2="21"></line><line x1="12" y1="17" x2="12" y2="21"></line></svg>');

        return `
          <article class="entry-card" data-id="\${item.id}" onclick="copyEntryById('\${item.id}')">
            <div class="entry-header">
              <div class="entry-origin">
                <span class="device-tag">
                  \${deviceSvg}
                  <span>\${deviceName}</span>
                </span>
                <span class="type-tag">\${typeLabel}</span>
                <span class="entry-time">\${formatTime(item.timestamp || item.created_at)}</span>
              </div>
              <div class="entry-actions">
                <button class="action-btn copy-btn" title="Copy" onclick="copyEntryBtn(event, '\${item.id}')">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>
                </button>
                <button class="action-btn delete-btn" title="Delete" onclick="deleteEntry(event, '\${item.id}')">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path></svg>
                </button>
              </div>
            </div>
            <div class="entry-body \${isCode ? 'is-code' : (isUrl ? 'is-url' : '')}">\${escapeHtml(item.content)}</div>
            <div class="entry-footer">
              <span>\${item.content ? item.content.length : 0} chars</span>
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
        showToast('Copied');
      } catch (err) {
        showToast('Failed to copy');
      }
    }

    async function deleteEntry(event, id) {
      event.stopPropagation();
      try {
        await fetch('/api/entries/' + id, { method: 'DELETE' });
        entries = entries.filter(e => e.id !== id);
        renderEntries();
        showToast('Deleted');
      } catch (e) {
        showToast('Error deleting');
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
          showToast('Broadcasted to all devices');
        } else {
          showToast('Failed to send');
        }
      } catch (e) {
        showToast('Connection error');
      } finally {
        sendBtn.disabled = false;
      }
    }

    function connectWebSocket() {
      const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      const url = proto + '//' + window.location.host + '/ws';

      ws = new WebSocket(url);

      ws.onopen = () => {
        badgeEl.className = 'status-badge connected';
        statusTextEl.textContent = 'Live';
      };

      ws.onmessage = (event) => {
        try {
          const msg = JSON.parse(event.data);
          if (msg.type === 'init') {
            entries = msg.entries || [];
            if (msg.server_name) {
              serverMeta.textContent = msg.server_name + ' • :' + window.location.port;
            }
            renderEntries();
          } else if (msg.type === 'new_entry') {
            const entry = msg.entry;
            if (!entries.some(e => e.id === entry.id)) {
              entries.unshift(entry);
              renderEntries();
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
        badgeEl.className = 'status-badge disconnected';
        statusTextEl.textContent = 'Disconnected';
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

    searchInput.addEventListener('input', renderEntries);

    // Initial load
    loadEntriesFromRest();
    connectWebSocket();
  </script>
</body>
</html>
''';
  }
}
