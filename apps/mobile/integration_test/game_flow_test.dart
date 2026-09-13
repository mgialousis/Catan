import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:island_table/core/connection.dart';
import 'package:island_table/core/protocol.dart';
import 'package:island_table/game/controller.dart';
import 'package:island_table/game/game_screen.dart';
import 'package:island_table/preview.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  Future<void> open(WidgetTester t, String scenario) async {
    final protocol = await Protocol.load();
    await t.pumpWidget(
      ProviderScope(
        key: ValueKey(scenario),
        overrides: [
          protocolProvider.overrideWithValue(protocol),
          gamePortProvider.overrideWithValue(PreviewPort(scenario)),
        ],
        child: MaterialApp(home: const GameScreen()),
      ),
    );
    await t.pump();
    container = ProviderScope.containerOf(t.element(find.byType(GameScreen)));
    await waitFor(t, () => container.read(gameProvider).snapshot != null);
  }

  Future<void> click(WidgetTester t, String label) async {
    final scroll = find
        .descendant(
          of: find.byKey(const Key('game-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    t.state<ScrollableState>(scroll).position.jumpTo(0);
    await t.pumpAndSettle();
    for (var i = 0; i < 40 && find.text(label).evaluate().isEmpty; i++) {
      final rect = t.getRect(scroll);
      await t.dragFrom(
        Offset(rect.right - 3, rect.center.dy),
        const Offset(0, -160),
      );
      await t.pumpAndSettle();
    }
    await t.ensureVisible(find.text(label).first);
    await t.pumpAndSettle();
    await t.tap(find.text(label).first);
    await t.pump();
  }

  Future<void> target(WidgetTester t, String label) async {
    await click(t, label);
    await t.pumpAndSettle();
    final field = find.byType(DropdownButtonFormField<String>);
    await t.ensureVisible(field);
    await t.pumpAndSettle();
    await t.tap(find.byType(DropdownButton<String>));
    await t.pumpAndSettle();
    final entries = find.byType(DropdownMenuItem<String>);
    // The popup duplicates the form's selected item; the last is a visible menu row.
    await t.tap(
      find
          .descendant(of: entries, matching: find.byType(Text))
          .hitTestable()
          .first,
    );
    await t.pumpAndSettle();
    final version = container.read(gameProvider).snapshot!.version;
    await click(t, 'Confirm placement');
    await waitFor(
      t,
      () =>
          container.read(gameProvider).pending == null &&
          container.read(gameProvider).snapshot!.version > version,
    );
  }

  testWidgets(
    'native setup, real placements, zoom and pan against the local engine',
    (t) async {
      await open(t, 'setup');
      for (var i = 0; i < 2; i++) {
        await target(t, 'Choose settlement');
        await target(t, 'Choose road');
      }
      expect(container.read(gameProvider).snapshot!.phase, 'AWAIT_ROLL');
      // Two real pointer gestures exercise InteractiveViewer, not a semantics-only shortcut.
      final scroll = find
          .descendant(
            of: find.byKey(const Key('game-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      t.state<ScrollableState>(scroll).position.jumpTo(0);
      await t.pumpAndSettle();
      final viewer = find.byType(InteractiveViewer),
          centre = t.getCenter(viewer);
      debugPrint(
        'Gesture board: ${t.getRect(viewer)}, surface: ${t.view.physicalSize / t.view.devicePixelRatio}',
      );
      final first = await t.startGesture(
        centre - const Offset(25, 0),
        pointer: 1,
      );
      final second = await t.startGesture(
        centre + const Offset(25, 0),
        pointer: 2,
      );
      await t.pump(const Duration(milliseconds: 16));
      for (var distance = 35.0; distance <= 90; distance += 10) {
        await first.moveTo(centre - Offset(distance, 0));
        await second.moveTo(centre + Offset(distance, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await first.up();
      await second.up();
      await t.pumpAndSettle();
      final transform = t
          .widget<InteractiveViewer>(viewer)
          .transformationController!;
      expect(transform.value.getMaxScaleOnAxis(), greaterThan(1));
      final before = transform.value.clone();
      await t.drag(viewer, const Offset(45, 30));
      await t.pumpAndSettle();
      expect(transform.value, isNot(before));
      await t.tap(find.byTooltip('Fit island'));
      await t.pumpAndSettle();
      expect(transform.value.getMaxScaleOnAxis(), 1);
      await click(t, 'Roll dice');
      await waitFor(
        t,
        () =>
            container.read(gameProvider).pending == null &&
            container.read(gameProvider).snapshot!.phase != 'AWAIT_ROLL',
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'native paid road, city and private development purchase advance engine state',
    (t) async {
      await open(t, 'action');
      await target(t, 'Build road');
      await target(t, 'Build city');
      final before = container.read(gameProvider).snapshot!.cards.length;
      await click(t, 'Buy development card');
      await waitFor(
        t,
        () =>
            container.read(gameProvider).pending == null &&
            container.read(gameProvider).snapshot!.cards.length == before + 1,
      );
      expect(
        container.read(gameProvider).snapshot!.own['publicPoints'],
        greaterThanOrEqualTo(3),
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('native winning purchase displays the real result', (t) async {
    await open(t, 'victory');
    await click(t, 'Buy development card');
    await waitFor(t, () => container.read(gameProvider).snapshot!.complete);
    expect(container.read(gameProvider).snapshot!.hand['totalPoints'], 10);
    final scroll = find
        .descendant(
          of: find.byKey(const Key('game-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    t.state<ScrollableState>(scroll).position.jumpTo(0);
    await t.pumpAndSettle();
    for (var i = 0; i < 10 && find.text('You won!').evaluate().isEmpty; i++) {
      final rect = t.getRect(scroll);
      await t.dragFrom(
        Offset(rect.right - 3, rect.center.dy),
        const Offset(0, -160),
      );
      await t.pumpAndSettle();
    }
    await t.ensureVisible(find.text('You won!'));
    expect(find.text('You won!'), findsOneWidget);
  });
}

Future<void> waitFor(WidgetTester t, bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
    if (condition()) return;
  }
  fail('The local engine did not confirm the expected state');
}
