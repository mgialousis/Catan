import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'config.dart';
import 'protocol.dart';

final configProvider = Provider<AppConfig>(
  (ref) => const AppConfig.environment(),
);
final protocolProvider = Provider<Protocol>(
  (ref) => throw StateError('Protocol not initialized'),
);
final supabaseProvider = Provider<SupabaseClient>(
  (ref) => Supabase.instance.client,
);
final guestSessionProvider = FutureProvider<Session>((ref) async {
  final auth = ref.read(supabaseProvider).auth;
  final session = auth.currentSession;
  // Never silently replace an existing guest identity after a failed refresh.
  final response = session == null
      ? await auth.signInAnonymously()
      : session.isExpired
      ? await auth.refreshSession()
      : null;
  final result = response?.session ?? auth.currentSession;
  if (result == null) throw StateError('Guest session unavailable');
  return result;
});

enum ConnectionStatus {
  idle,
  authenticating,
  connecting,
  connected,
  reconnecting,
  failed,
}

class ConnectionView {
  const ConnectionView(this.status, this.message, {this.hello});
  final ConnectionStatus status;
  final String message;
  final ServerHello? hello;
}

final connectionProvider =
    NotifierProvider<ConnectionController, ConnectionView>(
      ConnectionController.new,
    );

class ConnectionController extends Notifier<ConnectionView> {
  io.Socket? _socket;
  final _events = StreamController<MapEntry<String, dynamic>>.broadcast(
    sync: true,
  );
  Stream<MapEntry<String, dynamic>> get events => _events.stream;
  String? get subject => _subject;
  void subscribeRoom(String roomId, {int? lastRevision}) {
    _socket?.emit('session.subscribe', {
      'requestId': const Uuid().v4(),
      'roomId': roomId,
      'lastRoomRevision': lastRevision,
      'lastGameVersion': null,
    });
  }

  Future<Map<String, dynamic>> sendCommand(Map<String, dynamic> command) async {
    final socket = _socket;
    if (socket == null || !socket.connected) throw StateError('Disconnected');
    final result = Completer<Map<String, dynamic>>();
    socket.emitWithAck(
      command['expectedPhaseId'] == null ? 'room.command' : 'game.command',
      command,
      ack: (value) {
        if (!result.isCompleted &&
            ref.read(protocolProvider).accepts('ack', value)) {
          result.complete(Map<String, dynamic>.from(value as Map));
        }
      },
    );
    return result.future.timeout(const Duration(seconds: 8));
  }

  void syncGame(String roomId, int? version) => _socket?.emit('game.sync', {
    'requestId': const Uuid().v4(),
    'roomId': roomId,
    'lastGameVersion': version,
  });
  void checkGameVersion(String roomId) =>
      _socket?.emit('game.version.request', {'roomId': roomId});
  Future<Map<String, dynamic>> history(String roomId, int? before) async {
    final subject = _subject;
    final session = ref.read(supabaseProvider).auth.currentSession;
    if (subject == null || session?.user.id != subject) {
      throw StateError('Session changed');
    }
    final uri =
        Uri.parse(
          '${ref.read(configProvider).apiUrl}/api/v1/rooms/$roomId/activity',
        ).replace(
          queryParameters: {
            'limit': '30',
            if (before != null) 'before': '$before',
          },
        );
    final response = await http
        .get(uri, headers: {'Authorization': 'Bearer ${session!.accessToken}'})
        .timeout(const Duration(seconds: 8));
    if (_disposed || _subject != subject || response.statusCode != 200) {
      throw StateError('History unavailable');
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  StreamSubscription<AuthState>? _authSubscription;
  Timer? _restartTimer;
  bool _recoveringServer = false;
  bool _disposed = false;
  String? _subject;
  final _instanceId = const Uuid().v4();
  @override
  ConnectionView build() {
    ref.onDispose(() {
      _disposed = true;
      _authSubscription?.cancel();
      _restartTimer?.cancel();
      _socket?.dispose();
      _events.close();
    });
    return const ConnectionView(
      ConnectionStatus.idle,
      'Your private table starts here.',
    );
  }

  Future<void> connect() async {
    if ([
      ConnectionStatus.authenticating,
      ConnectionStatus.connecting,
    ].contains(state.status)) {
      return;
    }
    state = const ConnectionView(
      ConnectionStatus.authenticating,
      'Preparing your guest session…',
    );
    ref.invalidate(guestSessionProvider);
    try {
      final session = await ref.read(guestSessionProvider.future);
      if (_disposed) return;
      _authSubscription ??= ref
          .read(supabaseProvider)
          .auth
          .onAuthStateChange
          .listen(
            (event) {
              if (_disposed) return;
              final next = event.session;
              if (next == null) {
                _socket?.dispose();
                _subject = null;
                _events.add(const MapEntry('session.revoked', null));
                state = const ConnectionView(
                  ConnectionStatus.failed,
                  'Your session ended. Connect again to continue.',
                );
                ref.invalidate(guestSessionProvider);
              } else if (event.event == AuthChangeEvent.tokenRefreshed ||
                  next.user.id != _subject) {
                _open(next);
              }
            },
            onError: (_) {
              if (!_disposed) {
                state = const ConnectionView(
                  ConnectionStatus.failed,
                  'Your session could not refresh. Please retry.',
                );
              }
            },
          );
      _open(ref.read(supabaseProvider).auth.currentSession ?? session);
    } catch (_) {
      if (!_disposed) {
        ref.invalidate(guestSessionProvider);
        state = const ConnectionView(
          ConnectionStatus.failed,
          'Could not prepare your session. Check the connection and retry.',
        );
      }
    }
  }

  void _open(Session session) {
    _socket?.dispose();
    if (_subject != null && _subject != session.user.id) {
      _events.add(const MapEntry('session.revoked', null));
    }
    _subject = session.user.id;
    state = const ConnectionView(
      ConnectionStatus.connecting,
      'Connecting to your table…',
    );
    final config = ref.read(configProvider);
    final socket = io.io(
      '${config.apiUrl}/game',
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setPath('/socket.io')
          .disableAutoConnect()
          .enableForceNew()
          .setAuth({
            'accessToken': session.accessToken,
            'protocolVersion': 1,
            'clientInstanceId': _instanceId,
          })
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(10000)
          .build(),
    );
    _socket = socket;
    bool active() => !_disposed && identical(_socket, socket);
    socket.on('server.hello', (value) {
      if (!active()) return;
      try {
        final hello = ServerHello.parse(value, ref.read(protocolProvider));
        _recoveringServer = false;
        state = ConnectionView(
          ConnectionStatus.connected,
          'Connected. Your guest session is ready.',
          hello: hello,
        );
      } catch (_) {
        socket.dispose();
        state = const ConnectionView(
          ConnectionStatus.failed,
          'This server needs a compatible app version.',
        );
      }
    });
    for (final entry in {
      'game.snapshot': 'gameSnapshot',
      'game.delta': 'gameDelta',
      'game.version': 'gameVersion',
      'session.membership': 'membership',
      'room.snapshot': 'roomSnapshot',
      'presence.update': 'presence',
      'session.error': 'error',
    }.entries) {
      socket.on(entry.key, (value) {
        if (active() &&
            ref.read(protocolProvider).accepts(entry.value, value)) {
          _events.add(MapEntry(entry.key, value));
        }
      });
    }
    socket.on('server.restarting', (value) {
      if (!active() ||
          !ref.read(protocolProvider).accepts('restarting', value)) {
        return;
      }
      _recoveringServer = true;
      _restartTimer?.cancel();
      _restartTimer = Timer(
        Duration(milliseconds: (value as Map)['retryAfterMs'] as int),
        () {
          if (!_disposed) unawaited(connect());
        },
      );
    });
    socket.onConnectError((error) {
      if (active()) {
        if (_recoveringServer) {
          _restartTimer?.cancel();
          _restartTimer = Timer(const Duration(seconds: 5), () {
            if (!_disposed) unawaited(connect());
          });
        }
        state = const ConnectionView(
          ConnectionStatus.failed,
          'Could not connect. Check that the local server is running.',
        );
      }
    });
    socket.onDisconnect((_) {
      if (active()) {
        state = const ConnectionView(
          ConnectionStatus.reconnecting,
          'Connection lost. Reconnecting…',
        );
      }
    });
    socket.on('session.error', (value) {
      if (!active() || !ref.read(protocolProvider).accepts('error', value)) {
        return;
      }
      final code = (value as Map)['code'];
      if (code == 'TOKEN_EXPIRED' || code == 'UNAUTHENTICATED') {
        unawaited(_refresh());
      }
    });
    socket.connect();
  }

  Future<void> _refresh() async {
    try {
      await ref.read(supabaseProvider).auth.refreshSession();
    } catch (_) {
      if (!_disposed) {
        state = const ConnectionView(
          ConnectionStatus.failed,
          'Your session could not refresh. Please retry.',
        );
      }
    }
  }

  Future<void> resume() async {
    if (_disposed || _subject == null) return;
    final session = ref.read(supabaseProvider).auth.currentSession;
    if (session == null || session.isExpired) {
      await _refresh();
    } else if (_socket?.connected != true || session.user.id != _subject) {
      _open(session);
    } else {
      _events.add(const MapEntry('session.foreground', null));
    }
  }
}
