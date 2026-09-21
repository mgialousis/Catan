import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/core/connection.dart';
import 'package:island_table/game/controller.dart';
import 'package:island_table/game/game_screen.dart';
import 'package:island_table/game/table_stage.dart';
import 'game_model_test.dart' show uiProtocol, uiSnapshot;
import 'game_test.dart' show FakePort;

/// The whole island must be on screen without scrolling, in either orientation,
/// and the seats must stay on the map while that happens. Bounding the map by
/// the height once dropped the badges back into a row above the board, and not
/// bounding it at all ran the island off the bottom in landscape; these sizes
/// pin both halves against each other.
void main() {
  for (final (name, size) in [
    ('iPhone SE portrait', Size(375, 667)),
    ('iPhone SE landscape', Size(667, 375)),
    ('Android 360 portrait', Size(360, 800)),
    ('Android 360 landscape', Size(800, 360)),
    ('iPhone 15 portrait', Size(393, 852)),
    ('iPhone 15 landscape', Size(852, 393)),
  ]) {
    testWidgets('the map fills the width and seats the corners: $name', (
      t,
    ) async {
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
          child: const MaterialApp(home: GameScreen(isHost: true)),
        ),
      );
      await t.pump();
      port.emit('connected', true);
      port.emit('snapshot', uiSnapshot('action'));
      await t.pumpAndSettle();
      final map = t.getRect(find.byType(InteractiveViewer));
      final sea = t.getRect(find.byKey(const Key('island-sea')));
      // The island holds its proportions; the sea takes whatever width is
      // left, so a landscape screen is not mostly empty margin.
      expect(
        sea.width,
        closeTo(size.width > 820 ? 820 : size.width, 1),
        reason: '$name: the sea must fill the width (sea $sea, screen $size)',
      );
      expect(
        sea.bottom,
        lessThanOrEqualTo(t.getRect(find.byType(ResourceDock)).top),
        reason: '$name: the board card runs off the bottom',
      );
      // The whole island is visible without scrolling.
      expect(
        map.bottom,
        lessThanOrEqualTo(t.getRect(find.byType(ResourceDock)).top),
        reason:
            '$name: the island runs off the bottom (map $map, screen $size)',
      );
      expect(map.top, greaterThanOrEqualTo(0), reason: '$name: clipped at top');
      // In portrait the width binds and none of it is given up; in landscape
      // the height binds, and the map is scaled to fit rather than cropped.
      if (size.height > size.width) {
        expect(
          map.width,
          closeTo(size.width, 1),
          reason: '$name: portrait must give the map the whole width',
        );
      } else {
        // Landscape: the island is as tall as the space allows, and the sea
        // around it is wider than the island itself.
        expect(
          sea.width,
          greaterThan(map.width),
          reason: '$name: the sea should extend past the island',
        );
        expect(
          map.height,
          greaterThan(sea.height * 0.95),
          reason: '$name: the island should use the card height',
        );
      }
      // Every seat is on the map, not in a row above it.
      final seats = find
          .byWidgetPredicate((w) => w is PlayerBadge && w.compact)
          .evaluate()
          .length;
      expect(seats, greaterThan(0), reason: '$name: seats left the corners');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }
}
