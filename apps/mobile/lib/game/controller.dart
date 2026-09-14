import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/connection.dart';
import 'model.dart';

abstract class GamePort {
  Stream<MapEntry<String, dynamic>> get events;
  Future<void> connect();
  Future<JsonMap> send(JsonMap command);
  void synchronize();
  void close();
  Future<void> history() async {}
}

final gamePortProvider = Provider<GamePort>(
  (ref) => throw StateError('A game transport is required'),
);
final gameProvider = NotifierProvider<GameController, GameView>(
  GameController.new,
);

class GameView {
  const GameView({
    this.snapshot,
    this.connected = false,
    this.pending,
    this.sending = false,
    this.message,
    this.activity = const [],
    this.drawnCard,
    this.selection,
    this.target,
    this.setupVertex,
    this.serverTime,
    this.rollGains,
  });
  final GameSnapshot? snapshot;
  final bool connected, sending;
  final JsonMap? pending;
  final String? message, drawnCard, selection, target, setupVertex, serverTime;
  final List<ActivityEntry> activity;

  /// Actual owner-hand changes across a single, observed dice-roll command.
  final Map<String, int>? rollGains;
  bool get locked =>
      !connected ||
      pending != null ||
      snapshot == null ||
      snapshot!.paused ||
      snapshot!.complete;
  GameView copy({
    GameSnapshot? snapshot,
    bool? connected,
    JsonMap? pending,
    bool clearPending = false,
    bool? sending,
    String? message,
    bool clearMessage = false,
    List<ActivityEntry>? activity,
    String? drawnCard,
    bool clearDraw = false,
    String? selection,
    String? target,
    bool clearSelection = false,
    String? setupVertex,
    String? serverTime,
    Map<String, int>? rollGains,
    bool clearRollGains = false,
  }) => GameView(
    snapshot: snapshot ?? this.snapshot,
    connected: connected ?? this.connected,
    pending: clearPending ? null : pending ?? this.pending,
    sending: sending ?? this.sending,
    message: clearMessage ? null : message ?? this.message,
    activity: activity ?? this.activity,
    drawnCard: clearDraw ? null : drawnCard ?? this.drawnCard,
    selection: clearSelection ? null : selection ?? this.selection,
    target: clearSelection ? null : target ?? this.target,
    setupVertex: setupVertex ?? this.setupVertex,
    serverTime: serverTime ?? this.serverTime,
    rollGains: clearRollGains ? null : rollGains ?? this.rollGains,
  );
}

class GameController extends Notifier<GameView> {
  late GamePort _port;
  bool _disposed = false;
  int? _acceptedVersion;
  @override
  GameView build() {
    _port = ref.read(gamePortProvider);
    final sub = _port.events.listen(_event);
    ref.onDispose(() {
      _disposed = true;
      sub.cancel();
      _port.close();
    });
    return const GameView();
  }

  Future<void> connect() async {
    try {
      await _port.connect();
    } catch (_) {
      if (!_disposed) {
        state = state.copy(
          connected: false,
          message: 'Could not connect. Your table is waiting.',
        );
      }
    }
  }

  void synchronize() => _port.synchronize();
  Future<void> loadHistory() => _port.history();
  void _event(MapEntry<String, dynamic> event) {
    if (_disposed) return;
    switch (event.key) {
      case 'connected':
        final wasConnected = state.connected;
        state = state.copy(connected: event.value == true);
        if (event.value == true && !wasConnected) _port.synchronize();
      case 'snapshot':
        try {
          final next = GameSnapshot.parse(
            event.value,
            ref.read(protocolProvider),
          );
          final old = state.snapshot;
          if (old != null &&
              (next.roomId != old.roomId || next.playerId != old.playerId)) {
            state = state.copy(
              connected: false,
              message: 'The received table does not belong to this session.',
            );
            return;
          }
          if (old != null && next.version < old.version) return;
          final changed =
              old == null ||
              next.version != old.version ||
              next.phaseId != old.phaseId;
          final observedRoll =
              old != null &&
              next.version == old.version + 1 &&
              next.public['turnNumber'] == old.public['turnNumber'] &&
              old.public['hasRolled'] == false &&
              next.public['hasRolled'] == true;
          final gains = observedRoll
              ? {
                  for (final r in resourceTypes)
                    r: next.stock[r]! - old.stock[r]!,
                }
              : null;
          state = state.copy(
            snapshot: next,
            serverTime: next.json['serverTime'] as String,
            clearSelection: changed,
            clearPending:
                _acceptedVersion != null && next.version >= _acceptedVersion!,
            clearMessage: state.pending == null,
            rollGains: gains,
            clearRollGains:
                !observedRoll &&
                (old == null ||
                    next.public['turnNumber'] != old.public['turnNumber']),
          );
          if (state.pending == null) _acceptedVersion = null;
        } catch (_) {
          state = state.copy(
            connected: false,
            message:
                'This game update is incompatible. Reconnect to synchronize.',
          );
        }
      case 'restoreIntent':
        if (state.pending == null &&
            ref.read(protocolProvider).accepts('gameCommand', event.value)) {
          state = state.copy(pending: object(event.value));
          unawaited(retry());
        }
      case 'revoked':
        _acceptedVersion = null;
        state = const GameView(
          message: 'Your session changed. Reconnect to your table.',
        );
      case 'clock':
        state = state.copy(serverTime: event.value as String);
      case 'message':
        state = state.copy(message: event.value as String);
      case 'history':
        state = state.copy(
          activity: (event.value as List).cast<ActivityEntry>(),
        );
      case 'activity':
        final entries = (event.value as List).cast<ActivityEntry>();
        state = state.copy(
          activity: [
            ...state.activity,
            ...entries,
          ].reversed.take(100).toList().reversed.toList(),
        );
      case 'draw':
        state = state.copy(drawnCard: event.value as String);
    }
  }

  void select(String command) {
    if (state.locked) return;
    state = state.copy(clearSelection: true, clearMessage: true);
    state = state.copy(selection: command);
  }

  void target(String id) {
    final s = state.snapshot;
    if (state.locked ||
        s == null ||
        state.selection == null ||
        !s
            .targets(state.selection!, pendingSetupVertex: state.setupVertex)
            .contains(id)) {
      return;
    }
    state = state.copy(target: id);
  }

  void cancelSelection() => state = state.copy(clearSelection: true);
  void clearFeedback() =>
      state = state.copy(clearDraw: true, clearMessage: true);
  Future<void> confirmTarget() async {
    final type = state.selection, id = state.target;
    if (type == null || id == null) return;
    final key = type == 'MOVE_ROBBER'
        ? 'hexId'
        : type.contains('ROAD')
        ? 'edgeId'
        : 'vertexId';
    await command(type, {key: id});
  }

  Future<void> command(
    String type, [
    JsonMap payload = const {},
    GameSnapshot? basedOn,
  ]) async {
    final sessionCommand = [
      'PAUSE_GAME',
      'RESUME_GAME',
      'ABANDON_GAME',
    ].contains(type);
    if (state.snapshot == null ||
        !state.connected ||
        state.pending != null ||
        state.snapshot!.complete ||
        (!sessionCommand && state.locked)) {
      return;
    }
    final s = state.snapshot!;
    if (basedOn != null &&
        (basedOn.roomId != s.roomId ||
            basedOn.playerId != s.playerId ||
            basedOn.version != s.version ||
            basedOn.phaseId != s.phaseId)) {
      state = state.copy(
        message:
            'The table changed while you were choosing. Review it and choose again.',
      );
      return;
    }
    final intent = <String, dynamic>{
      'protocolVersion': 1,
      'commandId': const Uuid().v4(),
      'roomId': s.roomId,
      'expectedVersion': s.version,
      'expectedPhaseId': s.phaseId,
      'type': type,
      'payload': payload,
    };
    if (!ref.read(protocolProvider).accepts('gameCommand', intent)) {
      state = state.copy(message: 'Check the selected resources and choices.');
      return;
    }
    state = state.copy(
      pending: intent,
      clearMessage: true,
      clearSelection: true,
    );
    await retry();
  }

  Future<void> retry() async {
    if (state.pending == null || state.sending || !state.connected) return;
    final intent = state.pending!;
    state = state.copy(sending: true);
    try {
      final ack = await _port.send(intent);
      if (_disposed) return;
      if (ack['commandId'] != intent['commandId']) {
        throw const FormatException('Unmatched reply');
      }
      if (ack['status'] == 'ACCEPTED') {
        _acceptedVersion = ack['version'] as int;
        final settled = (state.snapshot?.version ?? -1) >= _acceptedVersion!;
        state = state.copy(
          sending: false,
          clearPending: settled,
          clearMessage: true,
          setupVertex: intent['type'] == 'PLACE_SETUP_SETTLEMENT'
              ? intent['payload']['vertexId'] as String
              : null,
        );
        if (settled) {
          _acceptedVersion = null;
        } else {
          _port.synchronize();
        }
      } else {
        final error = object(ack['error']);
        state = state.copy(
          sending: false,
          clearPending: error['retryable'] != true,
          message: gameError(error['code'] as String),
        );
        _port.synchronize();
      }
    } catch (_) {
      if (!_disposed) {
        state = state.copy(
          sending: false,
          message:
              'Waiting for confirmation. Retry this same action when connected.',
        );
      }
    }
  }
}

String gameError(String code) => switch (code) {
  'STALE_VERSION' || 'WRONG_PHASE' =>
    'The table changed. Review the latest position and choose again.',
  'NOT_YOUR_TURN' => 'Wait for your turn.',
  'ILLEGAL_PLACEMENT' =>
    'That location is no longer available. Choose another.',
  'INSUFFICIENT_RESOURCES' => 'You do not have the resources for that action.',
  'BANK_UNAVAILABLE' =>
    'The bank cannot supply that choice. Try different resources.',
  'CARD_NOT_PLAYABLE' =>
    'That card cannot be used now. Check its timing and available placements.',
  'TRADE_UNAVAILABLE' =>
    'This offer is no longer available. Ask for a new offer.',
  'DEADLINE_EXCEEDED' =>
    'Time is up. The server is resolving the required action.',
  'PLAYERS_NOT_READY' =>
    'A required player is still offline. Wait for them to return.',
  'GAME_PAUSED' =>
    'The table is paused. Actions resume when everyone is ready.',
  'GAME_FINISHED' => 'This game has finished.',
  _ =>
    'The action could not be completed. Synchronize the table and try again.',
};
