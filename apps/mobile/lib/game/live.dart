import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/connection.dart';
import '../core/protocol.dart';
import '../lobby/lobby.dart';
import 'controller.dart';
import 'delta.dart';
import 'game_screen.dart';
import 'model.dart';
import 'pending.dart';

class LiveGamePort extends GamePort {
  LiveGamePort(
    this.connection,
    this.protocol,
    this.store,
    this.ownsSession,
    this.online,
  );
  final ConnectionController connection;
  final Protocol protocol;
  final PendingGameStore store;
  final bool Function() ownsSession, online;
  final _events = StreamController<MapEntry<String, dynamic>>.broadcast(
    sync: true,
  );
  StreamSubscription<MapEntry<String, dynamic>>? _subscription;
  Timer? _versionTimer;
  GameSnapshot? _snapshot;
  JsonMap? _restored;
  bool _closed = false, _syncing = false, _historyLoading = false;
  bool _unavailable = false;
  Timer? _syncTimeout;
  int? _before;
  bool _historyStarted = false, _historyEnded = false;
  final Map<int, List<String>> _history = {};
  @override
  Stream<MapEntry<String, dynamic>> get events => _events.stream;
  void _emit(String key, dynamic value) {
    if (!_closed) _events.add(MapEntry(key, value));
  }

  @override
  Future<void> connect() async {
    _restored = await store.read(protocol);
    if (_closed) return;
    _subscription ??= connection.events.listen(_event);
    _versionTimer ??= Timer.periodic(const Duration(seconds: 15), (_) {
      if (online() && ownsSession()) connection.checkGameVersion(store.roomId);
    });
    status();
  }

  void status() {
    if (_closed) return;
    if (!ownsSession()) {
      _revoke();
      return;
    }
    _emit('connected', online() && !_unavailable);
  }

  void _revoke() {
    _snapshot = null;
    _restored = null;
    unawaited(store.write(null).catchError((_) {}));
    _emit('revoked', null);
    close();
  }

  @override
  void synchronize() {
    if (_closed || !online() || !ownsSession() || _syncing) return;
    _syncing = true;
    _syncTimeout?.cancel();
    _syncTimeout = Timer(const Duration(seconds: 8), () {
      _syncing = false;
      if (!_closed) _emit('connected', false);
    });
    connection.syncGame(store.roomId, _snapshot?.version);
  }

  void _event(MapEntry<String, dynamic> event) {
    if (_closed) return;
    if (!ownsSession() || event.key == 'session.revoked') {
      _revoke();
      return;
    }
    if (event.key == 'session.foreground') {
      synchronize();
      return;
    }
    if (event.key == 'session.error' &&
        (event.value as Map)['code'] == 'SERVICE_UNAVAILABLE') {
      _unavailable = true;
      _emit('connected', false);
      _emit(
        'message',
        'The saved game is temporarily unavailable. Actions will resume after recovery.',
      );
      return;
    }
    if (!event.key.startsWith('game.')) return;
    final value = object(event.value);
    if (value['roomId'] != store.roomId) return;
    try {
      switch (event.key) {
        case 'game.snapshot':
          final next = GameSnapshot.parse(value, protocol);
          if (next.playerId != store.playerId) {
            _revoke();
            return;
          }
          if (_snapshot != null && next.version < _snapshot!.version) return;
          _syncing = false;
          _syncTimeout?.cancel();
          _unavailable = false;
          _publish(next);
          _emit('connected', online());
          if (_restored != null) {
            final pending = _restored!;
            _restored = null;
            _emit('restoreIntent', pending);
          }
          if (!_historyStarted) unawaited(history());
        case 'game.delta':
          if (_snapshot != null &&
              (value['toVersion'] as int) <= _snapshot!.version) {
            return;
          }
          if (_snapshot == null) {
            synchronize();
            return;
          }
          final next = applyDelta(_snapshot!, value, protocol);
          _publish(next);
          _history[next.version] = [
            for (final e in value['activity'] as List)
              (e as Map)['message'] as String,
          ];
          _emitHistory();
        case 'game.version':
          if (value['serverTime'] is String) {
            _emit('clock', value['serverTime']);
          }
          if (_unavailable || _snapshot?.version != value['version']) {
            synchronize();
          }
      }
    } catch (_) {
      synchronize();
    }
  }

  void _publish(GameSnapshot next) {
    final previous = _snapshot;
    _snapshot = next;
    _emit('snapshot', next.json);
    if (previous != null) {
      final ids = previous.cards.map((c) => c['id']).toSet();
      for (final card in next.cards.where((c) => !ids.contains(c['id']))) {
        _emit('draw', words(card['type'] as String));
      }
    }
  }

  @override
  Future<JsonMap> send(JsonMap command) async {
    if (_closed || !ownsSession() || command['roomId'] != store.roomId) {
      throw StateError('Session changed');
    }
    // A reload can retry this exact envelope even if the first response is lost.
    await store.write(command);
    for (var attempt = 0; attempt < 5; attempt++) {
      if (_closed || !ownsSession() || !online()) {
        throw StateError('Disconnected');
      }
      try {
        final ack = await connection.sendCommand(command);
        if (_closed || !ownsSession()) throw StateError('Session changed');
        if (!protocol.accepts('ack', ack) ||
            ack['scope'] != 'GAME' ||
            ack['roomId'] != store.roomId ||
            ack['commandId'] != command['commandId']) {
          throw const FormatException('Unmatched acknowledgement');
        }
        if (ack['status'] == 'ACCEPTED' ||
            object(ack['error'])['retryable'] != true) {
          await store.write(null);
          return ack;
        }
        if (attempt == 4) return ack;
      } catch (_) {
        if (attempt == 4) rethrow;
      }
      await Future<void>.delayed(Duration(seconds: 1 << attempt));
    }
    throw StateError('Confirmation unavailable');
  }

  @override
  Future<void> history() async {
    if (_closed || _historyLoading || _historyEnded) return;
    _historyLoading = true;
    try {
      final page = await connection.history(store.roomId, _before);
      if (_closed || !ownsSession()) return;
      final entries = page['entries'] as List;
      if (entries.length > 30) throw const FormatException('Oversized history');
      for (final raw in entries) {
        final entry = object(raw);
        final sequence = entry['sequence'] as int;
        final activity = entry['activity'] as List;
        if (sequence < 0 ||
            activity.any((e) => !protocol.accepts('activity', e))) {
          throw const FormatException('Invalid history');
        }
        _history[sequence] = [
          for (final e in activity) (e as Map)['message'] as String,
        ];
      }
      _before = page['nextBefore'] as int?;
      _historyEnded = _before == null;
      _historyStarted = true;
      _emitHistory();
    } catch (_) {
      _emit('message', 'History could not load. Try again when connected.');
    } finally {
      _historyLoading = false;
    }
  }

  void _emitHistory() {
    // Bound memory even for very long matches. Older pages replace the oldest
    // retained window only when explicitly requested by the player.
    final keys = _history.keys.toList()..sort();
    while (_history.length > 300) {
      _history.remove(keys.removeAt(0));
    }
    _emit('history', [for (final key in keys) ...?_history[key]]);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _subscription?.cancel();
    _versionTimer?.cancel();
    _syncTimeout?.cancel();
    _events.close();
  }
}

class LiveGameShell extends ConsumerStatefulWidget {
  const LiveGameShell({
    super.key,
    required this.subject,
    required this.roomId,
    required this.playerId,
  });
  final String subject, roomId, playerId;
  @override
  ConsumerState<LiveGameShell> createState() => _LiveGameShellState();
}

class _LiveGameShellState extends ConsumerState<LiveGameShell> {
  late final LiveGamePort port;
  @override
  void initState() {
    super.initState();
    final connection = ref.read(connectionProvider.notifier);
    port = LiveGamePort(
      connection,
      ref.read(protocolProvider),
      PendingGameStore(widget.subject, widget.roomId, widget.playerId),
      () => connection.subject == widget.subject,
      () => ref.read(connectionProvider).status == ConnectionStatus.connected,
    );
  }

  @override
  void dispose() {
    port.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(connectionProvider, (_, next) => port.status());
    final host = ref.watch(lobbyProvider).isHost;
    return ProviderScope(
      overrides: [
        gamePortProvider.overrideWithValue(port),
        gameProvider.overrideWith(GameController.new),
      ],
      child: GameScreen(
        isHost: host,
        onExit: () => ref.read(lobbyProvider.notifier).dismissClosed(),
        createRematch: host
            ? () async {
                await ref
                    .read(lobbyProvider.notifier)
                    .command('CREATE_REMATCH', {});
                if (!mounted) return Uri();
                final lobby = ref.read(lobbyProvider);
                if (lobby.invitation == null ||
                    lobby.room?['roomId'] == widget.roomId) {
                  throw StateError('Rematch unavailable');
                }
                return Uri(
                  scheme: 'islandtable',
                  host: 'join',
                  queryParameters: {'invite': lobby.invitation},
                );
              }
            : null,
      ),
    );
  }
}
