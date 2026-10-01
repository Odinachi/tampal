// lib/webrtc/tampal_webrtc.dart
//
// Dart bridge to the native browser WebRTC API.
// Uses dart:js_interop (Dart 3 standard — no deprecated `package:js` needed).
// Calls window.TampalRTC.* methods defined in web/tampal_webrtc.js.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

// ---------------------------------------------------------------------------
// JS interop — bind to window.TampalRTC.*
// ---------------------------------------------------------------------------

@JS('TampalRTC.createOffer')
external void _jsCreateOffer(
  String signalBase,
  String room,
  JSFunction onMessage,
  JSFunction onStateChange,
);

@JS('TampalRTC.joinWithAnswer')
external void _jsJoinWithAnswer(
  String signalBase,
  String room,
  JSFunction onMessage,
  JSFunction onStateChange,
);

@JS('TampalRTC.sendMessage')
external bool _jsSendMessage(String json);

@JS('TampalRTC.close')
external void _jsClose();

@JS('TampalRTC.isConnected')
external bool _jsIsConnected();

// ---------------------------------------------------------------------------
// Connection state enum
// ---------------------------------------------------------------------------

enum WebRtcState {
  idle,
  waiting,    // Host created offer, waiting for peer
  connecting, // Peer joined, ICE negotiation in progress
  connected,  // DataChannel open — P2P active
  disconnected,
  error,
}

// ---------------------------------------------------------------------------
// TampalWebRTC — public Dart API
// ---------------------------------------------------------------------------

class TampalWebRTC {
  final String signalBase;

  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  final _stateController = StreamController<WebRtcState>.broadcast();

  WebRtcState _state = WebRtcState.idle;

  TampalWebRTC({required this.signalBase});

  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;
  Stream<WebRtcState> get stateStream => _stateController.stream;
  WebRtcState get state => _state;
  bool get isConnected => _state == WebRtcState.connected;

  void _handleMessage(String data) {
    try {
      final parsed = jsonDecode(data) as Map<String, dynamic>;
      _messageController.add(parsed);
    } catch (_) {}
  }

  void _handleStateChange(String rawState) {
    WebRtcState next;
    switch (rawState) {
      case 'waiting':
        next = WebRtcState.waiting;
      case 'connecting':
      case 'checking':
        next = WebRtcState.connecting;
      case 'connected':
        next = WebRtcState.connected;
      case 'disconnected':
      case 'closed':
      case 'failed':
        next = WebRtcState.disconnected;
      case 'error':
        next = WebRtcState.error;
      default:
        return; // unknown state — don't update
    }
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  /// Host side: create WebRTC offer and push to signaling server.
  /// Browser B must call [joinWithAnswer] with the same [roomCode].
  Future<void> createOffer(String roomCode) async {
    _updateState(WebRtcState.waiting);
    _jsCreateOffer(
      signalBase,
      roomCode,
      ((JSString data) => _handleMessage(data.toDart)).toJS,
      ((JSString state) => _handleStateChange(state.toDart)).toJS,
    );
  }

  /// Joiner side: fetch offer and reply with an answer.
  Future<void> joinWithAnswer(String roomCode) async {
    _updateState(WebRtcState.connecting);
    _jsJoinWithAnswer(
      signalBase,
      roomCode,
      ((JSString data) => _handleMessage(data.toDart)).toJS,
      ((JSString state) => _handleStateChange(state.toDart)).toJS,
    );
  }

  /// Send a clipboard entry over the DataChannel to the peer.
  bool sendEntry(Map<String, dynamic> entryJson) {
    if (!_jsIsConnected()) return false;
    return _jsSendMessage(jsonEncode({'type': 'entry', 'data': entryJson}));
  }

  void _updateState(WebRtcState s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  void close() {
    _jsClose();
    _updateState(WebRtcState.idle);
  }

  void dispose() {
    close();
    _messageController.close();
    _stateController.close();
  }
}
