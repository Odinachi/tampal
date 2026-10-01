# Tampal

A modern, cross-platform Flutter application that syncs clipboard content two-way between mobile devices (Android/iOS) and desktop workstations (macOS/Windows/Linux) over the local Wi-Fi network, retaining clipboard history on both ends with SQLite storage.

---

## Architecture Overview

Tampal is built as a single unified Flutter repository with a shared business core and three distinct entry points (Mobile, Desktop, Web):

```
lib/
├── core/                                # Shared core logic (platform agnostic)
│   ├── constants/
│   │   └── app_constants.dart           # Service type (_tampal._tcp), ports, constants
│   ├── models/
│   │   ├── clipboard_entry.dart         # Entry model, SQLite mapping & sync JSON
│   │   ├── sync_message.dart            # Handshake, syncRequest, syncResponse, pushEntry
│   │   └── device_info.dart             # Peer device representation
│   ├── database/
│   │   └── clipboard_database.dart      # SQLite storage (sqflite / sqflite_common_ffi)
│   ├── network/
│   │   ├── discovery_service.dart       # mDNS broadcast & discovery via Bonsoir
│   │   ├── socket_framing.dart          # Line-delimited stream framing for TCP
│   │   ├── sync_connection.dart        # Socket session with keepalive pings
│   │   ├── sync_service.dart            # Handshake, bidirectional sync, auto-reconnect
│   │   └── web_server.dart              # Local web portal for browser sync
│   ├── clipboard/
│   │   └── clipboard_watcher.dart       # Real-time polling, app resume hook, anti-echo
│   ├── providers/
│   │   └── tampal_providers.dart        # Riverpod providers for app state
│   └── services/
│       └── settings_service.dart        # Device identity, retention limits & preferences
├── ui/                                  # Shared UI components
│   ├── screens/
│   │   ├── history_screen.dart          # Reverse-chronological history, re-copy, search
│   │   ├── pairing_screen.dart          # mDNS discovery list, manual connect, status
│   │   └── settings_screen.dart         # Retention policy, friendly name, storage actions
│   ├── widgets/
│   │   ├── clipboard_card.dart          # Tappable card with copy feedback and metadata
│   │   ├── connection_badge.dart        # Status badge with live peer indicator
│   │   └── empty_state.dart             # Visual placeholder for empty history/search
│   └── theme/
│       └── app_theme.dart               # Modern theme with dark/light mode support
├── main_mobile.dart                     # Mobile entry point (Android / iOS)
├── main_desktop.dart                    # Desktop entry point (macOS / Windows / Linux)
├── main_web.dart                        # Web portal client entry point
└── main.dart                            # Auto-routing fallback entry point
```

---

## Running the Application

### Desktop Build (macOS / Windows / Linux)
```bash
flutter run -t lib/main_desktop.dart
# or specifying target device:
flutter run -d macos -t lib/main_desktop.dart
flutter run -d windows -t lib/main_desktop.dart
flutter run -d linux -t lib/main_desktop.dart
```

### Mobile Build (Android / iOS)
```bash
flutter run -t lib/main_mobile.dart
# or specifying target device:
flutter run -d android -t lib/main_mobile.dart
flutter run -d ios -t lib/main_mobile.dart
```

### Web Build
```bash
flutter run -d chrome -t lib/main_web.dart
```

### VS Code
Launch configurations are set up in `.vscode/launch.json`:
- **Tampal Mobile**
- **Tampal Desktop**
- **Tampal Web**
- **Tampal (Auto)**

---

## Core Features & Protocol

### 1. Device Discovery (mDNS)
- Uses Zeroconf / mDNS advertising service type `_tampal._tcp`.
- Desktop acts as the default listening server on port `42880`.
- Mobile devices automatically discover desktop peers on the local Wi-Fi and display them in the Pair & Connect view.
- Manual direct connection (`IP:Port`) is also available for complex router configurations.

### 2. Handshake on Connect
When a device connects, both peers exchange a handshake message:
```json
{
  "type": "handshake",
  "data": {
    "device_id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
    "device_name": "MacBook Pro",
    "platform": "macos",
    "latest_timestamp": "2026-09-27T16:15:00.000Z"
  }
}
```
Each peer compares the latest timestamp with its local database and automatically synchronizes any missing clipboard entries.

### 3. Real-Time Clipboard Synchronization
- **Push Payload Format**:
```json
{
  "id": "e309cb92-c423-42bf-9032-429ad1be84e6",
  "device_id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
  "content_type": "text",
  "content": "Copied content here",
  "timestamp": "2026-09-27T16:15:30.000Z"
}
```
- **Echo Suppression**: Received remote entries are marked internally so `ClipboardWatcher` sets the system clipboard without echoing the text back over the socket.
- **Mobile Lifecycle Hook**: On iOS and Android, resuming the app triggers an immediate clipboard inspection. A prominent manual "Sync Now" button is also provided.

### 4. SQLite Schema & Retention
Stored in `tampal.db`:
```sql
CREATE TABLE clipboard_entries (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  content_type TEXT NOT NULL,
  content TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_created_at ON clipboard_entries(created_at);
```
- **Configurable Retention**: Default keeps the last 100 entries or last 7 days. Configurable in the Settings screen (50 to 500 entries, 3 to 30 days or forever).

---

## Running Tests & Verification

Run the test suite:
```bash
flutter test
```

Analyze the codebase:
```bash
flutter analyze
```
