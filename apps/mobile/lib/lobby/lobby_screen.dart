import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/connection.dart';
import 'lobby.dart';
import '../game/live.dart';

class LobbyScreen extends ConsumerStatefulWidget {
  const LobbyScreen({super.key});
  @override
  ConsumerState<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends ConsumerState<LobbyScreen>
    with WidgetsBindingObserver {
  final _nickname = TextEditingController();
  final _code = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _filled = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(() => ref.read(lobbyProvider.notifier).initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nickname.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(connectionProvider.notifier).resume();
    }
  }

  Future<bool> _saveEntry() async {
    if (!_form.currentState!.validate()) return false;
    await ref
        .read(lobbyProvider.notifier)
        .saveEntry(_nickname.text, _code.text);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final lobby = ref.watch(lobbyProvider);
    final connection = ref.watch(connectionProvider);
    final configured = ref.watch(configProvider).isConfigured;
    final connected = connection.status == ConnectionStatus.connected;
    final busy = lobby.pending || !connected;
    ref.listen(lobbyProvider, (_, next) {
      if (next.loaded && !_filled) {
        _filled = true;
        _nickname.text = next.nickname;
        _code.text = next.invitationInput;
      }
      if (next.invitationInput.isNotEmpty &&
          next.invitationInput != _code.text) {
        _code.text = next.invitationInput;
      }
    });
    final subject = ref.read(connectionProvider.notifier).subject;
    if (subject != null &&
        lobby.playerId != null &&
        ['ACTIVE', 'PAUSED', 'FINISHED'].contains(lobby.room?['status'])) {
      final roomId = lobby.room!['roomId'] as String;
      return LiveGameShell(
        key: ValueKey('$subject:$roomId:${lobby.playerId}'),
        subject: subject,
        roomId: roomId,
        playerId: lobby.playerId!,
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xfff5f2e9),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.landscape_rounded,
                        size: 40,
                        color: Color(0xff256f61),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Catan',
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    lobby.room == null
                        ? 'A little island. Your favourite people.'
                        : 'Your private table',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 24),
                  if (!configured)
                    const Text(
                      'Local setup is needed. Follow the README to configure the app.',
                    ),
                  if (configured)
                    Row(
                      children: [
                        Icon(
                          connected ? Icons.check_circle : Icons.wifi_off,
                          size: 18,
                          color: connected ? const Color(0xff256f61) : null,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(connection.message)),
                      ],
                    ),
                  if (!connected &&
                      ![
                        ConnectionStatus.idle,
                        ConnectionStatus.authenticating,
                        ConnectionStatus.connecting,
                      ].contains(connection.status))
                    TextButton(
                      onPressed: () =>
                          ref.read(connectionProvider.notifier).connect(),
                      child: const Text('Reconnect'),
                    ),
                  const SizedBox(height: 20),
                  if (lobby.message != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          lobby.message!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                  if (lobby.pending)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            Text(
                              lobby.sending
                                  ? 'Saving your action…'
                                  : 'An action is waiting for a reply.',
                            ),
                            if (!lobby.sending)
                              TextButton(
                                onPressed: connected
                                    ? () => ref
                                          .read(lobbyProvider.notifier)
                                          .retryPending()
                                    : null,
                                child: const Text('Retry saved action'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (lobby.room == null)
                    _entry(lobby, configured, connected)
                  else if (lobby.room!['status'] != 'LOBBY')
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            const Icon(Icons.event_seat_outlined, size: 40),
                            const SizedBox(height: 12),
                            Text(
                              lobby.room!['status'] == 'EXPIRED'
                                  ? 'This invitation has expired.'
                                  : 'This table is closed.',
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: lobby.pending
                                  ? null
                                  : () => ref
                                        .read(lobbyProvider.notifier)
                                        .dismissClosed(),
                              child: const Text('Back to tables'),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    ..._table(lobby, busy),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _entry(LobbyView lobby, bool configured, bool connected) => Form(
    key: _form,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Take a seat',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'Choose a nickname, then create a table or use an invitation from a friend.',
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: _nickname,
              enabled: !lobby.pending,
              textCapitalization: TextCapitalization.words,
              maxLength: 20,
              decoration: const InputDecoration(
                labelText: 'Nickname',
                border: OutlineInputBorder(),
              ),
              validator: (value) => (value?.trim().characters.length ?? 0) < 2
                  ? 'Use at least 2 characters.'
                  : null,
            ),
            const SizedBox(height: 8),
            if (!connected)
              FilledButton.icon(
                onPressed:
                    configured &&
                        lobby.loaded &&
                        ![
                          ConnectionStatus.authenticating,
                          ConnectionStatus.connecting,
                        ].contains(ref.read(connectionProvider).status)
                    ? () async {
                        if (await _saveEntry()) {
                          await ref.read(connectionProvider.notifier).connect();
                        }
                      }
                    : null,
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Connect as guest'),
              ),
            if (connected) ...[
              FilledButton.icon(
                onPressed: lobby.pending
                    ? null
                    : () async {
                        if (await _saveEntry()) {
                          await ref.read(lobbyProvider.notifier).create();
                        }
                      },
                icon: const Icon(Icons.add),
                label: const Text('Create private table'),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  'or join your friends',
                  textAlign: TextAlign.center,
                ),
              ),
            ],
            const SizedBox(height: 16),
            TextFormField(
              controller: _code,
              enabled: !lobby.pending,
              textCapitalization: TextCapitalization.characters,
              maxLength: 32,
              decoration: const InputDecoration(
                labelText: 'Invitation code',
                hintText: 'ABCDE-FGHJK',
                border: OutlineInputBorder(),
              ),
            ),
            if (connected)
              OutlinedButton.icon(
                onPressed: lobby.pending
                    ? null
                    : () async {
                        if (await _saveEntry()) {
                          await ref.read(lobbyProvider.notifier).join();
                        }
                      },
                icon: const Icon(Icons.group_add_outlined),
                label: const Text('Join table'),
              ),
            const SizedBox(height: 16),
            const Text(
              'Your guest identity stays on this device. A nickname cannot recover a seat if app data is erased.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );
  List<Widget> _table(LobbyView lobby, bool disabled) {
    final controller = ref.read(lobbyProvider.notifier);
    final settings = lobby.room!['settings'] as Map;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Around the table',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  Text('${lobby.players.length} / 4'),
                ],
              ),
              const SizedBox(height: 12),
              for (final player in lobby.players) _player(player, lobby),
              for (var i = lobby.players.length; i < 4; i++)
                const ListTile(
                  leading: Icon(Icons.chair_outlined),
                  title: Text('An open seat'),
                  subtitle: Text('Invite a friend'),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: disabled || lobby.own == null
                    ? null
                    : () => controller.command('SET_READY', {
                        'ready': lobby.own!['ready'] != true,
                      }),
                icon: Icon(
                  lobby.own?['ready'] == true ? Icons.undo : Icons.check,
                ),
                label: Text(
                  lobby.own?['ready'] == true ? 'Not ready' : "I'm ready",
                ),
              ),
              TextButton(
                onPressed: disabled ? null : () => _editProfile(lobby),
                child: const Text('Edit nickname & colour'),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      if (lobby.isHost)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Invite your friends',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                if (lobby.invitation != null) ...[
                  SelectableText(
                    '${lobby.invitation!.substring(0, 5)}-${lobby.invitation!.substring(5)}',
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      context,
                    ).textTheme.headlineSmall?.copyWith(letterSpacing: 3),
                  ),
                  const SizedBox(height: 12),
                  // Always visible so sharing never depends on the clipboard:
                  // a browser can refuse the write, or silently no-op it.
                  SelectableText(
                    invitationUri(
                      lobby.invitation!,
                      webUrl: ref.read(configProvider).webUrl,
                      browserUri: kIsWeb ? Uri.base : null,
                    ).toString(),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final link = invitationUri(
                        lobby.invitation!,
                        webUrl: ref.read(configProvider).webUrl,
                        browserUri: kIsWeb ? Uri.base : null,
                      ).toString();
                      final copied = await copyToClipboard(link);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(switch (copied) {
                            true => 'Invitation link copied',
                            false =>
                              'Could not reach the clipboard. Select the link above and copy it.',
                            null =>
                              'Could not confirm the copy. If nothing pastes, select the link above.',
                          }),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy invitation link'),
                  ),
                ] else
                  const Text('Create a fresh invitation to share this table.'),
                TextButton(
                  onPressed: disabled
                      ? null
                      : () => controller.command('ROTATE_INVITATION', {}),
                  child: Text(
                    lobby.invitation == null
                        ? 'Create invitation'
                        : 'Replace invitation code',
                  ),
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Table settings',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                key: ValueKey(settings['turnLimitSeconds']),
                initialValue: settings['turnLimitSeconds'] as int? ?? 0,
                decoration: const InputDecoration(
                  labelText: 'Time per turn',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('No time limit')),
                  DropdownMenuItem(value: 60, child: Text('60 seconds')),
                  DropdownMenuItem(value: 120, child: Text('120 seconds')),
                  DropdownMenuItem(value: 180, child: Text('180 seconds')),
                ],
                onChanged: disabled || !lobby.isHost
                    ? null
                    : (value) => controller.command('UPDATE_SETTINGS', {
                        'turnLimitSeconds': value == 0 ? null : value,
                        'boardMode': 'STANDARD_RANDOM',
                      }),
              ),
              const SizedBox(height: 12),
              const Text('Base game · 3–4 players · Random island'),
              if (lobby.isHost) ...[
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: disabled || !lobby.eligible
                      ? null
                      : () => controller.command('START_GAME', {}),
                  child: const Text('Start game'),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                lobby.eligible
                    ? 'Everyone is ready. The host can start the game.'
                    : 'Gather 3–4 players. Everyone must be online and ready.',
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      TextButton.icon(
        onPressed: disabled
            ? null
            : () async {
                final leave = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Leave this table?'),
                    content: Text(
                      lobby.players.length == 1
                          ? 'You are the last player. Leaving will close the table.'
                          : 'Your seat will become available. You can rejoin with a valid invitation while a seat is free.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Stay'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Leave table'),
                      ),
                    ],
                  ),
                );
                if (leave == true) await controller.command('LEAVE_LOBBY', {});
              },
        icon: const Icon(Icons.logout),
        label: const Text('Leave table'),
      ),
    ];
  }

  Widget _player(Map<String, dynamic> player, LobbyView lobby) {
    const colours = {
      'RED': Color(0xffac3c35),
      'BLUE': Color(0xff2965a1),
      'WHITE': Color(0xffe0ddd2),
      'ORANGE': Color(0xffd77622),
    };
    final colour = player['colour'] as String? ?? 'WHITE';
    final you = player['id'] == lobby.playerId;
    final online = lobby.online.contains(player['id']);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: colours[colour],
        foregroundColor: colour == 'WHITE' ? Colors.black : Colors.white,
        child: Text('${(player['seatIndex'] as int) + 1}'),
      ),
      title: Text(
        '${player['nickname']}${you ? ' (you)' : ''}',
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${colour.toLowerCase()} · ${player['id'] == lobby.room!['hostPlayerId'] ? 'host · ' : ''}${online ? 'online' : 'offline'}',
      ),
      trailing: Icon(
        player['ready'] == true
            ? Icons.check_circle
            : Icons.radio_button_unchecked,
        semanticLabel: player['ready'] == true ? 'Ready' : 'Not ready',
        color: player['ready'] == true ? const Color(0xff256f61) : null,
      ),
    );
  }

  Future<void> _editProfile(LobbyView lobby) async {
    final own = lobby.own;
    if (own == null) return;
    final name = TextEditingController(text: own['nickname'] as String);
    var colour = own['colour'] as String;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Your place at the table'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  maxLength: 20,
                  decoration: const InputDecoration(labelText: 'Nickname'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: colour,
                  decoration: const InputDecoration(labelText: 'Piece colour'),
                  items: ['RED', 'BLUE', 'WHITE', 'ORANGE']
                      .map(
                        (c) => DropdownMenuItem(
                          value: c,
                          enabled: !lobby.players.any(
                            (p) => p['id'] != own['id'] && p['colour'] == c,
                          ),
                          child: Text(c.toLowerCase()),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => colour = value!),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save profile'),
            ),
          ],
        ),
      ),
    );
    if (result == true && mounted) {
      await ref.read(lobbyProvider.notifier).command('SET_PROFILE', {
        'nickname': name.text.trim(),
        'colour': colour,
      });
    }
    // The dialog's reverse animation still holds its TextField until the next frame.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    name.dispose();
  }
}
