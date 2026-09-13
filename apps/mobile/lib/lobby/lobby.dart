import 'dart:async';
import 'dart:convert';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../core/connection.dart';

Uri invitationUri(String code, {String webUrl = '', Uri? browserUri}) {
  final configured = Uri.tryParse(webUrl);
  final base =
      browserUri ??
      (configured?.scheme == 'https' && configured!.host.isNotEmpty
          ? configured
          : null);
  return base != null
      ? base.replace(queryParameters: {'invite': code}).removeFragment()
      : Uri(
          scheme: 'islandtable',
          host: 'join',
          queryParameters: {'invite': code},
        );
}

/// Copy [value], reporting what actually happened.
///
/// Flutter web can resolve `Clipboard.setData` while the browser refuses the
/// write or the hidden-textarea fallback silently no-ops, so a resolved future
/// is not evidence that anything was copied. Read the value back to tell the
/// difference. Reading can itself be refused, so an unreadable clipboard is
/// reported as unknown rather than as failure.
///
/// Returns true when the value is confirmed on the clipboard, false when the
/// clipboard holds something else, and null when it cannot be verified.
Future<bool?> copyToClipboard(String value) async {
  try {
    await Clipboard.setData(ClipboardData(text: value));
  } catch (_) {
    return false;
  }
  try {
    final read = await Clipboard.getData(Clipboard.kTextPlain);
    final text = read?.text;
    return text == null ? null : text == value;
  } catch (_) {
    return null;
  }
}

String? invitationFromUri(Uri uri) {
  final fragment = Uri.tryParse(uri.fragment);
  final code =
      uri.queryParameters['invite'] ?? fragment?.queryParameters['invite'];
  if (code == null || code.length > 32) return null;
  return normalizeInvitation(code);
}

String? normalizeInvitation(String text) {
  final code = text.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
  return RegExp(r'^[0-9A-HJKMNP-TV-Z]{10}$').hasMatch(code) ? code : null;
}

class LobbyStore {
  static const key = 'island-table-lobby-v1';
  Future<String?> read() async => kIsWeb
      ? (await SharedPreferences.getInstance()).getString(key)
      : const FlutterSecureStorage().read(key: key);
  Future<void> write(String value) async {
    if (kIsWeb) {
      await (await SharedPreferences.getInstance()).setString(key, value);
    } else {
      await const FlutterSecureStorage().write(key: key, value: value);
    }
  }
}

class LobbyView {
  const LobbyView({
    this.loaded = false,
    this.nickname = '',
    this.invitationInput = '',
    this.room,
    this.playerId,
    this.online = const {},
    this.invitation,
    this.pending = false,
    this.sending = false,
    this.message,
  });
  final bool loaded, pending, sending;
  final String nickname, invitationInput;
  final Map<String, dynamic>? room;
  final String? playerId, invitation, message;
  final Set<String> online;
  bool get isHost => room != null && playerId == room!['hostPlayerId'];
  List<Map<String, dynamic>> get players => (room?['players'] as List? ?? [])
      .map((p) => Map<String, dynamic>.from(p as Map))
      .toList();
  Map<String, dynamic>? get own {
    for (final player in players) {
      if (player['id'] == playerId) return player;
    }
    return null;
  }

  bool get eligible =>
      players.length >= 3 &&
      players.every((p) => p['ready'] == true && online.contains(p['id']));
  LobbyView copy({
    bool? loaded,
    String? nickname,
    String? invitationInput,
    Map<String, dynamic>? room,
    String? playerId,
    Set<String>? online,
    String? invitation,
    bool? pending,
    bool? sending,
    String? message,
    bool clearMessage = false,
    bool clearRoom = false,
    bool clearInvitation = false,
  }) => LobbyView(
    loaded: loaded ?? this.loaded,
    nickname: nickname ?? this.nickname,
    invitationInput: invitationInput ?? this.invitationInput,
    room: clearRoom ? null : room ?? this.room,
    playerId: clearRoom ? null : playerId ?? this.playerId,
    online: clearRoom ? {} : online ?? this.online,
    invitation: clearRoom || clearInvitation
        ? null
        : invitation ?? this.invitation,
    pending: pending ?? this.pending,
    sending: sending ?? this.sending,
    message: clearMessage ? null : message ?? this.message,
  );
}

final lobbyStoreProvider = Provider<LobbyStore>((ref) => LobbyStore());
final lobbyProvider = NotifierProvider<LobbyController, LobbyView>(
  LobbyController.new,
);

class LobbyController extends Notifier<LobbyView> {
  StreamSubscription<MapEntry<String, dynamic>>? _events;
  StreamSubscription<Uri>? _links;
  Map<String, dynamic>? _pending;
  String? _savedRoom, _subject;
  bool _disposed = false;
  Future<void> _writes = Future.value();
  Timer? _syncTimer;
  @override
  LobbyView build() {
    final connection = ref.read(connectionProvider.notifier);
    _events = connection.events.listen(_event);
    ref.listen(connectionProvider, (_, next) {
      if (next.status == ConnectionStatus.connected) {
        if (_subject != null && connection.subject != _subject) {
          _pending = null;
          _savedRoom = null;
          state = state.copy(clearRoom: true, pending: false);
        }
        _subject = connection.subject;
        synchronize();
        unawaited(_save());
      }
    });
    _syncTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => synchronize(),
    );
    ref.onDispose(() {
      _disposed = true;
      _events?.cancel();
      _links?.cancel();
      _syncTimer?.cancel();
    });
    return const LobbyView();
  }

  Future<void> initialize() async {
    try {
      final raw = await ref.read(lobbyStoreProvider).read();
      final saved = raw == null
          ? <String, dynamic>{}
          : jsonDecode(raw) as Map<String, dynamic>;
      if (_disposed) return;
      _subject = saved['subject'] as String?;
      _savedRoom = saved['roomId'] as String?;
      _pending = saved['pending'] == null
          ? null
          : Map<String, dynamic>.from(saved['pending'] as Map);
      state = state.copy(
        loaded: true,
        nickname: saved['nickname'] as String? ?? '',
        invitationInput: saved['invitationInput'] as String? ?? '',
        invitation: saved['invitation'] as String?,
        pending: _pending != null,
      );
      if (kIsWeb) {
        await acceptLink(Uri.base);
      } else {
        final links = AppLinks();
        _links = links.uriLinkStream.listen(
          (uri) => unawaited(acceptLink(uri)),
        );
        final first = await links.getInitialLink();
        if (first != null) await acceptLink(first);
      }
      if (!_disposed &&
          ref.read(configProvider).isConfigured &&
          ref.read(supabaseProvider).auth.currentSession != null) {
        await ref.read(connectionProvider.notifier).connect();
      }
    } catch (_) {
      if (!_disposed) {
        state = state.copy(
          loaded: true,
          message: 'Your saved table could not be restored. Please reconnect.',
        );
      }
    }
  }

  Future<void> acceptLink(Uri uri) async {
    final code = invitationFromUri(uri);
    if (code == null || _disposed) return;
    state = state.copy(invitationInput: code);
    await _save();
  }

  Future<void> saveEntry(String name, String code) async {
    state = state.copy(
      nickname: name.trim(),
      invitationInput: code.trim(),
      clearMessage: true,
    );
    await _save();
  }

  Future<void> _save() {
    final value = jsonEncode({
      'subject': _subject,
      'roomId': _savedRoom,
      'nickname': state.nickname,
      'invitationInput': state.invitationInput,
      'invitation': state.invitation,
      'pending': _pending,
    });
    final store = ref.read(lobbyStoreProvider);
    _writes = _writes.catchError((_) {}).then((_) => store.write(value));
    return _writes;
  }

  void synchronize() {
    if (_savedRoom != null &&
        ref.read(connectionProvider).status == ConnectionStatus.connected) {
      ref
          .read(connectionProvider.notifier)
          .subscribeRoom(
            _savedRoom!,
            lastRevision: state.room?['revision'] as int?,
          );
    }
  }

  void _event(MapEntry<String, dynamic> event) {
    if (_disposed) return;
    if (event.key == 'session.revoked') {
      _pending = null;
      _savedRoom = null;
      _subject = null;
      state = state.copy(clearRoom: true, pending: false, sending: false);
      unawaited(_save());
      return;
    }
    if (event.key.startsWith('game.')) return;
    if (event.key == 'session.foreground') {
      synchronize();
      return;
    }
    final value = Map<String, dynamic>.from(event.value as Map);
    switch (event.key) {
      case 'session.membership':
        final changed = _savedRoom != null && _savedRoom != value['roomId'];
        _savedRoom = value['roomId'] as String;
        if (changed) state = state.copy(clearRoom: true);
        state = state.copy(
          playerId: value['playerId'] as String,
          clearInvitation: changed,
        );
        unawaited(_save());
      case 'room.snapshot':
        if (_savedRoom != value['roomId']) return;
        if (state.room?['roomId'] == value['roomId'] &&
            (state.room!['revision'] as int) > (value['revision'] as int)) {
          return;
        }
        state = state.copy(
          room: value,
          clearInvitation: value['hostPlayerId'] != state.playerId,
        );
        if (state.own != null) {
          state = state.copy(nickname: state.own!['nickname'] as String);
        }
        unawaited(_save());
      case 'presence.update':
        if (_savedRoom == value['roomId']) {
          state = state.copy(
            online: Set<String>.from(value['onlinePlayerIds'] as List),
          );
        }
      case 'session.error':
        if (value['code'] == 'MEMBERSHIP_ENDED' ||
            value['code'] == 'FORBIDDEN') {
          _savedRoom = null;
          state = state.copy(
            clearRoom: true,
            message: value['message'] as String,
          );
          unawaited(_save());
        } else if (![
          'UNAUTHENTICATED',
          'TOKEN_EXPIRED',
        ].contains(value['code'])) {
          state = state.copy(message: value['message'] as String);
        }
    }
  }

  Future<void> create() => command('CREATE_ROOM', {
    'nickname': state.nickname,
    'settings': {
      'maxPlayers': 4,
      'turnLimitSeconds': null,
      'boardMode': 'STANDARD_RANDOM',
      'rulesVersion': 'base-2020-v1',
    },
  }, initial: true);
  Future<void> join() async {
    final code = normalizeInvitation(state.invitationInput);
    if (code == null) {
      state = state.copy(message: 'Enter the 10-character invitation code.');
      return;
    }
    await command('JOIN_ROOM', {
      'nickname': state.nickname,
      'invitationCode': code,
    }, initial: true);
  }

  Future<void> command(
    String type,
    Map<String, dynamic> payload, {
    bool initial = false,
  }) async {
    if (_pending != null || state.sending) return;
    if (ref.read(connectionProvider).status != ConnectionStatus.connected) {
      state = state.copy(message: 'Reconnect before changing your table.');
      return;
    }
    _pending = {
      'protocolVersion': 1,
      'commandId': const Uuid().v4(),
      'roomId': initial ? null : state.room?['roomId'],
      'expectedVersion': initial ? null : state.room?['revision'],
      'expectedPhaseId': null,
      'type': type,
      'payload': payload,
    };
    if (!ref.read(protocolProvider).accepts('roomCommand', _pending)) {
      _pending = null;
      state = state.copy(
        message: 'Check the nickname and table details before trying again.',
      );
      return;
    }
    state = state.copy(pending: true, clearMessage: true);
    try {
      await _save();
    } catch (_) {
      _pending = null;
      state = state.copy(
        pending: false,
        message: 'Could not save this action. Please retry.',
      );
      return;
    }
    await retryPending();
  }

  Future<void> retryPending() async {
    if (_pending == null || state.sending) return;
    final intent = _pending!;
    state = state.copy(sending: true, clearMessage: true);
    try {
      final ack = await ref
          .read(connectionProvider.notifier)
          .sendCommand(intent);
      if (_disposed) return;
      if (ack['commandId'] != intent['commandId']) {
        state = state.copy(
          sending: false,
          message:
              'The reply did not match your action. Retry the saved action.',
        );
        return;
      }
      if (ack['status'] == 'REJECTED' &&
          (ack['error'] as Map)['retryable'] == true) {
        state = state.copy(
          sending: false,
          message: (ack['error'] as Map)['message'] as String,
        );
        return;
      }
      _pending = null;
      state = state.copy(pending: false, sending: false);
      if (ack['status'] == 'ACCEPTED') {
        final result = ack['result'] as Map?;
        if (intent['type'] == 'LEAVE_LOBBY') {
          _savedRoom = null;
          state = state.copy(clearRoom: true, invitationInput: '');
        } else {
          _savedRoom = ack['roomId'] as String;
          state = state.copy(
            invitation: result?['invitationCode'] as String?,
            playerId: result?['playerId'] as String?,
            invitationInput: '',
          );
          synchronize();
        }
      } else {
        state = state.copy(message: (ack['error'] as Map)['message'] as String);
        synchronize();
      }
      await _save();
    } catch (_) {
      if (!_disposed) {
        state = state.copy(
          sending: false,
          message:
              'The reply was interrupted. Retry the saved action to check its result.',
        );
      }
    }
  }

  Future<void> dismissClosed() async {
    if (state.pending) return;
    _savedRoom = null;
    state = state.copy(
      clearRoom: true,
      invitationInput: '',
      clearMessage: true,
    );
    await _save();
  }
}
