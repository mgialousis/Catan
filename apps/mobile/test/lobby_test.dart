import 'dart:convert';
import 'dart:io';
import 'package:island_table/core/protocol.dart';
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
}
