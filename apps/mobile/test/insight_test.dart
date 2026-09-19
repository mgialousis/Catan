import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/core/connection.dart';
import 'package:island_table/game/controller.dart';
import 'package:island_table/game/game_screen.dart';
import 'package:island_table/game/model.dart';
import 'game_model_test.dart' show uiProtocol, uiSnapshot;
import 'game_test.dart' show FakePort;

void main() {
  GameSnapshot parse(JsonMap json) => GameSnapshot.parse(json, uiProtocol);

  group('what a roll paid out', () {
    test('is the hexes with that number, minus the robber', () {
      final json = uiSnapshot('action');
      json['publicState']['dice'] = [3, 5];
      final s = parse(json);
      final hexes = s.hexes;
      final expected = hexes.entries
          .where(
            (e) =>
                e.value['number'] == 8 &&
                e.value['terrain'] != 'DESERT' &&
                e.key != s.public['robberHexId'],
          )
          .map((e) => e.key)
          .toSet();
      expect(s.producingHexes, expected);
      expect(s.producingHexes.contains(s.public['robberHexId']), false);
    });

    test('is nothing before a roll, and nothing on a seven', () {
      expect(parse(uiSnapshot('setup')).producingHexes, isEmpty);
      final seven = uiSnapshot('action');
      seven['publicState']['dice'] = [3, 4];
      // A seven pays nobody; it moves the robber instead.
      expect(parse(seven).producingHexes, isEmpty);
    });
  });

  group('points breakdown', () {
    test('counts cities double and names the awards', () {
      final json = uiSnapshot('action');
      final me = json['privateState']['playerId'] as String;
      final buildings = json['publicState']['buildings'] as Map;
      final vertices = (json['publicState']['board']['vertices'] as Map).keys
          .toList();
      buildings.clear();
      buildings[vertices[0]] = {'ownerPlayerId': me, 'type': 'SETTLEMENT'};
      buildings[vertices[4]] = {'ownerPlayerId': me, 'type': 'CITY'};
      buildings[vertices[8]] = {'ownerPlayerId': me, 'type': 'CITY'};
      json['publicState']['longestRoad'] = {'holderPlayerId': me, 'size': 5};
      final rows = parse(json).pointsBreakdown(me);
      expect(rows, contains(('1 settlement', 1)));
      expect(rows, contains(('2 cities', 4)));
      expect(rows, contains(('Longest road', 2)));
      expect(rows.any((r) => r.$1 == 'Largest army'), false);
    });

    test('never counts a rival\'s hidden cards', () {
      final json = uiSnapshot('action');
      final s = parse(json);
      final rival = s.players.keys.firstWhere((id) => id != s.playerId);
      // The breakdown is built from public state alone for anyone else.
      expect(
        s.pointsBreakdown(rival).any((r) => r.$1.contains('victory point')),
        false,
      );
    });
  });

  testWidgets('the log collapses, expands and scrolls', (t) async {
    t.view.physicalSize = const Size(1200, 3000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final port = FakePort();
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          gamePortProvider.overrideWithValue(port),
          protocolProvider.overrideWithValue(uiProtocol),
        ],
        child: const MaterialApp(home: GameScreen()),
      ),
    );
    await t.pump();
    port.emit('connected', true);
    port.emit('snapshot', uiSnapshot('action'));
    await t.pumpAndSettle();
    final s = parse(uiSnapshot('action'));
    final many = [
      for (var i = 0; i < 12; i++)
        ActivityEntry(
          sequence: i,
          type: 'ROAD_BUILT',
          message: 'Built a road.',
          actorPlayerId: s.playerId,
        ),
    ];
    port.emit('history', many);
    await t.pumpAndSettle();
    // Collapsed by default, so a long match cannot swamp the page.
    expect(find.text('Show all 12'), findsOneWidget);
    expect(find.textContaining('built a road.'), findsNWidgets(4));
    await t.tap(find.text('Show all 12'));
    await t.pumpAndSettle();
    expect(find.text('Show less'), findsOneWidget);
    expect(find.byKey(const Key('activity-scroll')), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('a score explains how it adds up', (t) async {
    t.view.physicalSize = const Size(1200, 3000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final port = FakePort();
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          gamePortProvider.overrideWithValue(port),
          protocolProvider.overrideWithValue(uiProtocol),
        ],
        child: const MaterialApp(home: GameScreen()),
      ),
    );
    await t.pump();
    port.emit('connected', true);
    port.emit('snapshot', uiSnapshot('action'));
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.star_outline).first);
    await t.pumpAndSettle();
    expect(find.textContaining('points'), findsWidgets);
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();
    // Every other stat says what it means too.
    await t.tap(find.byIcon(Icons.shield_outlined).first);
    await t.pumpAndSettle();
    expect(find.text('Knights played'), findsOneWidget);
    expect(find.textContaining('Largest Army'), findsOneWidget);
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
