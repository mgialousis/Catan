import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'pending_stub.dart'
    if (dart.library.js_interop) 'pending_web.dart'
    as web;
import '../core/protocol.dart';
import 'model.dart';

/// Only an unconfirmed command is persisted, never the board or private hand.
class PendingGameStore {
  PendingGameStore(this.subject, this.roomId, this.playerId);
  final String subject, roomId, playerId;
  String get key => 'island-intent-v1-$subject-$roomId-$playerId';
  Future<JsonMap?> read(Protocol protocol) async {
    final raw = kIsWeb
        ? web.readIntent(key)
        : await const FlutterSecureStorage().read(key: key);
    if (raw == null) return null;
    try {
      final value = object(jsonDecode(raw));
      if (value['roomId'] == roomId && protocol.accepts('gameCommand', value)) {
        return value;
      }
    } catch (_) {
      /* Malformed local storage is not sent to the server. */
    }
    await write(null);
    return null;
  }

  Future<void> write(JsonMap? intent) async {
    if (kIsWeb) {
      web.writeIntent(key, intent == null ? null : jsonEncode(intent));
    } else if (intent == null) {
      await const FlutterSecureStorage().delete(key: key);
    } else {
      await const FlutterSecureStorage().write(
        key: key,
        value: jsonEncode(intent),
      );
    }
  }
}
