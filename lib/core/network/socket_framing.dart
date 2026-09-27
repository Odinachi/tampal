import 'dart:async';
import 'dart:convert';
import 'dart:io';

class SocketMessageFramer {
  /// Send a JSON map or string message over the socket followed by a newline delimiter
  static void sendMessage(Socket socket, String jsonString) {
    socket.add(utf8.encode('$jsonString\n'));
  }

  /// Create a stream of parsed JSON string lines from a raw socket
  static Stream<String> frameStream(Socket socket) {
    return socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.trim().isNotEmpty);
  }
}
