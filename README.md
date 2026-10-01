# Tampal 📋⚡

[![Flutter](https://img.shields.io/badge/Flutter-3.24+-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.5+-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20%7C%20Windows%20%7C%20Linux%20%7C%20Android%20%7C%20iOS%20%7C%20Web-brightgreen)](https://flutter.dev/multi-platform)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Tampal** is a modern, privacy-first, zero-cloud clipboard synchronization tool built with Flutter. It seamlessly syncs clipboard text, code snippets, and URLs across your local devices (Mac, Windows, Linux, Android, iOS, and web browsers) in real time over local Wi-Fi.

---

## 📑 Table of Contents

- [Key Features](#-key-features)
- [Architecture & Directory Structure](#-architecture--directory-structure)
- [How It Works: Technical Deep Dive](#-how-it-works-technical-deep-dive)
  - [1. Zeroconf / mDNS Peer Discovery](#1-zeroconf--mdns-peer-discovery)
  - [2. Bidirectional TCP Socket Protocol](#2-bidirectional-tcp-socket-protocol)
  - [3. Anti-Echo Clipboard Observation](#3-anti-echo-clipboard-observation)
  - [4. Embedded HTTP & WebSocket Portal](#4-embedded-http--websocket-portal)
  - [5. SQLite Storage & Retention Engine](#5-sqlite-storage--retention-engine)
  - [6. State Management Architecture](#6-state-management-architecture)
- [UI & Theme System](#-ui--theme-system)
- [Getting Started & Installation](#-getting-started--installation)
  - [Prerequisites](#prerequisites)
  - [Running on Desktop (macOS / Windows / Linux)](#running-on-desktop-macos--windows--linux)
  - [Running on Mobile (Android / iOS)](#running-on-mobile-android--ios)
  - [Running Web Portal Client](#running-web-portal-client)
- [VS Code Run & Debug Profiles](#-vs-code-run--debug-profiles)
- [REST & WebSocket API Reference](#-rest--websocket-api-reference)
- [Configuration & Storage Keys](#-configuration--storage-keys)
- [Testing & Quality Assurance](#-testing--quality-assurance)
- [Troubleshooting & FAQ](#-troubleshooting--faq)
- [Security & Privacy](#-security--privacy)

---

## ✨ Key Features

- **⚡ Instant Real-Time Sync**: Copied text appears on connected devices within milliseconds over local TCP sockets.
- **🔒 100% Local & Private**: No cloud relay, no third-party servers, and no telemetry. All data stays strictly within your local Wi-Fi network.
- **🔍 Automatic Peer Discovery**: Uses Bonjour/Zeroconf/mDNS (`_tampal._tcp`) to detect active devices automatically without entering IP addresses.
- **🌐 Built-in Web Portal**: Desktop instances host an embedded web portal with WebSockets. Any phone, tablet, or secondary PC can participate in clipboard sync instantly via web browser without installing the native app.
- **🔄 Smart Anti-Echo**: Internal hashing and suppression prevent ping-pong loops when synced text is written into the receiving device's clipboard.
- **💾 Local SQLite History**: Stores clipboard history locally on each device with full-text search, categorization (Text, Links, Code), and single-tap re-copying.
- **🧹 Automatic Retention Pruning**: Configurable retention policies (e.g., keep last 100 items, keep 7 days, or unlimited) keep your database lightweight.
- **🎨 Raycast-Inspired UI**: Beautiful dark and light modes, typography, smooth micro-interactions, connection indicators, and quick-broadcast command inputs.

---

## 🏗 Architecture & Directory Structure

Tampal is architected as a modular Flutter project where platform-agnostic business logic is decoupled from platform entry points and UI presentation:

```
lib/
├── core/                                # Platform-Agnostic Core Domain & Services
│   ├── constants/
│   │   └── app_constants.dart           # Service types, default ports, DB names, storage keys
│   ├── models/
│   │   ├── clipboard_entry.dart         # Entry data model, SQLite serializer, socket JSON format
│   │   ├── sync_message.dart            # Protocol messages: handshake, pushEntry, syncRequest, syncResponse
│   │   └── device_info.dart             # Peer device representation & connection status
│   ├── database/
│   │   └── clipboard_database.dart      # SQLite persistence layer (sqflite / sqflite_common_ffi)
│   ├── network/
│   │   ├── discovery_service.dart       # mDNS broadcast & discovery engine via Bonsoir
│   │   ├── socket_framing.dart          # Line-delimited (\n) TCP stream encoder/decoder
│   │   ├── sync_connection.dart        # Socket session wrapper with keepalive pings
│   │   ├── sync_service.dart            # TCP server/client, handshake, batch sync & reconnect
│   │   └── web_server.dart              # Embedded HTTP REST API & WebSocket server for LAN browsers
│   ├── clipboard/
│   │   └── clipboard_watcher.dart       # Periodic poller, app lifecycle watcher & echo suppression
│   ├── providers/
│   │   └── tampal_providers.dart        # Flutter Riverpod providers, streams, and notifiers
│   └── services/
│       └── settings_service.dart        # SharedPreferences wrapper for device name, ports, policies
├── ui/                                  # Presentation & Views
│   ├── screens/
│   │   ├── history_screen.dart          # Main clipboard feed, search, filter tabs, quick-composer
│   │   ├── pairing_screen.dart          # Discovered peers list, manual IP:port pair, LAN portal URL
│   │   └── settings_screen.dart         # Retention rules, friendly device name, port configurations
│   ├── widgets/
│   │   ├── clipboard_card.dart          # Clipboard entry card with type tags, preview & actions
│   │   ├── connection_badge.dart        # Status pill indicator (Connected / Disconnected / Syncing)
│   │   └── empty_state.dart             # Placeholder states for empty feeds and search misses
│   └── theme/
│       └── app_theme.dart               # Theme system (Obsidian dark & clean light themes)
├── main_mobile.dart                     # Entry point optimized for Android & iOS
├── main_desktop.dart                    # Entry point optimized for macOS, Windows & Linux
├── main_web.dart                        # Standalone Web App client entry point
└── main.dart                            # Multi-platform automatic routing entry point
```

---

## 🔬 How It Works: Technical Deep Dive

```
+-----------------------------------------------------------------------------------------+
|                                     LOCAL WI-FI NETWORK                                 |
|                                                                                         |
|   +--------------------+     mDNS (_tampal._tcp)     +--------------------+             |
|   |   Tampal Desktop   | <.........................> |   Tampal Mobile    |             |
|   |   (TCP Port 42880) |                             |   (Android / iOS)  |             |
|   |                    | <=========================> |                    |             |
|   +---------+----------+      TCP Sockets (Framed)   +--------------------+             |
|             |                                                                           |
|             | HTTP & WebSockets (Port 42881)                                            |
|             v                                                                           |
|   +--------------------+                                                                |
|   |    Web Browser     |                                                                |
|   |  (Phone / Laptop)  |                                                                |
|   +--------------------+                                                                |
+-----------------------------------------------------------------------------------------+
```

### 1. Zeroconf / mDNS Peer Discovery
- Uses multicast DNS (`_tampal._tcp`) powered by the `bonsoir` package.
- When started, a **Tampal Desktop** instance starts broadcasting its service details (Device Name, Device ID, Platform, and TCP Server Port).
- **Tampal Mobile** starts discovery on launch, discovering available desktop hosts within seconds on the same subnet without manual configuration.

### 2. Bidirectional TCP Socket Protocol
- **Port**: Default `42880` (configurable in settings).
- **Framing**: Messages are encoded as UTF-8 JSON objects delimited by newline (`\n`) characters to prevent TCP stream fragmentation issues.
- **Handshake Flow**:
  1. Once a TCP socket connection is established, the client sends a `HandshakePayload`:
     ```json
     {
       "type": "handshake",
       "data": {
         "device_id": "8482f3a8-20a2-4a7b-a45e-b816a13d7191",
         "device_name": "Workstation PC",
         "platform": "windows",
         "latest_timestamp": "2026-10-01T08:00:00.000Z"
       }
     }
     ```
  2. The server responds with its own handshake.
  3. Missing history entries since `latest_timestamp` are queried from SQLite and sent in a `syncResponse` batch to synchronize offline history.
- **Live Push Sync**:
  Whenever the local clipboard changes, a `pushEntry` message is dispatched across all active socket sessions:
  ```json
  {
    "id": "e309cb92-c423-42bf-9032-429ad1be84e6",
    "device_id": "8482f3a8-20a2-4a7b-a45e-b816a13d7191",
    "content_type": "text",
    "content": "https://github.com/flutter/flutter",
    "timestamp": "2026-10-01T08:05:30.000Z"
  }
  ```

### 3. Anti-Echo Clipboard Observation
When Device B receives text from Device A:
1. Device B writes the received text to its local system clipboard.
2. If left unmanaged, Device B's clipboard watcher would detect the change and push it back to Device A, creating an endless feedback loop.
3. **Tampal solves this** by tracking recently synced content in `ClipboardWatcher._suppressedContents`. When an external copy matches the suppression register, the event is recorded locally in SQLite but suppressed from socket rebroadcast.

### 4. Embedded HTTP & WebSocket Portal
- Desktop nodes automatically initialize an embedded `HttpServer` listening on port `42881`.
- It serves a rich, single-page web dashboard crafted with clean HTML5/CSS/JavaScript.
- Includes WebSocket live streaming (`ws://<ip>:42881/ws`) for bidirectional sync directly from web browsers without any installation.

### 5. SQLite Storage & Retention Engine
- Desktop platforms utilize `sqflite_common_ffi` with native SQLite bindings.
- Mobile platforms utilize native platform SQLite via `sqflite`.
- **Schema**:
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
- **Automated Retention**: Runs at app boot and after saves, pruning items that exceed maximum item count (e.g. 100) or age limits (e.g. 7 days).

### 6. State Management Architecture
- Built on **Riverpod 2.x**.
- `clipboardHistoryProvider`: Manages loaded clipboard list, reactive search filters, copy operations, and deletions.
- `syncStatusProvider` & `activePeerProvider`: Reactive streams displaying connection health and peer details in real time.
- `appThemeModeProvider`: StateNotifier persisting Dark / Light mode UI state.

---

## 🎨 UI & Theme System

| Element | Dark Mode Token | Light Mode Token |
|---|---|---|
| Background | `#0C0D11` (Obsidian) | `#F8F9FA` (Soft Off-White) |
| Elevated Surfaces | `#14151D` | `#FFFFFF` |
| Primary Accent | `#3B82F6` (Electric Blue) | `#2563EB` |
| Secondary Accent | `#38BDF8` (Sky) | `#38BDF8` |
| Glass Borders | `#1E222E` | `#E5E7EB` |
| Text Primary | `#EDEDED` | `#111827` |
| Text Secondary | `#8E93A4` | `#4B5563` |

### Responsive Layouts
- **Desktop**: Compact card lists with quick-filter chips, broadcast command bar, search-as-you-type, and persistent connection status.
- **Mobile**: Touch-optimized cards with swipe gestures, app lifecycle resume triggers, and easy pairing QR/discovery lists.
- **Web Portal**: Single-page dashboard accessible via mobile and desktop browsers on local Wi-Fi.

---

## 🚀 Getting Started & Installation

### Prerequisites
- [Flutter SDK](https://docs.flutter.dev/get-started/install) (version 3.24 or higher)
- [Dart SDK](https://dart.dev/get-dart) (version 3.5 or higher)
- For macOS: Xcode & CocoaPods
- For Windows: Visual Studio 2022 with C++ desktop development
- For Linux: `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`
- For Android: Android Studio & Android SDK 34+

### Clone & Install Dependencies
```bash
git clone https://github.com/your-username/tampal.git
cd tampal
flutter pub get
```

### Running on Desktop (macOS / Windows / Linux)
```bash
# macOS
flutter run -d macos -t lib/main_desktop.dart

# Windows
flutter run -d windows -t lib/main_desktop.dart

# Linux
flutter run -d linux -t lib/main_desktop.dart
```

### Running on Mobile (Android / iOS)
```bash
# Android
flutter run -d android -t lib/main_mobile.dart

# iOS Simulator / Device
flutter run -d ios -t lib/main_mobile.dart
```

### Running Web Portal Client
```bash
flutter run -d chrome -t lib/main_web.dart
```

### Deploying to Vercel
This repository includes a [vercel.json](file:///Users/Apple/vscode_projects/copysync/vercel.json) and [vercel-build.sh](file:///Users/Apple/vscode_projects/copysync/vercel-build.sh) script that automatically installs the Flutter SDK in the Vercel build environment and compiles the web release:

1. **Via GitHub Integration**: Connect your repository to Vercel. Vercel will automatically detect `vercel.json` and execute `bash vercel-build.sh` to output the build to `build/web`.
2. **Via Vercel CLI**:
   ```bash
   # Build locally
   flutter build web --release

   # Deploy compiled output to Vercel
   npx vercel deploy build/web --prod
   ```

---

## 💻 VS Code Run & Debug Profiles

Pre-configured launch configurations are included in `.vscode/launch.json`:

| Launch Configuration | Target File | Target Platform |
|---|---|---|
| **Tampal Desktop** | `lib/main_desktop.dart` | macOS / Windows / Linux |
| **Tampal Mobile** | `lib/main_mobile.dart` | Android / iOS |
| **Tampal Web** | `lib/main_web.dart` | Chrome / Edge |
| **Tampal (Auto)** | `lib/main.dart` | Auto-detects running host platform |

---

## 🔌 REST & WebSocket API Reference

When the Desktop application is running, the embedded web portal exposes the following local endpoints on port `42881`:

### 1. Get Clipboard Entries
- **Endpoint**: `GET /api/entries`
- **Query Params**: `q` *(optional)* — Search query string.
- **Response**: `200 OK`
  ```json
  [
    {
      "id": "e309cb92-c423-42bf-9032-429ad1be84e6",
      "device_id": "8482f3a8-20a2-4a7b-a45e-b816a13d7191",
      "content_type": "text",
      "content": "Sample clipboard text",
      "timestamp": "2026-10-01T08:30:00.000Z"
    }
  ]
  ```

### 2. Broadcast New Entry
- **Endpoint**: `POST /api/send`
- **Headers**: `Content-Type: application/json`
- **Body**:
  ```json
  {
    "content": "Text to sync across all devices"
  }
  ```
- **Response**: `200 OK` `{"status": "ok"}`

### 3. Delete Entry
- **Endpoint**: `DELETE /api/entries/<id>`
- **Response**: `200 OK` `{"status": "deleted"}`

### 4. WebSocket Live Stream
- **Endpoint**: `ws://<ip>:42881/ws`
- **Events**:
  - `init`: Sends initial list of recent entries upon connection.
  - `new_entry`: Broadcasted to all connected clients whenever a new copy event occurs.
  - `delete_entry`: Broadcasted when an item is deleted.

---

## ⚙️ Configuration & Storage Keys

Tampal stores user preferences in local storage (`SharedPreferences`):

| Key | Default | Description |
|---|---|---|
| `tampal_device_id` | Auto UUIDv4 | Unique identifier for the local device. |
| `tampal_device_name` | Device Name | Human-readable name (e.g. *MacBook Pro*). |
| `tampal_server_port` | `42880` | TCP listening port for device-to-device sync. |
| `tampal_web_port` | `42881` | HTTP & WebSocket port for the embedded web portal. |
| `tampal_web_enabled`| `true` | Enables or disables the embedded web server. |
| `tampal_auto_sync` | `true` | Automatically connects to the last paired peer. |
| `tampal_retention_limit` | `100` | Maximum number of entries kept in local SQLite DB. |
| `tampal_retention_days` | `7` | Maximum days before older entries are pruned (0 = forever). |

---

## 🧪 Testing & Quality Assurance

Run the comprehensive unit and widget test suite:
```bash
# Run all tests
flutter test

# Run specific test files
flutter test test/unit_test.dart
flutter test test/widget_test.dart
```

Perform static analysis with Flutter linter:
```bash
flutter analyze
```

---

## 🛠 Troubleshooting & FAQ

#### Q: My devices cannot discover each other automatically.
1. Ensure both devices are connected to the **same Wi-Fi network** (and not on separated Guest/AP-isolated subnets).
2. Ensure your firewall allows incoming connections on ports `42880` and `42881`.
3. If your router blocks multicast / mDNS packets, use the **Manual Connect** option in the *Pair & Connect* screen by entering `IP:42880`.

#### Q: How do I access the Web Dashboard on my phone?
1. Open Tampal on your Desktop.
2. Navigate to **Pair & Connect** or **Settings**.
3. Locate the **Web Portal URL** (e.g., `http://192.168.1.50:42881`).
4. Open this URL in any mobile or desktop web browser connected to the same Wi-Fi.

#### Q: Does Tampal sync images or large files?
Currently, Tampal is optimized for text, URLs, JSON payloads, and source code. Image and binary file synchronization support is planned for a future release.

---

## 🛡 Security & Privacy

- **Zero Cloud**: Data never leaves your local area network (LAN).
- **No Analytics / Telemetry**: No tracking identifiers or usage data are collected.
- **Local Persistence**: All SQLite databases (`tampal.db`) reside exclusively in your device's local application support directory.

---

## 📄 License

Distributed under the MIT License. See [LICENSE](LICENSE) for more details.
