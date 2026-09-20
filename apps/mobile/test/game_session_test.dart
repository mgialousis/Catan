import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/core/connection.dart';
import 'package:island_table/game/controller.dart';
import 'package:island_table/game/countdown.dart';
import 'package:island_table/game/game_screen.dart';
import 'package:island_table/game/model.dart';
import 'package:island_table/game/resource_icon.dart';
import 'game_model_test.dart' show uiProtocol, uiSnapshot;
import 'game_test.dart' show FakePort;
import 'table_stage_test.dart' show rollFixture;

void main() {
  /// Pause and leave live behind the table menu now, so a test has to open it
  /// exactly as a player would.
  Future<void> openMenu(WidgetTester t) async {
    await t.tap(find.byIcon(Icons.settings_outlined));
    await t.pumpAndSettle();
  }

  test(
    'countdown uses elapsed time and stale server samples cannot refund time',
    () {
      var elapsed = 0;
      final clock = EstimatedServerClock(() => elapsed)
        ..observe('2026-09-11T12:00:00Z');
      const deadline = '2026-09-11T12:01:00Z';
      expect(clock.secondsLeft(deadline), 60);
      elapsed = 17250;
      expect(clock.secondsLeft(deadline), 43);
      clock.observe('2026-09-11T11:59:59Z');
      expect(clock.secondsLeft(deadline), 43);
      clock.observe('2026-09-11T12:00:20Z');
      expect(clock.secondsLeft(deadline), 40);
      elapsed = 80000;
      expect(clock.secondsLeft(deadline), 0);
    },
  );
  testWidgets('expired display waits for server and never sends a move', (
    t,
  ) async {
    await t.pumpWidget(
      const MaterialApp(
        home: GameCountdown(
          serverTime: '2026-09-11T12:00:00Z',
          deadline: '2026-09-11T11:59:59Z',
          discard: true,
        ),
      ),
    );
    expect(find.text('Time is up · waiting for the server'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
    'a live timed owner snapshot renders the synchronized countdown',
    (t) async {
      t.view.physicalSize = const Size(430, 932);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final port = FakePort(), saved = uiSnapshot('action');
      saved['serverTime'] = '2026-09-11T12:00:00Z';
      saved['publicState']['turnDeadline'] = '2026-09-11T12:01:00Z';
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            gamePortProvider.overrideWithValue(port),
            protocolProvider.overrideWithValue(uiProtocol),
          ],
          child: const MaterialApp(home: GameScreen(isHost: true)),
        ),
      );
      await t.pump();
      port.emit('connected', true);
      port.emit('snapshot', saved);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Turn time · 1:00'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  for (final host in [false, true]) {
    testWidgets('host=$host has the appropriate pause and abandon controls', (
      t,
    ) async {
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
          child: MaterialApp(home: GameScreen(isHost: host)),
        ),
      );
      await t.pump();
      port.emit('connected', true);
      port.emit('snapshot', uiSnapshot('paused'));
      await t.pumpAndSettle();
      // The table's own actions live behind one control beside the board.
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
      await openMenu(t);
      expect(find.text('Resume game'), host ? findsOneWidget : findsNothing);
      // Everyone can reach the exit; what it offers depends on who they are.
      expect(find.text('Leave game'), findsOneWidget);
      if (host) {
        await t.tap(find.text('Resume game'));
        await t.pump();
        expect(port.commands.single['type'], 'RESUME_GAME');
      } else {
        await t.tapAt(const Offset(5, 5));
        await t.pumpAndSettle();
      }
      await t.pumpWidget(const SizedBox());
    });
  }

  /// A saved game whose non-host seats are automated, as practice mode creates.
  JsonMap withBots(String scene) {
    final snapshot = uiSnapshot(scene);
    final players = snapshot['publicState']['players'] as Map;
    final me = snapshot['privateState']['playerId'];
    for (final entry in players.entries) {
      if (entry.key != me) (entry.value as Map)['kind'] = 'BOT';
    }
    return snapshot;
  }

  Future<FakePort> show(
    WidgetTester t,
    JsonMap snapshot, {
    bool isHost = true,
  }) async {
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
        child: MaterialApp(home: GameScreen(isHost: isHost)),
      ),
    );
    await t.pump();
    port.emit('connected', true);
    port.emit('snapshot', snapshot);
    await t.pumpAndSettle();
    return port;
  }

  testWidgets('a practice game is left in its own terms', (t) async {
    final port = await show(t, withBots('paused'));
    await openMenu(t);
    expect(find.text('Leave practice game'), findsOneWidget);
    expect(find.text('Leave game'), findsNothing);
    await t.tap(find.text('Leave practice game'));
    await t.pumpAndSettle();
    // Nothing about ending it for other people: there are none.
    expect(find.text('Leave this practice game?'), findsOneWidget);
    expect(find.text('End game for everyone'), findsNothing);
    await t.tap(find.text('Keep playing'));
    await t.pumpAndSettle();
    expect(port.commands, isEmpty);
    await openMenu(t);
    await t.tap(find.text('Leave practice game'));
    await t.pumpAndSettle();
    await t.tap(find.text('Leave practice game').last);
    await t.pump();
    expect(port.commands.single['type'], 'ABANDON_GAME');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a guest can leave a shared game without ending it', (t) async {
    final port = await show(t, uiSnapshot('paused'), isHost: false);
    await openMenu(t);
    expect(find.text('Leave game'), findsOneWidget);
    await t.tap(find.text('Leave game'));
    await t.pumpAndSettle();
    expect(find.text('Leave this game?'), findsOneWidget);
    // A guest is never offered the power to end someone else's game.
    expect(find.text('End game for everyone'), findsNothing);
    await t.tap(find.text('Keep playing'));
    await t.pumpAndSettle();
    expect(port.commands, isEmpty);
    await openMenu(t);
    await t.tap(find.text('Leave game'));
    await t.pumpAndSettle();
    await t.tap(find.text('Leave the table'));
    await t.pump();
    expect(port.commands.single['type'], 'LEAVE_GAME');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('the host can leave without ending the game too', (t) async {
    final port = await show(t, uiSnapshot('paused'));
    await openMenu(t);
    await t.tap(find.text('Leave game'));
    await t.pumpAndSettle();
    // Both exits are offered, and they are not the same thing.
    expect(find.text('End game for everyone'), findsOneWidget);
    expect(find.text('Leave the table'), findsOneWidget);
    await t.tap(find.text('Leave the table'));
    await t.pump();
    expect(port.commands.single['type'], 'LEAVE_GAME');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('an empty seat asks the table to decide', (t) async {
    final snapshot = uiSnapshot('paused');
    final players = snapshot['publicState']['players'] as Map;
    final me = snapshot['privateState']['playerId'];
    final gone = players.keys.firstWhere((id) => id != me);
    (players[gone] as Map)['kind'] = 'VACANT';
    (snapshot['publicState']['pauseReasons'] as List).add('SEAT_VACANT');
    final port = await show(t, snapshot);
    final name = (players[gone] as Map)['nickname'];
    expect(find.textContaining('$name left the game.'), findsOneWidget);
    // The generic pause banner steps aside: this needs a decision, not a status.
    expect(
      find.textContaining('The host can resume when required players'),
      findsNothing,
    );
    await t.tap(find.text('Let a bot take over'));
    await t.pump();
    expect(port.commands.single['type'], 'REPLACE_WITH_BOT');
    expect(port.commands.single['payload'], {'playerId': gone});
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('automated seats are labelled in the roster', (t) async {
    await show(t, withBots('action'));
    expect(find.textContaining('(bot)'), findsWidgets);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
    'abandon confirmation can be cancelled and uses the displayed version',
    (t) async {
      t.view.physicalSize = const Size(1200, 3000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final port = FakePort(), saved = uiSnapshot('paused');
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            gamePortProvider.overrideWithValue(port),
            protocolProvider.overrideWithValue(uiProtocol),
          ],
          child: const MaterialApp(home: GameScreen(isHost: true)),
        ),
      );
      await t.pump();
      port.emit('connected', true);
      port.emit('snapshot', saved);
      await t.pumpAndSettle();
      await openMenu(t);
      await t.tap(find.text('Leave game'));
      await t.pumpAndSettle();
      await t.tap(find.text('Keep playing'));
      await t.pumpAndSettle();
      expect(port.commands, isEmpty);
      await openMenu(t);
      await t.tap(find.text('Leave game'));
      await t.pumpAndSettle();
      await t.tap(find.text('End game for everyone'));
      await t.pump();
      expect(port.commands.single['type'], 'ABANDON_GAME');
      expect(port.commands.single['expectedVersion'], saved['version']);
      await t.pumpWidget(const SizedBox());
    },
  );

  /// Bug: rolling on your own turn showed no dice or resource animation, while
  /// a bot's roll animated normally. Sending a command inserts a "sending"
  /// panel above the board, and the acknowledgement removes it again. The board
  /// was an unkeyed list child, so each shift rebuilt its element from scratch
  /// and the roll transition never reached the presentation.
  testWidgets('rolling on your own turn animates through the real screen', (
    t,
  ) async {
    t.view.physicalSize = const Size(430, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final f = rollFixture();
    final port = FakePort();
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          gamePortProvider.overrideWithValue(port),
          protocolProvider.overrideWithValue(uiProtocol),
        ],
        child: const MaterialApp(home: GameScreen(isHost: true)),
      ),
    );
    await t.pump();
    port.emit('connected', true);
    port.emit('snapshot', f.before.json);
    await t.pumpAndSettle();
    // Roll exactly as a player does, so the pending panel really appears.
    await t.tap(find.text('Roll dice'));
    await t.pump();
    expect(port.commands.single['type'], 'ROLL_DICE');
    port.replies.single.complete({'version': f.after.version});
    port.emit('snapshot', f.after.json);
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(
      find.byKey(const Key('roll-dice-overlay')),
      findsOneWidget,
      reason: 'Your own roll must animate, not only other players\' rolls.',
    );
    // The HUD readout also shows the total, so scope this to the overlay.
    expect(
      find.descendant(
        of: find.byKey(const Key('roll-dice-overlay')),
        matching: find.text('2 + 3 = 5'),
      ),
      findsOneWidget,
    );
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('build actions show what they cost', (t) async {
    await show(t, uiSnapshot('action'));
    // A road costs one brick and one lumber: two icons on the action itself.
    final road = find.ancestor(
      of: find.text('Build road'),
      matching: find.byType(OutlinedButton),
    );
    expect(road, findsOneWidget);
    for (final resource in ['brick', 'lumber']) {
      expect(
        find.descendant(
          of: road,
          matching: find.byWidgetPredicate(
            (w) => w is ResourceIcon && w.resource == resource,
          ),
        ),
        findsOneWidget,
        reason: 'a road costs one $resource',
      );
    }
    // A city costs two grain and three ore, shown as five icons.
    final city = find.ancestor(
      of: find.text('Build city'),
      matching: find.byType(OutlinedButton),
    );
    expect(
      find.descendant(
        of: city,
        matching: find.byWidgetPredicate(
          (w) => w is ResourceIcon && w.resource == 'ore',
        ),
      ),
      findsNWidgets(3),
    );
    expect(
      find.descendant(
        of: city,
        matching: find.byWidgetPredicate(
          (w) => w is ResourceIcon && w.resource == 'grain',
        ),
      ),
      findsNWidgets(2),
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
