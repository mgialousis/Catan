import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/core/connection.dart';
import 'package:island_table/game/controller.dart';
import 'package:island_table/game/game_screen.dart';
import 'package:island_table/game/table_stage.dart';
import 'game_model_test.dart' show uiProtocol, uiSnapshot;
import 'game_test.dart' show FakePort;

/// Fitting the map to the viewport height once shrank it to about 320 logical
/// pixels on an 800-wide phone in landscape, which also silently dropped the
/// corner seats back into a row above the board. These sizes pin both.
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
      // The map takes the screen's width, short of the 820 desktop cap.
      expect(
        map.width,
        closeTo(size.width > 820 ? 820 : size.width, 1),
        reason: '$name: the map must not be shrunk below the screen width',
      );
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
