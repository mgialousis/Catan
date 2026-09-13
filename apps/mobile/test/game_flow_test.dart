import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/core/connection.dart';
import 'package:island_table/game/controller.dart';
import 'package:island_table/game/game_screen.dart';
import 'package:island_table/game/model.dart';
import 'game_test.dart' show FakePort;
import 'game_model_test.dart' show uiProtocol, uiSnapshot;

Future<FakePort> showGame(
  WidgetTester t,
  String scene, {
  Size size = const Size(375, 812),
  double scale = 1,
  Future<Uri> Function()? rematch,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final port = FakePort();
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        gamePortProvider.overrideWithValue(port),
        protocolProvider.overrideWithValue(uiProtocol),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: GameScreen(createRematch: rematch),
      ),
    ),
  );
  await t.pump();
  port.emit('connected', true);
  port.emit('snapshot', uiSnapshot(scene));
  await t.pumpAndSettle();
  return port;
}

Future<void> reveal(WidgetTester t, Finder finder) async {
  final scroll = find.byType(Scrollable).first;
  t.state<ScrollableState>(scroll).position.jumpTo(0);
  await t.pumpAndSettle();
  for (var i = 0; i < 50 && finder.evaluate().isEmpty; i++) {
    final rect = t.getRect(scroll);
    await t.dragFrom(
      Offset(rect.right - 3, rect.center.dy),
      const Offset(0, -180),
    );
    await t.pumpAndSettle();
  }
  expect(finder, findsWidgets);
  await t.ensureVisible(finder.first);
  await t.pumpAndSettle();
}

Future<void> press(WidgetTester t, String label) async {
  final f = find.text(label);
  await reveal(t, f);
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('trade resources stay exclusive and unlock when removed', (
    t,
  ) async {
    await showGame(t, 'action', size: const Size(900, 1400));
    await press(t, 'Trade');
    final buttons = find.byWidgetPredicate(
      (w) => w is IconButton && w.tooltip == 'One more Brick',
    );
    final give = buttons.first;
    final receive = buttons.last;
    await t.tap(give);
    await t.pump();
    expect(t.widget<IconButton>(receive).onPressed, isNull);
    expect(
      find.textContaining('offered above', findRichText: true),
      findsOneWidget,
    );
    await t.tap(find.byTooltip('One fewer Brick').first);
    await t.pump();
    expect(t.widget<IconButton>(receive).onPressed, isNotNull);
    await t.ensureVisible(receive);
    await t.tap(receive);
    await t.pump();
    expect(t.widget<IconButton>(give).onPressed, isNull);
    expect(
      find.textContaining('asked for below', findRichText: true),
      findsOneWidget,
    );
    await t.tap(find.byTooltip('One fewer Brick').last);
    await t.pump();
    expect(t.widget<IconButton>(give).onPressed, isNotNull);
  });

  testWidgets(
    'waiting player can compose a trade only with the active player',
    (t) async {
      final port = await showGame(t, 'waiting');
      await press(t, 'Offer a trade');
      expect(find.text('You give'), findsOneWidget);
      expect(find.text('Everyone'), findsNothing);
      final dropdown = t.widget<DropdownButtonFormField<String?>>(
        find.byType(DropdownButtonFormField<String?>),
      );
      expect(
        dropdown.initialValue,
        uiSnapshot('waiting')['publicState']['activePlayerId'],
      );
      expect(find.textContaining('Bank exchange'), findsNothing);
      expect(port.commands, isEmpty);
    },
  );
  testWidgets(
    'mixed bank resources never produce a different exchange than the composition',
    (t) async {
      final port = await showGame(t, 'action');
      await press(t, 'Trade');
      await t.tap(find.byTooltip('One more Brick').first);
      await t.tap(find.byTooltip('One more Lumber').first);
      await t.tap(find.byTooltip('One more Lumber').first);
      await t.tap(find.byTooltip('One more Lumber').first);
      await t.scrollUntilVisible(
        find.text('You receive'),
        180,
        scrollable: find.byType(Scrollable).last,
      );
      await t.pumpAndSettle();
      await t.ensureVisible(find.byTooltip('One more Ore').last);
      await t.tap(find.byTooltip('One more Ore').last);
      await t.pumpAndSettle();
      await t.scrollUntilVisible(
        find.textContaining('Bank needs'),
        180,
        scrollable: find.byType(Scrollable).last,
      );
      await t.pumpAndSettle();
      final button = t.widget<OutlinedButton>(
        find.ancestor(
          of: find.textContaining('Bank needs'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(button.onPressed, isNull);
      expect(port.commands, isEmpty);
    },
  );
  testWidgets('discard exactly the required owned bundle', (t) async {
    final port = await showGame(t, 'discard');
    await press(t, 'Discard cards');
    final dialog = find.byType(AlertDialog);
    var confirm = find.descendant(of: dialog, matching: find.text('Confirm'));
    expect(
      t
          .widget<FilledButton>(
            find.ancestor(of: confirm, matching: find.byType(FilledButton)),
          )
          .onPressed,
      isNull,
    );
    for (final resource in ['Brick', 'Lumber', 'Wool']) {
      for (var i = 0; i < (resource == 'Wool' ? 2 : 4); i++) {
        await t.tap(find.byTooltip('One more $resource'));
        await t.pump();
      }
    }
    await t.tap(confirm);
    await t.pump();
    expect(port.commands.single['type'], 'DISCARD_RESOURCES');
    expect(port.commands.single['payload']['resources'], {
      'brick': 4,
      'lumber': 4,
      'wool': 2,
      'grain': 0,
      'ore': 0,
    });
  });
  testWidgets(
    'a stale modal choice cannot be submitted against a newer table',
    (t) async {
      final port = await showGame(t, 'action');
      await press(t, 'Play a card');
      await t.tap(find.text('Monopoly').last);
      await t.pumpAndSettle();
      final next = uiSnapshot('action');
      next['version'] = (next['version'] as int) + 1;
      port.emit('snapshot', next);
      await t.pump();
      await t.tap(find.text('Ore'));
      await t.pumpAndSettle();
      expect(port.commands, isEmpty);
      await reveal(t, find.textContaining('table changed while'));
      expect(find.textContaining('table changed while'), findsOneWidget);
    },
  );
  testWidgets('Year of Plenty emits an exact duplicate-resource choice', (
    t,
  ) async {
    final port = await showGame(t, 'action');
    await press(t, 'Play a card');
    await t.tap(find.text('Year Of Plenty').last);
    await t.pumpAndSettle();
    final holdings = GameSnapshot.parse(uiSnapshot('action'), uiProtocol).stock;
    for (final resource in holdings.keys) {
      expect(
        find.text(
          '${words(resource)}  you hold ${holdings[resource]}',
          findRichText: true,
        ),
        findsOneWidget,
      );
    }
    for (var i = 0; i < 2; i++) {
      await t.tap(find.byTooltip('One more Grain'));
      await t.pump();
    }
    await t.tap(find.text('Confirm'));
    await t.pump();
    expect(port.commands.single['type'], 'PLAY_DEVELOPMENT_CARD');
    expect(port.commands.single['payload']['choice']['resources']['grain'], 2);
  });
  testWidgets(
    'result confirms rematch creation once and displays a copyable invitation',
    (t) async {
      var calls = 0;
      await showGame(
        t,
        'results',
        rematch: () async {
          calls++;
          return Uri.parse('https://example.test/#invite=ABCDEF1234');
        },
      );
      await press(t, 'Invite to a rematch');
      expect(calls, 0);
      await t.tap(find.text('Create invitation'));
      await t.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('Copy invitation'), findsOneWidget);
      expect(
        find.text('https://example.test/#invite=ABCDEF1234'),
        findsOneWidget,
      );
    },
  );
  for (final size in [const Size(320, 640), const Size(812, 375)]) {
    for (final scale in [1.0, 2.0]) {
      for (final modal in [
        'trade',
        'discard',
        'monopoly',
        'plenty',
        'cards',
        'rematch',
      ]) {
        testWidgets(
          '$modal modal at ${size.width}×${size.height}, text $scale',
          (t) async {
            await showGame(
              t,
              modal == 'discard'
                  ? 'discard'
                  : modal == 'rematch'
                  ? 'results'
                  : 'action',
              size: size,
              scale: scale,
              rematch: () async =>
                  Uri.parse('https://example.test/#invite=ABCDEF1234'),
            );
            if (modal == 'trade') {
              await press(t, 'Trade');
            } else if (modal == 'discard') {
              await press(t, 'Discard cards');
            } else if (modal == 'rematch') {
              await press(t, 'Invite to a rematch');
            } else {
              await press(t, 'Play a card');
              if (modal != 'cards') {
                final card = find.descendant(
                  of: find.byType(BottomSheet),
                  matching: find.text(
                    modal == 'monopoly' ? 'Monopoly' : 'Year Of Plenty',
                  ),
                );
                await t.scrollUntilVisible(
                  card,
                  80,
                  scrollable: find
                      .descendant(
                        of: find.byType(BottomSheet),
                        matching: find.byType(Scrollable),
                      )
                      .last,
                );
                await t.pumpAndSettle();
                await t.tap(card);
                await t.pumpAndSettle();
                expect(
                  find.byType(modal == 'monopoly' ? SimpleDialog : AlertDialog),
                  findsOneWidget,
                );
              }
            }
            expect(t.takeException(), isNull);
            for (var i = 0; i < 10; i++) {
              final surface = find.byType(AlertDialog).evaluate().isNotEmpty
                  ? find.byType(AlertDialog)
                  : find.byType(SimpleDialog).evaluate().isNotEmpty
                  ? find.byType(SimpleDialog)
                  : find.byType(BottomSheet);
              final scrolls = find.descendant(
                of: surface,
                matching: find.byType(Scrollable),
              );
              if (scrolls.evaluate().isEmpty) break;
              final scroll = scrolls.last;
              await t.drag(scroll, const Offset(0, -160));
              await t.pumpAndSettle();
              expect(t.takeException(), isNull, reason: '$modal scroll $i');
            }
          },
        );
      }
    }
  }
  test(
    'ack-before-snapshot keeps the intent pending, same-ID retry survives a lost reply',
    () async {
      final port = FakePort(),
          container = ProviderContainer(
            overrides: [
              gamePortProvider.overrideWithValue(port),
              protocolProvider.overrideWithValue(uiProtocol),
            ],
          );
      addTearDown(container.dispose);
      final c = container.read(gameProvider.notifier);
      port.emit('connected', true);
      port.emit('snapshot', uiSnapshot('action'));
      await Future<void>.delayed(Duration.zero);
      final operation = c.command('END_TURN');
      port.replies[0].completeError(TimeoutException('lost reply'));
      await operation;
      final original = port.commands[0];
      final retry = c.retry();
      expect(port.commands[1], same(original));
      port.replies[1].complete({
        'commandId': original['commandId'],
        'status': 'ACCEPTED',
        'version': c.state.snapshot!.version + 1,
      });
      await retry;
      expect(c.state.pending, isNotNull);
      final next = uiSnapshot('action');
      next['version'] = c.state.snapshot!.version + 1;
      port.emit('snapshot', next);
      await Future<void>.delayed(Duration.zero);
      expect(c.state.pending, isNull);
    },
  );
}
