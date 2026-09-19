import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/core/config.dart';
import 'package:island_table/core/connection.dart';
import 'package:island_table/lobby/lobby.dart';
import 'package:island_table/lobby/lobby_screen.dart';
import 'lobby_test.dart' show ReplyConnection;

/// Connected, with no room yet: the home page a player actually lands on.
class HomeLobby extends LobbyController {
  @override
  LobbyView build() => const LobbyView(loaded: true, nickname: 'Mira');

  @override
  Future<void> initialize() async {}
}

class InvitationLobby extends LobbyController {
  @override
  LobbyView build() => const LobbyView(
    loaded: true,
    playerId: 'host',
    invitation: 'ABCDEFGHJK',
    room: {
      'status': 'LOBBY',
      'hostPlayerId': 'host',
      'players': [],
      'settings': {},
    },
  );

  @override
  Future<void> initialize() async {}
}

Widget home() => ProviderScope(
  overrides: [
    lobbyProvider.overrideWith(HomeLobby.new),
    connectionProvider.overrideWith(ReplyConnection.new),
    configProvider.overrideWithValue(
      const AppConfig(
        apiUrl: 'https://api.example.test',
        supabaseUrl: 'https://auth.example.test',
        anonKey: 'test',
        webUrl: 'https://island.example.test',
      ),
    ),
  ],
  child: const MaterialApp(home: LobbyScreen()),
);

void main() {
  for (final size in [const Size(320, 900), const Size(700, 1200)]) {
    testWidgets('the home page offers three ways in at $size', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(home());
      await t.pumpAndSettle();
      for (final label in ['Practice', 'Multiplayer', 'How to play']) {
        expect(find.text(label), findsOneWidget, reason: '$label at $size');
      }
      // Practice is the landing choice: it needs nobody else to be free.
      expect(find.text('Start practice game'), findsOneWidget);
      expect(find.text('Create private table'), findsNothing);

      await t.tap(find.text('Multiplayer'));
      await t.pumpAndSettle();
      expect(find.text('Create private table'), findsOneWidget);
      expect(find.text('Join table'), findsOneWidget);
      expect(find.text('Start practice game'), findsNothing);

      await t.tap(find.text('How to play'));
      await t.pumpAndSettle();
      expect(find.text('Winning'), findsOneWidget);
      expect(find.textContaining('First to ten points'), findsOneWidget);
      expect(find.text('Create private table'), findsNothing);
      expect(t.takeException(), isNull, reason: 'no overflow at $size');
    });
  }

  for (final outcome in ['confirmed', 'refused', 'unverifiable']) {
    testWidgets('invitation remains selectable when copy is $outcome', (
      t,
    ) async {
      const link = 'https://island.example.test?invite=ABCDEFGHJK';
      final messenger = t.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          expect((call.arguments as Map)['text'], link);
          if (outcome == 'refused') throw PlatformException(code: 'denied');
        }
        if (call.method == 'Clipboard.getData') {
          if (outcome == 'unverifiable') {
            throw PlatformException(code: 'denied');
          }
          return {'text': link};
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            lobbyProvider.overrideWith(InvitationLobby.new),
            connectionProvider.overrideWith(ReplyConnection.new),
            configProvider.overrideWithValue(
              const AppConfig(
                apiUrl: 'https://api.example.test',
                supabaseUrl: 'https://auth.example.test',
                anonKey: 'test',
                webUrl: 'https://island.example.test',
              ),
            ),
          ],
          child: const MaterialApp(home: LobbyScreen()),
        ),
      );
      await t.pumpAndSettle();
      expect(
        find.byWidgetPredicate((w) => w is SelectableText && w.data == link),
        findsOneWidget,
      );
      final copy = find.text('Copy invitation link');
      await t.ensureVisible(copy);
      await t.tap(copy);
      await t.pumpAndSettle();
      final message = switch (outcome) {
        'confirmed' => 'Invitation link copied',
        'refused' =>
          'Could not reach the clipboard. Select the link above and copy it.',
        _ =>
          'Could not confirm the copy. If nothing pastes, select the link above.',
      };
      expect(find.text(message), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
