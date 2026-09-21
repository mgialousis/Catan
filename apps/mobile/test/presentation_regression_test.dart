import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/game/model.dart';
import 'package:island_table/game/table_stage.dart';
import 'game_model_test.dart' show uiProtocol, uiSnapshot;
import 'game_test.dart' show pumpGame;
import 'table_stage_test.dart' show rollFixture;

void main() {
  testWidgets('last opening road must not move the camera', (t) async {
    final json = uiSnapshot('action');
    final p = json['publicState'] as Map;
    p['phase'] = 'SETUP_ROAD';
    p['hasRolled'] = false;
    p['dice'] = null;
    final me = json['privateState']['playerId'];
    final owner = (p['players'] as Map).keys.firstWhere((id) => id != me);
    p['activePlayerId'] = owner;
    var snapshot = GameSnapshot.parse(json, uiProtocol);
    late StateSetter update;
    await t.pumpWidget(
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
    await t.pumpAndSettle();
    final camera = t
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    final held = camera.value.clone();
    final next = object(jsonDecode(jsonEncode(json)));
    final roads = next['publicState']['roads'] as Map;
    final edge = (next['publicState']['board']['edges'] as Map).keys.firstWhere(
      (id) => !roads.containsKey(id),
    );
    roads[edge] = {'ownerPlayerId': owner};
    next['version']++;
    next['publicState']['phase'] = 'AWAIT_ROLL';
    next['publicState']['turnNumber'] = 1;
    update(() => snapshot = GameSnapshot.parse(next, uiProtocol));
    await t.pump();
    await t.pump(const Duration(milliseconds: 350));
    expect(camera.value, held);
  });

  testWidgets('no-payout roll finished when server releases next bot', (
    t,
  ) async {
    final f = rollFixture();
    final before = object(jsonDecode(jsonEncode(f.before.json)));
    final after = object(jsonDecode(jsonEncode(f.after.json)));
    before['publicState']['buildings'] = <String, dynamic>{};
    after['publicState']['buildings'] = <String, dynamic>{};
    var snapshot = GameSnapshot.parse(before, uiProtocol);
    late StateSetter update;
    await t.pumpWidget(
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
    await t.pumpAndSettle();
    final camera = t
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    update(() => snapshot = GameSnapshot.parse(after, uiProtocol));
    await t.pump();
    await t.pump(const Duration(milliseconds: 3500));
    expect(
      camera.value,
      Matrix4.identity(),
      reason: 'Server botPace is 3500 ms for zero payouts.',
    );
  });

  for (final scale in [1.0, 2.0]) {
    for (final paused in [false, true]) {
      testWidgets(
        'landscape map fits with ${paused ? 'pause notice' : 'countdown'} at $scale text',
        (t) async {
          t.view.physicalSize = const Size(800, 360);
          t.view.devicePixelRatio = 1;
          t.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(t.view.reset);
          addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
          final json = uiSnapshot('action');
          json['serverTime'] = '2026-09-21T12:00:00Z';
          if (paused) {
            json['publicState']['pauseReasons'] = ['MANUAL'];
          } else {
            json['publicState']['turnDeadline'] = '2026-09-21T12:01:00Z';
          }
          await pumpGame(t, json);
          if (scale > 1) {
            // At 2x text, a long notice can fill most of a landscape screen.
            // The board must remain readable and reachable without overflow.
            await t.ensureVisible(find.byType(TableStage));
            await t.pumpAndSettle();
          }
          final map = t.getRect(find.byType(InteractiveViewer));
          final dock = t.getRect(find.byType(ResourceDock));
          expect(
            map.bottom,
            lessThanOrEqualTo(dock.top),
            reason: 'map=$map, dock=$dock',
          );
          expect(map.height, greaterThan(0));
          expect(t.takeException(), isNull);
          // Scrolling must not change the island's size.
          await t.drag(
            find.byKey(const Key('game-scroll')),
            const Offset(0, -40),
          );
          await t.pumpAndSettle();
          final afterScroll = t.getSize(find.byType(InteractiveViewer));
          expect(afterScroll.width, closeTo(map.width, 0.01));
          expect(afterScroll.height, closeTo(map.height, 0.01));
          await t.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('the persistent turn header exposes dice to screen readers', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    try {
      final f = rollFixture();
      await pumpGame(t, f.after.json);
      expect(
        find.bySemanticsLabel(RegExp(r'Turn .*dice 2 and 3, total 5')),
        findsOneWidget,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('dice fit a short landscape board with large text', (t) async {
    t.view.physicalSize = const Size(800, 360);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(t.view.reset);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final f = rollFixture();
    final before = object(jsonDecode(jsonEncode(f.before.json)));
    final after = object(jsonDecode(jsonEncode(f.after.json)));
    for (final json in [before, after]) {
      json['serverTime'] = '2026-09-21T12:00:00Z';
      json['publicState']['turnDeadline'] = '2026-09-21T12:01:00Z';
    }
    final port = await pumpGame(t, before);
    await t.ensureVisible(find.byType(TableStage));
    await t.pumpAndSettle();
    port.emit('snapshot', after);
    await t.pump();
    await t.pump();
    await t.pump(const Duration(milliseconds: 700));
    expect(find.text('2 + 3 = 5'), findsOneWidget);
    final panel = t.getRect(find.byKey(const Key('roll-dice-overlay')));
    final viewport = t.getRect(find.byType(InteractiveViewer));
    expect(panel.left, greaterThanOrEqualTo(viewport.left));
    expect(panel.right, lessThanOrEqualTo(viewport.right));
    expect(panel.top, greaterThanOrEqualTo(viewport.top));
    expect(panel.bottom, lessThanOrEqualTo(viewport.bottom));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  final timings =
      jsonDecode(
            File(
              '../../packages/protocol/fixtures/presentation-timing.json',
            ).readAsStringSync(),
          )
          as List;
  for (final timing in timings) {
    final cards = timing['cards'] as int;
    final duration = timing['durationMs'] as int;
    testWidgets('$cards-card payout finishes within the shared server timing', (
      t,
    ) async {
      final f = rollFixture();
      var snapshot = f.before;
      late StateSetter update;
      final first = f.activity.first;
      final resource = first.resources!.entries
          .firstWhere((e) => e.value > 0)
          .key;
      final activity = cards == 3
          ? f.activity
          : cards == 0
          ? <ActivityEntry>[]
          : [
              ActivityEntry(
                sequence: f.after.version,
                type: 'RESOURCES_COLLECTED',
                message: 'Collected resources from the roll.',
                actorPlayerId: first.actorPlayerId,
                resources: {...resources(), resource: cards},
              ),
            ];
      await t.pumpWidget(
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
      await t.pumpAndSettle();
      final camera = t
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      update(() => snapshot = f.after);
      await t.pump();
      await t.pump(const Duration(milliseconds: 2700));
      expect(find.byKey(const Key('roll-dice-overlay')), findsOneWidget);
      if (cards > 0) {
        await t.pump(const Duration(milliseconds: 1000));
        expect(
          camera.value,
          isNot(Matrix4.identity()),
          reason: 'a payout must actually focus the board',
        );
        await t.pump(Duration(milliseconds: duration - 3700));
      } else {
        await t.pump(Duration(milliseconds: duration - 2700));
      }
      expect(camera.value, Matrix4.identity());
      expect(find.byKey(const Key('roll-dice-overlay')), findsNothing);
      expect(
        t.binding.transientCallbackCount,
        0,
        reason: 'no presentation remains when the server resumes',
      );
    });
  }
}
