import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/game/model.dart';
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
        expect(find.text('2 + 3 · 5'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 1900));
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

  testWidgets('fast subsequent turns queue rolls without blocking the board', (
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
    expect(find.text('2 + 3 · 5'), findsOneWidget);
    next['version']++;
    next['publicState']['hasRolled'] = true;
    next['publicState']['dice'] = [3, 3];
    next['publicState']['phase'] = 'ACTION';
    update(() => snapshot = GameSnapshot.parse(next, uiProtocol));
    await tester.pump();
    expect(find.text('2 + 3 · 5'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 4700));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('3 + 3 · 6'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('roll-dice-overlay')), findsNothing);
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
}
