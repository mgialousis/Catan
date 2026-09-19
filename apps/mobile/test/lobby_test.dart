import 'dart:convert';
import 'dart:io';
import 'package:island_table/core/protocol.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:island_table/core/connection.dart';
import 'package:island_table/lobby/lobby.dart';

class MemoryStore extends LobbyStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    this.value = value;
  }
}

class ReplyConnection extends ConnectionController {
  final commands = <Map<String, dynamic>>[];
  @override
  ConnectionView build() =>
      const ConnectionView(ConnectionStatus.connected, 'Connected');
  @override
  Stream<MapEntry<String, dynamic>> get events => const Stream.empty();
  @override
  Future<Map<String, dynamic>> sendCommand(Map<String, dynamic> command) async {
    commands.add(command);
    return {
      'commandId': commands.length == 1 ? 'mismatched' : command['commandId'],
      'status': 'REJECTED',
      'error': {
        'code': 'ROOM_UNAVAILABLE',
        'message': 'Unavailable',
        'retryable': false,
      },
    };
  }
}

void main() {
  // The reported bug: Flutter web resolved setData while nothing reached the
  // clipboard, so the UI claimed success. Verify by reading back, and keep an
  // unreadable clipboard distinct from a failed write.
  group('copyToClipboard', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    void mock(Future<Object?>? Function(MethodCall call)? handler) =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, handler);
    tearDown(() => mock(null));

    test('confirms a write the clipboard actually accepted', () async {
      String? stored;
      mock((call) async {
        if (call.method == 'Clipboard.setData') {
          stored = (call.arguments as Map)['text'] as String;
          return null;
        }
        if (call.method == 'Clipboard.getData') return {'text': stored};
        return null;
      });
      expect(await copyToClipboard('https://example.test/?invite=ABC'), isTrue);
    });

    test('reports failure when the write silently did not take', () async {
      mock((call) async {
        if (call.method == 'Clipboard.setData') {
          return null; // resolves, writes nothing
        }
        if (call.method == 'Clipboard.getData') {
          return {'text': 'something else'};
        }
        return null;
      });
      expect(
        await copyToClipboard('https://example.test/?invite=ABC'),
        isFalse,
      );
    });

    test('reports unknown when the clipboard cannot be read back', () async {
      mock((call) async {
        if (call.method == 'Clipboard.setData') return null;
        if (call.method == 'Clipboard.getData') {
          throw PlatformException(code: 'denied');
        }
        return null;
      });
      expect(await copyToClipboard('https://example.test/?invite=ABC'), isNull);
    });

    test('reports failure when the write itself is refused', () async {
      mock((call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'denied');
        }
        return null;
      });
      expect(
        await copyToClipboard('https://example.test/?invite=ABC'),
        isFalse,
      );
    });
  });

  test(
    'native invitations and rematches can open the free web client on an iPhone',
    () {
      const code = 'ABCDEFGHJK';
      final uri = invitationUri(code, webUrl: 'https://island.example.invalid');
      expect(
        uri.toString(),
        'https://island.example.invalid?invite=ABCDEFGHJK',
      );
      expect(invitationFromUri(uri), code);
      expect(invitationUri(code).scheme, 'islandtable');
      expect(
        invitationUri(
          code,
          browserUri: Uri.parse('http://127.0.0.1:8080/#/old'),
        ).fragment,
        '',
      );
    },
  );

  test(
    'mismatched acknowledgement unlocks retry while preserving the saved intent',
    () async {
      final connection = ReplyConnection(), store = MemoryStore();
      final container = ProviderContainer(
        overrides: [
          connectionProvider.overrideWith(() => connection),
          lobbyStoreProvider.overrideWithValue(store),
          protocolProvider.overrideWithValue(
            Protocol(
              jsonDecode(
                    File(
                      '../../packages/protocol/schemas/v1.json',
                    ).readAsStringSync(),
                  )
                  as Map<String, dynamic>,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final lobby = container.read(lobbyProvider.notifier);
      await lobby.saveEntry('Tester', '');
      await lobby.create();
      expect(container.read(lobbyProvider).sending, false);
      expect(container.read(lobbyProvider).pending, true);
      expect(store.value, contains(connection.commands.first['commandId']));
      await lobby.retryPending();
      expect(connection.commands[1], connection.commands[0]);
      expect(container.read(lobbyProvider).pending, false);
    },
  );
  test('invitation survives web and native link formats', () {
    expect(
      invitationFromUri(Uri.parse('http://localhost:8080/?invite=abcde-fghjk')),
      'ABCDEFGHJK',
    );
    expect(
      invitationFromUri(Uri.parse('islandtable://join?invite=ABCDEFGHJK')),
      'ABCDEFGHJK',
    );
    expect(
      invitationFromUri(Uri.parse('https://example.test/#/?invite=ABCDEFGHJK')),
      'ABCDEFGHJK',
    );
    expect(
      invitationFromUri(Uri.parse('https://example.test/?invite=ABCDEFGHIJ')),
      isNull,
    );
    expect(normalizeInvitation('ABCDE'), isNull);
  });
  test(
    'only the membership owner is selected; start UI requires connected ready roster',
    () {
      final players = List.generate(
        3,
        (i) => {'id': '$i', 'nickname': 'Guest $i', 'ready': true},
      );
      final view = LobbyView(
        playerId: '1',
        online: {'0', '1', '2'},
        room: {'hostPlayerId': '0', 'players': players},
      );
      expect(view.own!['nickname'], 'Guest 1');
      expect(view.isHost, false);
      expect(view.eligible, true);
      expect(view.copy(online: {'0', '1'}).eligible, false);
      expect(view.copy(clearRoom: true).own, isNull);
    },
  );

  test('a practice table is eligible although its bots hold no connection', () {
    final players = [
      {'id': '0', 'nickname': 'You', 'ready': true},
      for (var i = 1; i < 4; i++)
        {'id': '$i', 'nickname': 'Bot $i', 'ready': true, 'kind': 'BOT'},
    ];
    // Only the person is ever online; requiring the bots there would leave a
    // practice table permanently unable to start.
    final view = LobbyView(
      playerId: '0',
      online: {'0'},
      room: {'hostPlayerId': '0', 'players': players},
    );
    expect(view.bots, true);
    expect(view.eligible, true);
    // A table of people still needs all of them present.
    final people = players.map((p) => {...p}..remove('kind')).toList();
    expect(
      LobbyView(
        playerId: '0',
        online: {'0'},
        room: {'hostPlayerId': '0', 'players': people},
      ).eligible,
      false,
    );
  });
}
