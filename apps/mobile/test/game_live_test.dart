import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:island_table/core/connection.dart';
import 'package:island_table/core/protocol.dart';
import 'package:island_table/game/controller.dart';
import 'package:island_table/game/delta.dart';
import 'package:island_table/game/live.dart';
import 'package:island_table/game/model.dart';
import 'package:island_table/game/pending.dart';
import 'game_model_test.dart' show uiProtocol;

final fixtures =
    (jsonDecode(
              File(
                '../../packages/protocol/fixtures/game-deltas.json',
              ).readAsStringSync(),
            )
            as List)
        .cast<Map>();
final activeFixture = fixtures.firstWhere(
  (f) =>
      f['before']['privateState']['playerId'] ==
      f['before']['publicState']['activePlayerId'],
);

class MemoryStore extends PendingGameStore {
  MemoryStore(String room, String player) : super('subject', room, player);
  JsonMap? saved;
  bool fail = false;
  @override
  Future<JsonMap?> read(Protocol protocol) async => saved;
  @override
  Future<void> write(JsonMap? intent) async {
    if (fail) throw StateError('Disk full');
    saved = intent;
  }
}

class Connection extends ConnectionController {
  final stream = StreamController<MapEntry<String, dynamic>>.broadcast(
    sync: true,
  );
  @override
  Stream<MapEntry<String, dynamic>> get events => stream.stream;
  final sent = <JsonMap>[];
  final syncs = <int?>[];
  Future<JsonMap> Function(JsonMap)? respond;
  @override
  void syncGame(String roomId, int? version) => syncs.add(version);
  @override
  void checkGameVersion(String roomId) {}
  @override
  Future<JsonMap> history(String roomId, int? before) async => {
    'entries': [],
    'nextBefore': null,
  };
  @override
  Future<JsonMap> sendCommand(JsonMap command) {
    sent.add(command);
    return respond!(command);
  }

  void emit(String key, Object? value) => stream.add(MapEntry(key, value));
}

JsonMap intent(GameSnapshot snapshot) => {
  'protocolVersion': 1,
  'commandId': const Uuid().v4(),
  'roomId': snapshot.roomId,
  'expectedVersion': snapshot.version,
  'expectedPhaseId': snapshot.phaseId,
  'type': 'PLACE_SETUP_SETTLEMENT',
  'payload': {'vertexId': snapshot.targets('PLACE_SETUP_SETTLEMENT').first},
};
JsonMap ack(JsonMap command, int version) => {
  'commandId': command['commandId'],
  'status': 'ACCEPTED',
  'scope': 'GAME',
  'roomId': command['roomId'],
  'version': version,
  'serverTime': '2026-09-10T12:00:00.000Z',
};
void main() {
  for (final fixture in fixtures) {
    test(
      'TypeScript delta reconstructs the exact Dart owner view: ${fixture['name']}',
      () {
        final before = GameSnapshot.parse(fixture['before'], uiProtocol);
        final after = applyDelta(before, fixture['delta'], uiProtocol);
        expect(after.json, fixture['after']);
        expect(before.json, fixture['before']);
      },
    );
  }
  test(
    'patch gaps, wrong rooms, unsafe paths and partial private changes fail atomically',
    () {
      final f = activeFixture,
          before = GameSnapshot.parse(f['before'], uiProtocol),
          original = jsonEncode(before.json);
      for (final change in [
        {'fromVersion': 99},
        {'roomId': const Uuid().v4()},
        {'toVersion': 9},
        {
          'privatePatch': [
            {'op': 'replace', 'path': '/playerId', 'value': const Uuid().v4()},
          ],
        },
        {
          'publicPatch': [
            {'op': 'add', 'path': '/__proto__/x', 'value': 1},
          ],
        },
        {
          'privatePatch': [
            {'op': 'replace', 'path': '/resources/ore', 'value': -1},
          ],
        },
      ]) {
        expect(
          () => applyDelta(before, {
            ...object(f['delta']),
            ...change,
          }, uiProtocol),
          throwsFormatException,
        );
        expect(jsonEncode(before.json), original);
      }
    },
  );
  testWidgets(
    'reload synchronizes first, then resolves the saved original ID',
    (t) async {
      final f = activeFixture,
          before = GameSnapshot.parse(f['before'], uiProtocol);
      final connection = Connection(),
          store = MemoryStore(before.roomId, before.playerId);
      final saved = intent(before);
      store.saved = saved;
      final port = LiveGamePort(
        connection,
        uiProtocol,
        store,
        () => true,
        () => true,
      );
      final container = ProviderContainer(
        overrides: [
          gamePortProvider.overrideWithValue(port),
          protocolProvider.overrideWithValue(uiProtocol),
        ],
      );
      addTearDown(() {
        container.dispose();
        connection.stream.close();
      });
      connection.respond = (c) async => ack(c, before.version + 1);
      final controller = container.read(gameProvider.notifier);
      await controller.connect();
      expect(connection.syncs, [null]);
      expect(connection.sent, isEmpty);
      connection.emit('game.snapshot', f['before']);
      await t.pump();
      expect(connection.sent.single, saved);
      expect(container.read(gameProvider).pending, saved);
      connection.emit('game.delta', f['delta']);
      await t.pump();
      expect(container.read(gameProvider).pending, isNull);
      expect(store.saved, isNull);
      expect(container.read(gameProvider).snapshot!.json, f['after']);
      container.dispose();
    },
  );
  testWidgets(
    'bounded retries reuse exactly one saved command and stop after five attempts',
    (t) async {
      final before = GameSnapshot.parse(activeFixture['before'], uiProtocol),
          connection = Connection();
      final store = MemoryStore(before.roomId, before.playerId),
          cmd = intent(before);
      final port = LiveGamePort(
        connection,
        uiProtocol,
        store,
        () => true,
        () => true,
      );
      addTearDown(() {
        port.close();
        connection.stream.close();
      });
      connection.respond = (c) async {
        expectSync(store.saved, c);
        throw TimeoutException('lost');
      };
      Object? failure;
      final result = port.send(cmd).catchError((Object e) {
        failure = e;
        return <String, dynamic>{};
      });
      await t.pump();
      expect(connection.sent.length, 1);
      for (final seconds in [1, 2, 4, 8]) {
        await t.pump(Duration(seconds: seconds));
      }
      await result;
      expect(failure, isA<TimeoutException>());
      expect(connection.sent.length, 5);
      expect(
        connection.sent.every((c) => c['commandId'] == cmd['commandId']),
        isTrue,
      );
      expect(store.saved, cmd);
      await t.pump(const Duration(seconds: 60));
      expect(connection.sent.length, 5);
    },
  );
  testWidgets(
    'duplicate updates are ignored, gaps sync once and identity changes erase private state',
    (t) async {
      final f = activeFixture,
          before = GameSnapshot.parse(f['before'], uiProtocol),
          connection = Connection();
      final store = MemoryStore(before.roomId, before.playerId);
      bool owner = true;
      final port = LiveGamePort(
        connection,
        uiProtocol,
        store,
        () => owner,
        () => true,
      );
      final container = ProviderContainer(
        overrides: [
          gamePortProvider.overrideWithValue(port),
          protocolProvider.overrideWithValue(uiProtocol),
        ],
      );
      addTearDown(() {
        container.dispose();
        connection.stream.close();
      });
      await container.read(gameProvider.notifier).connect();
      connection.emit('game.snapshot', f['before']);
      await t.pump();
      connection.emit('game.delta', f['delta']);
      connection.emit('game.delta', f['delta']);
      await t.pump();
      expect(
        container.read(gameProvider).snapshot!.version,
        before.version + 1,
      );
      connection.syncs.clear();
      connection.emit('game.version', {'roomId': before.roomId, 'version': 99});
      connection.emit('game.version', {'roomId': before.roomId, 'version': 99});
      expect(connection.syncs.length, 1);
      store.saved = intent(before);
      owner = false;
      port.status();
      await t.pump();
      expect(container.read(gameProvider).snapshot, isNull);
      expect(store.saved, isNull);
      expect(container.read(gameProvider).connected, isFalse);
    },
  );
  testWidgets(
    'database error holds controls until an authoritative snapshot, even at the same version',
    (t) async {
      final f = activeFixture,
          before = GameSnapshot.parse(f['before'], uiProtocol),
          connection = Connection();
      final port = LiveGamePort(
        connection,
        uiProtocol,
        MemoryStore(before.roomId, before.playerId),
        () => true,
        () => true,
      );
      final container = ProviderContainer(
        overrides: [
          gamePortProvider.overrideWithValue(port),
          protocolProvider.overrideWithValue(uiProtocol),
        ],
      );
      addTearDown(() {
        container.dispose();
        connection.stream.close();
      });
      await container.read(gameProvider.notifier).connect();
      connection.emit('game.snapshot', f['before']);
      await t.pump();
      connection.emit('session.error', {'code': 'SERVICE_UNAVAILABLE'});
      port.status();
      await t.pump();
      expect(container.read(gameProvider).connected, isFalse);
      connection.syncs.clear();
      connection.emit('game.version', {
        'roomId': before.roomId,
        'version': before.version,
        'serverTime': '2026-09-11T12:00:00Z',
      });
      expect(connection.syncs, isNotEmpty);
      expect(container.read(gameProvider).connected, isFalse);
      connection.emit('game.snapshot', f['before']);
      await t.pump();
      expect(container.read(gameProvider).connected, isTrue);
      container.dispose();
    },
  );
  test('storage failure never sends an unrecorded command', () async {
    final before = GameSnapshot.parse(activeFixture['before'], uiProtocol),
        connection = Connection();
    final store = MemoryStore(before.roomId, before.playerId)..fail = true;
    final port = LiveGamePort(
      connection,
      uiProtocol,
      store,
      () => true,
      () => true,
    );
    await expectLater(port.send(intent(before)), throwsStateError);
    expect(connection.sent, isEmpty);
    port.close();
    await connection.stream.close();
  });
}
