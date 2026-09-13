import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:island_table/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native guest creates, readies and closes a private lobby', (
    tester,
  ) async {
    await app.main();
    await tester.pumpAndSettle();
    Future<void> visible(String text) async {
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (find.text(text).evaluate().isNotEmpty) return;
      }
      fail('Expected screen text: $text');
    }

    final saved = Supabase.instance.client.auth.currentSession;
    if (saved == null) {
      expect(find.text('Connect as guest'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, 'Native guest');
      await tester.tap(find.text('Connect as guest'));
    }
    await visible('Create private table');
    final identity = Supabase.instance.client.auth.currentUser!.id;
    if (saved != null) expect(identity, saved.user.id);
    await tester.enterText(find.byType(TextFormField).first, 'Native guest');
    await tester.tap(find.text('Create private table'));
    await visible('Around the table');
    expect(find.text('Native guest (you)'), findsOneWidget);
    await tester.ensureVisible(find.text("I'm ready"));
    await tester.tap(find.text("I'm ready"));
    await visible('Not ready');
    await tester.ensureVisible(find.text('Start game'));
    final start = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Start game'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(
      start.onPressed,
      isNull,
      reason: 'One player cannot start a base game',
    );
    await tester.ensureVisible(find.text('Leave table'));
    await tester.tap(find.text('Leave table'));
    await tester.pumpAndSettle();
    expect(find.text('Leave this table?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Leave table'));
    await visible('Create private table');
    expect(Supabase.instance.client.auth.currentUser!.id, identity);
  });
}
