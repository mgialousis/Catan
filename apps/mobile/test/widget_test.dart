import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/main.dart';

void main() {
  testWidgets('unconfigured scaffold cannot start a guest session', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: IslandTableApp()));
    expect(find.text('Island Table'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    expect(button.onPressed, isNull);
    expect(find.textContaining('Local setup is needed'), findsOneWidget);
  });
}
