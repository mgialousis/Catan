import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/game/model.dart';
import 'game_flow_test.dart' show showGame, reveal;
import 'game_model_test.dart' show uiSnapshot;

// Seats in the fixture, in turn order. The viewer is Noor.
const mira = '00000000-0000-4000-8000-00000000000a';
const theo = '00000000-0000-4000-8000-00000000000b';
const noor = '00000000-0000-4000-8000-00000000000c';

/// The table after something else happened: the same game one version on.
JsonMap next(JsonMap from, void Function(JsonMap public, JsonMap hand) change) {
  final snapshot = object(jsonDecode(jsonEncode(from)));
  snapshot['version'] = (snapshot['version'] as int) + 1;
  change(
    snapshot['publicState'] as JsonMap,
    snapshot['privateState'] as JsonMap,
  );
  return snapshot;
}

Future<void> openTrade(WidgetTester t, String label) async {
  await reveal(t, find.text(label));
  await t.tap(find.text(label));
  await t.pumpAndSettle();
}

/// Give one Lumber, ask for one Ore -- the counters are in two sections.
Future<void> compose(WidgetTester t, {int lumber = 1}) async {
  for (var i = 0; i < lumber; i++) {
    await t.tap(find.byTooltip('One more Lumber').first);
    await t.pump();
  }
  await t.tap(find.byTooltip('One more Ore').last);
  await t.pump();
}

Finder get propose => find.widgetWithText(FilledButton, 'Propose trade');

void main() {
  testWidgets('a trade being composed survives the table moving on', (t) async {
    final port = await showGame(t, 'action');
    await openTrade(t, 'Trade');
    await compose(t);
    // Somebody else's move lands while the sheet is open. This is constant in
    // a bot game, and it used to throw the whole composition away.
    final moved = next(uiSnapshot('action'), (public, _) {
      (public['players'] as Map)[mira]['resourceCardCount'] = 6;
    });
    port.emit('snapshot', moved);
    await t.pump();
    await t.tap(propose);
    await t.pump();
    expect(
      port.commands,
      hasLength(1),
      reason: 'the trade was sent, not refused',
    );
    final sent = port.commands.single;
    expect(sent['type'], 'PROPOSE_TRADE');
    expect(
      sent['expectedVersion'],
      moved['version'],
      reason: 'against the table as it is now',
    );
    expect(sent['payload']['give']['lumber'], 1);
    expect(sent['payload']['receive']['ore'], 1);
    // The sheet waits for the table to confirm before it closes.
    expect(propose, findsOneWidget);
    port.replies.single.complete({
      'commandId': sent['commandId'],
      'status': 'ACCEPTED',
      'version': (moved['version'] as int) + 1,
    });
    await t.pumpAndSettle();
    expect(propose, findsNothing, reason: 'closed once the trade was accepted');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('if you no longer hold what you offered, it says so and waits', (
    t,
  ) async {
    final port = await showGame(t, 'action');
    await openTrade(t, 'Trade');
    await compose(t, lumber: 3);
    // A card is stolen while the offer is being put together.
    port.emit(
      'snapshot',
      next(uiSnapshot('action'), (_, hand) {
        (hand['resources'] as Map)['lumber'] = 1;
      }),
    );
    await t.pump();
    expect(t.widget<FilledButton>(propose).onPressed, isNull);
    expect(find.textContaining('You hold only 1 Lumber now'), findsOneWidget);
    // What you chose is kept, for you to adjust rather than start over.
    expect(find.bySemanticsLabel(RegExp(r'^Lumber 3')), findsOneWidget);
    for (var i = 0; i < 2; i++) {
      await t.tap(find.byTooltip('One fewer Lumber').first);
      await t.pump();
    }
    expect(t.widget<FilledButton>(propose).onPressed, isNotNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a refused trade keeps the sheet open with the reason', (
    t,
  ) async {
    final port = await showGame(t, 'action');
    await openTrade(t, 'Trade');
    await compose(t);
    await t.tap(propose);
    await t.pump();
    port.replies.single.complete({
      'commandId': port.commands.single['commandId'],
      'status': 'REJECTED',
      'version': null,
      'error': {
        'code': 'INSUFFICIENT_RESOURCES',
        'message': 'Insufficient resources.',
        'retryable': false,
      },
    });
    await t.pumpAndSettle();
    expect(propose, findsOneWidget, reason: 'still open');
    expect(
      find.text('You do not have the resources for that action.'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^Lumber 1')),
      findsOneWidget,
      reason: 'composition kept',
    );
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('when the turn passes, the offer follows it and says so', (
    t,
  ) async {
    final port = await showGame(t, 'action');
    // Mira's turn: Noor can only offer to her.
    final miraTurn = next(uiSnapshot('action'), (public, _) {
      public['activePlayerId'] = mira;
      public['requiredPlayerIds'] = [mira];
      public['phaseId'] = '00000000-0000-4000-8000-0000000000e0';
      public['turnNumber'] = (public['turnNumber'] as int) + 1;
    });
    port.emit('snapshot', miraTurn);
    await t.pumpAndSettle();
    await openTrade(t, 'Offer a trade');
    await compose(t);
    // Mira ends her turn; Theo has not rolled yet, so nobody can trade.
    final waiting = next(miraTurn, (public, _) {
      public['activePlayerId'] = theo;
      public['requiredPlayerIds'] = [theo];
      public['phase'] = 'AWAIT_ROLL';
      public['phaseId'] = '00000000-0000-4000-8000-0000000000e1';
      public['turnNumber'] = (public['turnNumber'] as int) + 1;
      public['hasRolled'] = false;
      public['dice'] = null;
    });
    port.emit('snapshot', waiting);
    await t.pump();
    expect(t.widget<FilledButton>(propose).onPressed, isNull);
    expect(
      find.textContaining('Trading opens once Theo has rolled'),
      findsOneWidget,
    );
    // Theo rolls: the offer can go to him now, and the sheet says who gets it.
    port.emit(
      'snapshot',
      next(waiting, (public, _) {
        public['phase'] = 'ACTION';
        public['phaseId'] = '00000000-0000-4000-8000-0000000000e2';
        public['hasRolled'] = true;
        public['dice'] = [3, 4];
      }),
    );
    await t.pump();
    expect(find.textContaining('now goes to Theo'), findsOneWidget);
    await t.tap(propose);
    await t.pump();
    expect(port.commands.single['payload']['targetPlayerId'], theo);
    await t.pumpWidget(const SizedBox());
  });
}
