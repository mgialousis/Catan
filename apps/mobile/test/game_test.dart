import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/core/connection.dart';
import 'package:island_table/core/protocol.dart';
import 'package:island_table/game/board.dart';
import 'package:island_table/game/controller.dart';
import 'package:island_table/game/game_screen.dart';
import 'package:island_table/game/model.dart';

/// Real engine output: these fixtures are produced by the TypeScript engine and
/// already pass the shared draft-07 conformance suite in both languages.
final _fixtures =
    (jsonDecode(
              File(
                '../../packages/protocol/fixtures/contracts.json',
              ).readAsStringSync(),
            )
            as List)
        .cast<Map<String, dynamic>>();
JsonMap _snapshot(String name) =>
    object(_fixtures.firstWhere((f) => f['name'] == name)['value']);
final _protocol = Protocol(
  jsonDecode(File('../../packages/protocol/schemas/v1.json').readAsStringSync())
      as Map<String, dynamic>,
);

class FakePort extends GamePort {
  final _events = StreamController<MapEntry<String, dynamic>>.broadcast();
  final commands = <JsonMap>[];
  final replies = <Completer<JsonMap>>[];
  int synchronized = 0;
  bool closed = false;

  @override
  Stream<MapEntry<String, dynamic>> get events => _events.stream;
  @override
  Future<void> connect() async => emit('connected', true);
  @override
  Future<JsonMap> send(JsonMap command) {
    commands.add(command);
    final reply = Completer<JsonMap>();
    replies.add(reply);
    return reply.future;
  }

  @override
  void synchronize() => synchronized++;
  @override
  void close() {
    closed = true;
    _events.close();
  }

  void emit(String key, Object? value) => _events.add(MapEntry(key, value));
}

Future<FakePort> pumpGame(WidgetTester tester, JsonMap snapshot) async {
  final port = FakePort();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        gamePortProvider.overrideWithValue(port),
        protocolProvider.overrideWithValue(_protocol),
      ],
      child: const MaterialApp(home: GameScreen()),
    ),
  );
  await tester.pump();
  port.emit('connected', true);
  port.emit('snapshot', snapshot);
  await tester.pumpAndSettle();
  return port;
}

/// The multi-view binding keeps semantics on a child pipeline owner.
SemanticsOwner _semanticsOwner(WidgetTester tester) {
  SemanticsOwner? found;
  void consider(SemanticsOwner? candidate) {
    if (candidate?.rootSemanticsNode != null) found ??= candidate;
  }

  consider(tester.binding.rootPipelineOwner.semanticsOwner);
  tester.binding.rootPipelineOwner.visitChildren(
    (child) => consider(child.semanticsOwner),
  );
  return found!;
}

SemanticsNode? _findNode(
  SemanticsNode node,
  bool Function(SemanticsData) test,
) {
  if (test(node.getSemanticsData())) return node;
  SemanticsNode? found;
  node.visitChildren((child) {
    found ??= _findNode(child, test);
    return found == null;
  });
  return found;
}

void main() {
  testWidgets(
    'a real engine snapshot renders the island, roster and owner-only hand',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final snapshot = _snapshot(
        'engine initial 3-player canonical board snapshot',
      );
      await pumpGame(tester, snapshot);

      // The board's header line carries the table's status now, not its name.
      expect(find.textContaining('Turn '), findsWidgets);
      expect(find.byKey(const Key('turn-status-detail')), findsOneWidget);
      expect(find.text('Your hand'), findsOneWidget);
      // Setup phase for the viewing player, so its own prompt and action are offered.
      expect(find.textContaining('starting settlement'), findsOneWidget);
      expect(find.text('Choose settlement'), findsOneWidget);
      for (final player in object(snapshot['publicState'])['players'].values) {
        expect(find.textContaining(player['nickname'] as String), findsWidgets);
      }
    },
  );

  testWidgets(
    'opponent rows expose counts only; no opponent resource type is rendered',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final snapshot = _snapshot(
        'engine completed 4-player winner reveal snapshot',
      );
      final viewer = object(snapshot['privateState'])['playerId'] as String;
      await pumpGame(tester, snapshot);

      // The delivered snapshot carries exactly one private hand: the viewer's own.
      expect(object(snapshot['privateState'])['playerId'], viewer);

      final semantics = tester.widgetList<Semantics>(find.byType(Semantics));
      final opponentLabels = semantics
          .map((s) => s.properties.label)
          .whereType<String>()
          .where(
            (label) =>
                label.contains('resource cards') &&
                !label.contains('Your resources'),
          )
          .toList();
      expect(opponentLabels, isNotEmpty);
      for (final label in opponentLabels) {
        for (final resource in resourceTypes) {
          expect(
            label.toLowerCase().contains(resource),
            isFalse,
            reason:
                'a public player summary must never name a resource type: $label',
          );
        }
      }
    },
  );

  testWidgets(
    'duplicate taps stay a single pending intent until the table replies',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Only the phase is retargeted; the payload remains schema-valid engine output.
      final snapshot = _snapshot(
        'engine initial 3-player canonical board snapshot',
      );
      final public = object(snapshot['publicState']);
      public['phase'] = 'AWAIT_ROLL';
      snapshot['publicState'] = public;
      final port = await pumpGame(tester, snapshot);

      expect(find.text('Roll dice'), findsOneWidget);
      await tester.tap(find.text('Roll dice'));
      await tester.pump();
      await tester.tap(find.text('Roll dice'), warnIfMissed: false);
      await tester.pump();
      expect(port.commands.length, 1);
      expect(port.commands.single['type'], 'ROLL_DICE');
      expect(find.textContaining('Waiting for the table'), findsOneWidget);

      port.replies.single.complete({
        'commandId': port.commands.single['commandId'],
        'status': 'REJECTED',
        'error': {'code': 'NOT_YOUR_TURN', 'message': 'x', 'retryable': false},
      });
      await tester.pumpAndSettle();
      expect(find.text('Wait for your turn.'), findsOneWidget);
    },
  );

  testWidgets(
    'a finished game reveals the winner, final points and card count',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final snapshot = _snapshot(
        'engine completed 4-player winner reveal snapshot',
      );
      await pumpGame(tester, snapshot);

      expect(find.text('You won!'), findsOneWidget);
      expect(
        find.textContaining('Revealed victory point cards: 4'),
        findsOneWidget,
      );
      // A finished table offers no gameplay action.
      expect(find.text('End turn'), findsNothing);
      expect(find.text('Roll dice'), findsNothing);
    },
  );

  // P4.10 device matrix: supported phone widths, both orientations, and text
  // scales up to the largest ordinary accessibility setting.
  const devices = <String, Size>{
    'iPhone SE': Size(320, 568),
    'Pixel': Size(360, 800),
    'iPhone mini': Size(375, 812),
    'iPhone Pro Max': Size(430, 932),
    'landscape phone': Size(812, 375),
  };
  for (final device in devices.entries) {
    for (final scale in const [1.0, 1.3, 2.0]) {
      testWidgets(
        '${device.key} at ${scale}x text scrolls the whole game without overflow',
        (tester) async {
          tester.view.physicalSize = device.value;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final port = FakePort();
          addTearDown(port.close);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                gamePortProvider.overrideWithValue(port),
                protocolProvider.overrideWithValue(_protocol),
              ],
              child: MediaQuery(
                data: MediaQueryData(
                  size: device.value,
                  textScaler: TextScaler.linear(scale),
                ),
                child: const MaterialApp(home: GameScreen()),
              ),
            ),
          );
          await tester.pump();
          port.emit('connected', true);
          port.emit(
            'snapshot',
            _snapshot('engine completed 4-player winner reveal snapshot'),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'first screen of ${device.key}',
          );

          // Walk the entire page; an overflow anywhere below the fold still fails.
          final scrollable = find.byType(Scrollable).first;
          for (var step = 0; step < 12; step++) {
            await tester.drag(scrollable, const Offset(0, -320));
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '${device.key} at ${scale}x, scroll step $step',
            );
          }
        },
      );
    }
  }

  testWidgets('a narrow phone at enlarged text scale lays out without overflow', (
    tester,
  ) async {
    // Smallest supported width class, with the largest ordinary accessibility scale.
    tester.view.physicalSize = const Size(320, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final snapshot = _snapshot(
      'engine completed 4-player winner reveal snapshot',
    );
    final port = FakePort();
    addTearDown(port.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gamePortProvider.overrideWithValue(port),
          protocolProvider.overrideWithValue(_protocol),
        ],
        child: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: const MaterialApp(home: GameScreen()),
        ),
      ),
    );
    await tester.pump();
    port.emit('connected', true);
    port.emit('snapshot', snapshot);
    await tester.pumpAndSettle();

    // A ListView only builds what is on screen, so scroll the whole page and
    // assert no section overflows on the way down.
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Your hand'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Your hand'), findsOneWidget);
  });

  testWidgets(
    'a board target is selectable through the accessibility tree and confirms one command',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final handle = tester.ensureSemantics();
      final port = await pumpGame(
        tester,
        _snapshot('engine initial 3-player canonical board snapshot'),
      );

      await tester.tap(find.text('Choose settlement'));
      await tester.pumpAndSettle();

      // The painter publishes one tappable node per legal placement.
      final owner = _semanticsOwner(tester);
      final target = _findNode(
        owner.rootSemanticsNode!,
        (data) => data.label.startsWith('Select Junction'),
      );
      expect(
        target,
        isNotNull,
        reason: 'legal placements must be reachable without sight',
      );
      owner.performAction(target!.id, SemanticsAction.tap);
      await tester.pumpAndSettle();

      expect(find.textContaining('Selected Junction'), findsOneWidget);
      // The pending spinner animates until the table replies, so settle would hang.
      await tester.tap(find.text('Confirm placement'));
      await tester.pump();

      expect(port.commands.length, 1);
      expect(port.commands.single['type'], 'PLACE_SETUP_SETTLEMENT');
      expect(port.commands.single['payload'], contains('vertexId'));
      // The end-of-test verification runs before tearDown, so release it here.
      handle.dispose();
    },
  );

  testWidgets(
    'the island fits a height-constrained parent without overflowing',
    (tester) async {
      tester.view.physicalSize = const Size(760, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 400,
              child: IslandBoard(
                snapshot: GameSnapshot.parse(
                  _snapshot('engine initial 3-player canonical board snapshot'),
                  _protocol,
                ),
                onTarget: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  test('a stale snapshot never rolls the view backwards', () {
    final port = FakePort();
    addTearDown(port.close);
    final container = ProviderContainer(
      overrides: [
        gamePortProvider.overrideWithValue(port),
        protocolProvider.overrideWithValue(_protocol),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(gameProvider.notifier);
    final newer = _snapshot('engine completed 4-player winner reveal snapshot');
    final older = _snapshot('engine completed 4-player winner reveal snapshot');
    older['version'] = (newer['version'] as int) - 1;

    controller.state = controller.state.copy(
      snapshot: GameSnapshot.parse(newer, _protocol),
      connected: true,
    );
    port.emit('snapshot', older);
    expect(container.read(gameProvider).snapshot!.version, newer['version']);
  });
}
