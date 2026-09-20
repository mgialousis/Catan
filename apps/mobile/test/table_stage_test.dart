import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/game/model.dart';
import 'package:island_table/game/board.dart';
import 'package:island_table/game/roll_presentation.dart';
import 'package:island_table/game/table_stage.dart';
import 'game_model_test.dart' show uiProtocol, uiSnapshot;
import 'board_rendering_test.dart' show boardPictures;

({
  GameSnapshot before,
  GameSnapshot after,
  List<ActivityEntry> activity,
  String hex,
})
rollFixture() {
  final json = uiSnapshot('action');
  final p = json['publicState'] as Map;
  final hexes = p['board']['hexes'] as Map;
  final hex = hexes.keys.firstWhere((id) => hexes[id]['number'] == 5) as String;
  final vertices = hexes[hex]['vertexIds'] as List;
  final ids = (p['players'] as Map).keys.toList();
  p['buildings'] = {
    vertices[0]: {'ownerPlayerId': ids[0], 'type': 'CITY'},
    vertices[2]: {'ownerPlayerId': ids[1], 'type': 'SETTLEMENT'},
  };
  p['robberHexId'] = hexes.keys.firstWhere(
    (id) => hexes[id]['terrain'] == 'DESERT',
  );
  p['hasRolled'] = false;
  p['dice'] = null;
  p['phase'] = 'AWAIT_ROLL';
  final before = GameSnapshot.parse(json, uiProtocol);
  json['version']++;
  p['hasRolled'] = true;
  p['dice'] = [2, 3];
  p['phase'] = 'ACTION';
  final after = GameSnapshot.parse(json, uiProtocol);
  final resource = terrainResources[hexes[hex]['terrain']]!;
  return (
    before: before,
    after: after,
    hex: hex,
    activity: [
      for (var i = 0; i < 2; i++)
        ActivityEntry(
          sequence: after.version,
          type: 'RESOURCES_COLLECTED',
          message: 'Collected resources from the roll.',
          actorPlayerId: ids[i] as String,
          resources: {...resources(), resource: i == 0 ? 2 : 1},
        ),
    ],
  );
}

void main() {
  for (final textScale in [1.0, 1.6]) {
    testWidgets(
      'dice stay centered on the map viewport after zoom and pan at $textScale text',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final f = rollFixture();
        var snapshot = f.before;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 70, 12, 0),
                    child: StatefulBuilder(
                      builder: (context, setState) {
                        update = setState;
                        return TableStage(
                          snapshot: snapshot,
                          activity: f.activity,
                          onTarget: (_) {},
                          onPlayer: (_) {},
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final controller = tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController!;
        controller.value = Matrix4.identity()
          ..translateByDouble(-80, -35, 0, 1)
          ..scaleByDouble(1.7, 1.7, 1, 1);
        await tester.pumpAndSettle();
        update(() => snapshot = f.after);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        final viewport = find
            .descendant(
              of: find.byType(IslandBoard),
              matching: find.byType(ClipRRect),
            )
            .first;
        final delta =
            tester.getCenter(find.byKey(const Key('roll-dice-overlay'))) -
            tester.getCenter(viewport);
        expect(
          delta.distance,
          lessThan(1),
          reason:
              'Use the actual panel size and the untransformed map viewport.',
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
  test(
    'flights use actual payouts, city counts, and the correct recipients',
    () {
      final f = rollFixture();
      final flights = resourceFlights(f.after, f.activity);
      expect(flights.length, 3);
      expect(flights.every((flight) => flight.hexId == f.hex), isTrue);
      expect(
        flights
            .where((flight) => flight.playerId == f.activity[0].actorPlayerId)
            .length,
        2,
      );
      expect(
        flights
            .where((flight) => flight.playerId == f.activity[1].actorPlayerId)
            .length,
        1,
      );
      final shortage = [
        ActivityEntry(
          sequence: f.after.version,
          type: 'RESOURCES_COLLECTED',
          message: '',
          actorPlayerId: f.activity[0].actorPlayerId,
          resources: {
            for (final e in f.activity[0].resources!.entries)
              e.key: e.value > 0 ? 1 : 0,
          },
        ),
      ];
      expect(resourceFlights(f.after, shortage).length, 1);
      expect(resourceFlights(f.after, []), isEmpty);
      expect(resourceFlights(f.before, f.activity), isEmpty);
      // A redelivered activity page must not duplicate an award.
      expect(
        resourceFlights(f.after, [...f.activity, ...f.activity]).length,
        3,
      );
    },
  );

  for (final reduced in [false, true]) {
    testWidgets(
      'roll sequence, camera and touch cancellation; reduced=$reduced',
      (tester) async {
        tester.view.physicalSize = const Size(390, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final f = rollFixture();
        var snapshot = f.before;
        var activity = <ActivityEntry>[];
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) {
                    update = setState;
                    return TableStage(
                      snapshot: snapshot,
                      activity: activity,
                      onTarget: (_) {},
                      onPlayer: (_) {},
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('roll-dice-overlay')), findsNothing);
        final artwork = boardPictures(tester).take(2).toList();
        final transform = tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController!;
        update(() {
          snapshot = f.after;
          activity = f.activity;
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byKey(const Key('roll-dice-overlay')), findsOneWidget);
        expect(find.text('2 + 3 = 5'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 1900));
        expect(
          find.byKey(const Key('roll-dice-overlay')),
          findsOneWidget,
          reason: 'The result stays visible one second longer than build 17.',
        );
        await tester.pump(const Duration(milliseconds: 1000));
        expect(find.byKey(const Key('roll-dice-overlay')), findsNothing);
        expect(
          boardPictures(tester).take(2),
          orderedEquals(artwork),
          reason:
              'Dice, camera movement and flying resources reuse the terrain and pieces.',
        );
        if (reduced) {
          expect(transform.value.getMaxScaleOnAxis(), 1);
          expect(find.byKey(const ValueKey('resource-flight-0')), findsNothing);
        } else {
          expect(transform.value.getMaxScaleOnAxis(), greaterThan(1));
          expect(
            find.byKey(const ValueKey('resource-flight-0')),
            findsOneWidget,
          );
          final original = transform.value.clone();
          await tester.tapAt(tester.getCenter(find.byType(InteractiveViewer)));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('resource-flight-0')), findsNothing);
          expect(
            transform.value,
            original,
            reason: 'A touch takes over the current camera without a snap.',
          );
        }
        update(() => activity = [...f.activity]);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('roll-dice-overlay')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a superseded roll is dropped, never replayed late', (
    tester,
  ) async {
    final f = rollFixture();
    var snapshot = f.before;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return TableStage(
                  snapshot: snapshot,
                  activity: f.activity,
                  onTarget: (_) {},
                  onPlayer: (_) {},
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    update(() => snapshot = f.after);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final next = object(jsonDecode(jsonEncode(f.before.json)));
    next['version'] = f.after.version + 1;
    next['publicState']['turnNumber']++;
    update(() => snapshot = GameSnapshot.parse(next, uiProtocol));
    await tester.pump();
    expect(find.text('2 + 3 = 5'), findsOneWidget);
    next['version']++;
    next['publicState']['hasRolled'] = true;
    next['publicState']['dice'] = [3, 3];
    next['publicState']['phase'] = 'ACTION';
    update(() => snapshot = GameSnapshot.parse(next, uiProtocol));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('3 + 3 = 6'), findsOneWidget);
    // The overtaken roll is gone for good; it must not surface again once the
    // newer presentation finishes, minutes behind the table it describes.
    await tester.pump(const Duration(milliseconds: 7000));
    expect(find.text('2 + 3 = 5'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('roll-dice-overlay')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late payouts fly for one second each, strictly one at a time', (
    tester,
  ) async {
    final f = rollFixture();
    var snapshot = f.before;
    var activity = <ActivityEntry>[];
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return TableStage(
                  snapshot: snapshot,
                  activity: activity,
                  onTarget: (_) {},
                  onPlayer: (_) {},
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    update(() => snapshot = f.after);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    update(() => activity = f.activity);
    await tester.pump();
    expect(
      find.text('2 + 3 = 5'),
      findsOneWidget,
      reason: 'Receiving payout data must not restart the dice animation.',
    );
    final icons = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('resource-flight-'),
    );
    await tester.pump(const Duration(milliseconds: 2400));
    final transform = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    final focus = transform.value.clone();
    for (var index = 0; index < 3; index++) {
      expect(icons, findsOneWidget);
      expect(find.byKey(ValueKey('resource-flight-$index')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 900));
      expect(
        icons,
        findsOneWidget,
        reason: 'The current icon is still flying after 900 ms.',
      );
      expect(find.byKey(ValueKey('resource-flight-$index')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        icons,
        findsNothing,
        reason: 'There is a short pause after each delivery.',
      );
      expect(
        transform.value,
        focus,
        reason: 'Keep focus until every resource arrives.',
      );
      if (index < 2) await tester.pump(const Duration(milliseconds: 160));
    }
    await tester.pumpAndSettle();
    expect(transform.value.getMaxScaleOnAxis(), 1);
    expect(icons, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'completed rolls and reconnect gaps do not replay; fresh roll restores camera',
    (tester) async {
      final f = rollFixture();
      var snapshot = f.after;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return TableStage(
                    snapshot: snapshot,
                    activity: f.activity,
                    onTarget: (_) {},
                    onPlayer: (_) {},
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('roll-dice-overlay')), findsNothing);
      update(() => snapshot = f.before);
      await tester.pump();
      final gap = uiSnapshot('action');
      gap['version'] = f.before.version + 3;
      update(() => snapshot = GameSnapshot.parse(gap, uiProtocol));
      await tester.pump();
      expect(find.byKey(const Key('roll-dice-overlay')), findsNothing);
      update(() => snapshot = f.before);
      await tester.pump();
      update(() => snapshot = f.after);
      await tester.pump();
      await tester.pumpAndSettle();
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1);
      expect(find.byKey(const Key('roll-dice-overlay')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  /// Bug: your own roll never animated. A bot presentation was usually still
  /// running when your turn came, so your roll went into a queue behind it --
  /// and the first board touch to build cleared that queue. The newest roll is
  /// the one worth watching, so it takes over immediately.
  testWidgets('your own roll takes over a running bot presentation', (
    tester,
  ) async {
    final f = rollFixture();
    var snapshot = f.before;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return TableStage(
                  snapshot: snapshot,
                  activity: f.activity,
                  onTarget: (_) {},
                  onPlayer: (_) {},
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // A bot rolls, and its presentation is still on screen.
    update(() => snapshot = f.after);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('2 + 3 = 5'), findsOneWidget);
    // The bot ends its turn and you roll, all while that is still showing.
    final mine = object(jsonDecode(jsonEncode(f.before.json)));
    mine['version'] = f.after.version + 1;
    mine['publicState']['turnNumber']++;
    update(() => snapshot = GameSnapshot.parse(mine, uiProtocol));
    await tester.pump();
    mine['version']++;
    mine['publicState']['hasRolled'] = true;
    mine['publicState']['dice'] = [3, 3];
    mine['publicState']['phase'] = 'ACTION';
    update(() => snapshot = GameSnapshot.parse(mine, uiProtocol));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      find.text('3 + 3 = 6'),
      findsOneWidget,
      reason:
          'Your roll must be shown when it happens, not minutes of bot '
          'presentations later.',
    );
    expect(find.text('2 + 3 = 5'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('roll-dice-overlay')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  /// Bug: the cyan production rings read the live snapshot while the dice
  /// overlay showed an older roll, so the two disagreed. Ending a turn clears
  /// the dice, which used to wipe the rings mid-presentation.
  testWidgets('production rings follow the roll being presented', (
    tester,
  ) async {
    final f = rollFixture();
    var snapshot = f.before;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return TableStage(
                  snapshot: snapshot,
                  activity: f.activity,
                  onTarget: (_) {},
                  onPlayer: (_) {},
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    update(() => snapshot = f.after);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final rolled = f.after.producingHexes;
    expect(rolled, isNotEmpty);
    Set<String> rings() =>
        tester.widget<IslandBoard>(find.byType(IslandBoard)).producing ??
        tester
            .widget<IslandBoard>(find.byType(IslandBoard))
            .snapshot
            .producingHexes;
    expect(rings(), rolled);
    // The turn ends while the presentation is still running. The live snapshot
    // has no dice any more, but the rings belong to the roll on screen.
    final ended = object(jsonDecode(jsonEncode(f.after.json)));
    ended['version']++;
    ended['publicState']['hasRolled'] = false;
    ended['publicState']['dice'] = null;
    ended['publicState']['turnNumber']++;
    update(() => snapshot = GameSnapshot.parse(ended, uiProtocol));
    await tester.pump();
    expect(find.text('2 + 3 = 5'), findsOneWidget);
    expect(
      rings(),
      rolled,
      reason: 'The rings must not empty out from under the dice still showing.',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  /// Somebody else's roll waits its turn, so a payout is never cut short by the
  /// next roll. Your own still takes over, because you are waiting to act.
  testWidgets('another seat\'s roll waits for the payout to finish', (
    tester,
  ) async {
    final f = rollFixture();
    var snapshot = f.before;
    late StateSetter update;
    final transform = TransformationController();
    addTearDown(transform.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return TableStage(
                  snapshot: snapshot,
                  activity: f.activity,
                  onTarget: (_) {},
                  onPlayer: (_) {},
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    update(() => snapshot = f.after);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('2 + 3 = 5'), findsOneWidget);
    // The turn passes to another seat, which rolls while the payout is flying.
    final other = object(jsonDecode(jsonEncode(f.after.json)));
    final players = other['publicState']['players'] as Map;
    final them = players.keys.firstWhere(
      (id) => id != other['privateState']['playerId'],
    );
    other['publicState']['activePlayerId'] = them;
    other['publicState']['hasRolled'] = false;
    other['publicState']['dice'] = null;
    other['publicState']['turnNumber']++;
    other['version']++;
    update(() => snapshot = GameSnapshot.parse(other, uiProtocol));
    await tester.pump();
    other['version']++;
    other['publicState']['hasRolled'] = true;
    other['publicState']['dice'] = [3, 3];
    update(() => snapshot = GameSnapshot.parse(other, uiProtocol));
    await tester.pump();
    expect(
      find.text('2 + 3 = 5'),
      findsOneWidget,
      reason: 'The payout in progress keeps the stage until it is finished.',
    );
    expect(find.text('3 + 3 = 6'), findsNothing);
    // It is presented afterwards, in order, rather than dropped.
    await tester.pump(const Duration(milliseconds: 8000));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('3 + 3 = 6'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a roll hands the board back centred, however it started', (
    tester,
  ) async {
    final f = rollFixture();
    var snapshot = f.before;
    late StateSetter update;
    final transform = TransformationController();
    addTearDown(transform.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return TableStage(
                  snapshot: snapshot,
                  activity: f.activity,
                  onTarget: (_) {},
                  onPlayer: (_) {},
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final camera = viewer.transformationController!;
    // Start from somewhere the player panned and zoomed to.
    camera.value = Matrix4.identity()
      ..translateByDouble(-40, -30, 0, 1)
      ..scaleByDouble(1.25, 1.25, 1, 1);
    update(() => snapshot = f.after);
    await tester.pumpAndSettle();
    expect(
      camera.value,
      Matrix4.identity(),
      reason: 'The next roll must begin from the centred island.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('another seat building is zoomed, named and then recentred', (
    tester,
  ) async {
    final f = rollFixture();
    var snapshot = f.after;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return TableStage(
                  snapshot: snapshot,
                  activity: const [],
                  onTarget: (_) {},
                  onPlayer: (_) {},
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final camera = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    expect(camera.value, Matrix4.identity());
    final built = object(jsonDecode(jsonEncode(f.after.json)));
    final players = built['publicState']['players'] as Map;
    final them = players.keys.firstWhere(
      (id) => id != built['privateState']['playerId'],
    );
    built['publicState']['activePlayerId'] = them;
    final roads = built['publicState']['roads'] as Map;
    final edge = (built['publicState']['board']['edges'] as Map).keys
        .firstWhere((id) => !roads.containsKey(id));
    roads[edge] = {'ownerPlayerId': them};
    built['version']++;
    update(() => snapshot = GameSnapshot.parse(built, uiProtocol));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('build-focus-label')), findsOneWidget);
    expect(
      find.textContaining('built a road'),
      findsOneWidget,
      reason: 'Say who placed it; the camera only shows where.',
    );
    // Held long enough to notice, and zoomed in while it is held.
    await tester.pump(const Duration(milliseconds: 900));
    expect(camera.value.getMaxScaleOnAxis(), greaterThan(1.2));
    expect(find.byKey(const Key('build-focus-label')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('build-focus-label')), findsNothing);
    expect(
      camera.value,
      Matrix4.identity(),
      reason: 'The board is handed back centred after the close-up.',
    );
    expect(tester.takeException(), isNull);
  });
}
