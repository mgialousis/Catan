import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/core/connection.dart';
import 'package:island_table/game/controller.dart';
import 'package:island_table/game/model.dart';
import 'package:island_table/game/resource_icon.dart';
import 'game_flow_test.dart' show showGame, reveal;
import 'game_model_test.dart' show uiProtocol, uiSnapshot;
import 'game_test.dart' show FakePort;

void main() {
  testWidgets('new Road Building card shows why it must wait', (t) async {
    final port = await showGame(t, 'action');
    final s = uiSnapshot('action');
    s['version']++;
    for (final card in s['privateState']['developmentCards'] as List) {
      if (card['type'] == 'ROAD_BUILDING') {
        card['purchasedOnTurn'] = s['publicState']['turnNumber'];
      }
    }
    port.emit('snapshot', s);
    await t.pumpAndSettle();
    await reveal(
      t,
      find.textContaining('New development cards, including Road Building'),
    );
    final card = find.widgetWithText(ActionChip, 'Road Building');
    expect(t.widget<ActionChip>(card).onPressed, isNull);
    expect(t.widget<ActionChip>(card).tooltip, 'Available on your next turn');
    expect(port.commands, isEmpty);
  });

  test(
    'collection tracks only the observed roll, not subsequent spending or replay',
    () async {
      final port = FakePort();
      final container = ProviderContainer(
        overrides: [
          gamePortProvider.overrideWithValue(port),
          protocolProvider.overrideWithValue(uiProtocol),
        ],
      );
      addTearDown(container.dispose);
      container.read(gameProvider);
      Future<void> publish(JsonMap s) async {
        port.emit('snapshot', s);
        await Future<void>.delayed(Duration.zero);
        expect(container.read(gameProvider).snapshot!.version, s['version']);
      }

      final before = uiSnapshot('waiting');
      before['publicState']['hasRolled'] = false;
      before['publicState']['dice'] = null;
      before['publicState']['phase'] = 'AWAIT_ROLL';
      await publish(before);
      final roll = uiSnapshot('waiting');
      roll['version'] = before['version'] + 1;
      roll['privateState']['resources']['brick'] = 6;
      await publish(roll);
      expect(container.read(gameProvider).rollGains, {
        ...resources(),
        'brick': 2,
      });
      await publish(roll);
      final spent = uiSnapshot('waiting');
      spent['version'] = roll['version'] + 1;
      spent['privateState']['resources']['brick'] = 3;
      await publish(spent);
      expect(container.read(gameProvider).rollGains!['brick'], 2);
      final nextTurn = uiSnapshot('waiting');
      nextTurn['version'] = spent['version'] + 1;
      nextTurn['publicState']['turnNumber'] = 2;
      nextTurn['publicState']['hasRolled'] = false;
      nextTurn['publicState']['dice'] = null;
      await publish(nextTurn);
      expect(container.read(gameProvider).rollGains, isNull);
      final gap = uiSnapshot('waiting');
      gap['version'] = nextTurn['version'] + 3;
      gap['publicState']['turnNumber'] = 2;
      await publish(gap);
      expect(container.read(gameProvider).rollGains, isNull);
    },
  );

  test(
    'trade recipients exclude own, declined, expired, and unrelated offers',
    () {
      final s = uiSnapshot('waiting');
      final offer = (s['publicState']['trades'] as Map).values.single as Map;
      List<JsonMap> incoming() =>
          GameSnapshot.parse(s, uiProtocol).incomingTrades;
      expect(incoming(), hasLength(1));
      offer['targetPlayerId'] = null;
      expect(incoming(), hasLength(1));
      offer['declinedBy'] = [s['privateState']['playerId']];
      expect(incoming(), isEmpty);
      offer['declinedBy'] = [];
      offer['status'] = 'EXPIRED';
      expect(incoming(), isEmpty);
      offer['status'] = 'OPEN';
      offer['targetPlayerId'] = '00000000-0000-4000-8000-00000000000a';
      expect(incoming(), isEmpty);
      offer['targetPlayerId'] = null;
      offer['proposerPlayerId'] = s['privateState']['playerId'];
      expect(incoming(), isEmpty);
    },
  );

  testWidgets('discards and thefts are announced and then logged', (t) async {
    final port = await showGame(t, 'action');
    final s = GameSnapshot.parse(uiSnapshot('action'), uiProtocol);
    final others = s.orderedPlayers
        .map((p) => p['id'] as String)
        .where((id) => id != s.playerId)
        .toList();
    final a = others[0], b = others[1];
    ActivityEntry built(int sequence) => ActivityEntry(
      sequence: sequence,
      type: 'ROAD_BUILT',
      message: 'Built a road.',
      actorPlayerId: a,
    );
    final discard = ActivityEntry(
      sequence: 2,
      type: 'RESOURCES_DISCARDED',
      message: 'Discarded the required resource cards.',
      actorPlayerId: a,
      resources: {'brick': 2, 'lumber': 0, 'wool': 0, 'grain': 0, 'ore': 1},
    );
    final theft = ActivityEntry(
      sequence: 3,
      type: 'RESOURCE_STOLEN',
      message: 'Stole one resource card.',
      actorPlayerId: b,
      subjectPlayerId: a,
    );

    // The first delivery only establishes the high-water mark.
    port.emit('history', [built(1)]);
    await t.pumpAndSettle();
    expect(find.textContaining('discarded'), findsNothing);

    port.emit('history', [built(1), discard, theft]);
    await t.pumpAndSettle();
    final discarded = '${s.name(a)} discarded 2 brick · 1 ore.';
    final stolen = '${s.name(b)} stole one resource card from ${s.name(a)}.';
    expect(find.text(discarded), findsOneWidget);
    expect(find.text(stolen), findsOneWidget);

    // Re-delivering the same log must not announce them a second time.
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 8));
    await t.pumpAndSettle();
    port.emit('history', [built(1), discard, theft]);
    await t.pumpAndSettle();
    expect(find.text(stolen), findsNothing);

    // They remain in the log itself.
    await reveal(t, find.text('· $stolen'));
    await reveal(t, find.text('· $discarded'));
    expect(port.commands, isEmpty);
    expect(t.takeException(), isNull);
  });

  testWidgets('a decline on your own offer is announced once', (t) async {
    final port = await showGame(t, 'action');
    final base = uiSnapshot('waiting');
    final me = base['privateState']['playerId'] as String;
    final trade = (base['publicState']['trades'] as Map).values.single as Map;
    // Re-point the fixture's offer so this player is the proposer, offered to
    // the table rather than to one opponent.
    trade['proposerPlayerId'] = me;
    trade['targetPlayerId'] = null;
    trade['declinedBy'] = <String>[];
    port.emit('snapshot', base);
    await t.pumpAndSettle();
    expect(find.text('Trade declined'), findsNothing);

    final opponents = (base['publicState']['players'] as Map).keys
        .cast<String>()
        .where((id) => id != me)
        .toList();
    final first = uiSnapshot('waiting');
    first['version'] = (base['version'] as int) + 1;
    final firstTrade =
        (first['publicState']['trades'] as Map).values.single as Map;
    firstTrade['proposerPlayerId'] = me;
    firstTrade['targetPlayerId'] = null;
    firstTrade['declinedBy'] = [opponents.first];
    port.emit('snapshot', first);
    await t.pumpAndSettle();
    expect(find.text('Trade declined'), findsOneWidget);
    expect(find.textContaining('declined your offer of'), findsOneWidget);
    // Not yet exhausted: other opponents can still accept.
    expect(find.textContaining('Nobody is left'), findsNothing);
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
    expect(find.text('Trade declined'), findsNothing);

    // Re-delivering the same state must not announce the decline again.
    port.emit('snapshot', first);
    await t.pumpAndSettle();
    expect(find.text('Trade declined'), findsNothing);

    // The last outstanding opponents decline together.
    final rest = uiSnapshot('waiting');
    rest['version'] = (first['version'] as int) + 1;
    final restTrade =
        (rest['publicState']['trades'] as Map).values.single as Map;
    restTrade['proposerPlayerId'] = me;
    restTrade['targetPlayerId'] = null;
    restTrade['declinedBy'] = opponents;
    port.emit('snapshot', rest);
    await t.pumpAndSettle();
    expect(find.textContaining('Nobody is left'), findsOneWidget);
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
    expect(port.commands, isEmpty);
    expect(t.takeException(), isNull);
  });

  testWidgets('new trade alerts once, opens review and expires', (t) async {
    final port = await showGame(t, 'action');
    final offer = uiSnapshot('waiting');
    port.emit('snapshot', offer);
    await t.pumpAndSettle();
    expect(find.textContaining('wants to trade with you.'), findsOneWidget);
    expect(find.text('1 trade request for you'), findsOneWidget);
    await t.tap(find.text('View trades'));
    await t.pumpAndSettle();
    expect(find.text('Accept'), findsOneWidget);
    Navigator.of(t.element(find.text('Accept'))).pop();
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 7));
    await t.pumpAndSettle();
    port.emit('snapshot', offer);
    await t.pumpAndSettle();
    expect(find.textContaining('wants to trade with you.'), findsNothing);
    offer['version']++;
    (offer['publicState']['trades'] as Map).values.single['status'] = 'EXPIRED';
    port.emit('snapshot', offer);
    await t.pumpAndSettle();
    expect(find.text('1 trade request for you'), findsNothing);
  });

  testWidgets('trade can arrive and expire while roll feedback is visible', (
    t,
  ) async {
    final port = await showGame(t, 'action');
    final before = uiSnapshot('action');
    before['version']++;
    before['publicState']['hasRolled'] = false;
    before['publicState']['dice'] = null;
    port.emit('snapshot', before);
    await t.pump();
    final roll = uiSnapshot('action');
    roll['version'] = before['version'] + 1;
    roll['privateState']['resources']['ore'] = 6;
    port.emit('snapshot', roll);
    await t.pumpAndSettle();
    expect(find.text('You collected 2 ore.'), findsOneWidget);
    final trade = uiSnapshot('waiting');
    trade['version'] = roll['version'] + 1;
    port.emit('snapshot', trade);
    await t.pump();
    trade['version']++;
    (trade['publicState']['trades'] as Map).values.single['status'] = 'EXPIRED';
    port.emit('snapshot', trade);
    await t.pumpAndSettle();
    expect(find.textContaining('wants to trade with you.'), findsNothing);
    expect(t.takeException(), isNull);
  });

  for (final size in [const Size(320, 740), const Size(844, 390)]) {
    testWidgets(
      'dice, resource art and zero collection fit $size with large text',
      (t) async {
        final port = await showGame(t, 'action', size: size, scale: 1.5);
        expect(find.textContaining('1 + 1 = 2'), findsOneWidget);
        final before = uiSnapshot('action');
        before['version']++;
        before['publicState']['hasRolled'] = false;
        before['publicState']['dice'] = null;
        port.emit('snapshot', before);
        await t.pumpAndSettle();
        final roll = uiSnapshot('action');
        roll['version'] = before['version'] + 1;
        roll['publicState']['dice'] = [3, 4];
        port.emit('snapshot', roll);
        await t.pumpAndSettle();
        expect(find.textContaining('3 + 4 = 7'), findsOneWidget);
        await reveal(t, find.text('You collected this roll'));
        expect(
          find.text('No resources — a 7 activates the robber.'),
          findsOneWidget,
        );
        expect(find.byType(ResourceIcon), findsNWidgets(5));
        expect(t.takeException(), isNull);
      },
    );
  }
}
