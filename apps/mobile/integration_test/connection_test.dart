import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:island_table/main.dart' as app;
import 'package:island_table/core/config.dart';
import 'package:island_table/core/secure_session_storage.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('guest connects, persists native identity and refreshes', (
    tester,
  ) async {
    await app.main();
    await tester.pumpAndSettle();
    if (Supabase.instance.client.auth.currentSession == null) {
      expect(find.text('Connect as guest'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, 'Native guest');
      await tester.tap(find.text('Connect as guest'));
    }
    Future<void> waitConnected() async {
      for (var attempt = 0; attempt < 60; attempt++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find
            .text('Connected. Your guest session is ready.')
            .evaluate()
            .isNotEmpty) {
          return;
        }
      }
      fail('Authenticated server hello did not reach the Flutter UI');
    }

    await waitConnected();
    final auth = Supabase.instance.client.auth;
    final identity = auth.currentUser!.id;
    expect(auth.currentUser!.isAnonymous, isTrue);
    if (!kIsWeb) {
      const config = AppConfig.environment();
      final storage = SecureSessionStorage(
        'island-table-${Uri.parse(config.supabaseUrl).host}-session',
      );
      final persisted = await storage.accessToken();
      expect(persisted, isNotNull);
      expect((jsonDecode(persisted!) as Map)['user']['id'], identity);
    }
    await auth.refreshSession();
    await waitConnected();
    expect(auth.currentUser!.id, identity);
  });
}
