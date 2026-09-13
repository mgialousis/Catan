import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'board.dart';
import 'controller.dart';
import 'countdown.dart';
import 'model.dart';

const _sand = Color(0xfff5f2e9);
const _teal = Color(0xff256f61);

/// Phase-specific guidance. Every supported command is reachable from here.
const _prompts = <String, String>{
  'SETUP_SETTLEMENT': 'Choose a junction for your starting settlement.',
  'SETUP_ROAD': 'Place a road touching the settlement you just built.',
  'AWAIT_ROLL': 'Roll the dice to begin your turn.',
  'DISCARD_REQUIRED':
      'A seven was rolled. Everyone holding more than seven cards discards half.',
  'ROBBER_MOVE': 'Move the robber to a different tile.',
  'ROBBER_VICTIM': 'Choose an opponent to steal one card from.',
  'ACTION': 'Build, trade, play a card, or end your turn.',
  'ROAD_BUILDING': 'Place your free roads.',
  'COMPLETE': 'The game is over.',
};

class GameScreen extends ConsumerStatefulWidget {
  const GameScreen({
    super.key,
    this.createRematch,
    this.onExit,
    this.isHost = false,
  });

  /// Supplied by the room coordinator in Phase 5; UI is independently testable.
  final Future<Uri> Function()? createRematch;
  final VoidCallback? onExit;
  final bool isHost;
  @override
  ConsumerState<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends ConsumerState<GameScreen>
    with WidgetsBindingObserver {
  bool _creatingRematch = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(() => ref.read(gameProvider.notifier).connect());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(gameProvider.notifier).synchronize();
    }
  }

  GameController get _controller => ref.read(gameProvider.notifier);

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(gameProvider);
    final snapshot = view.snapshot;
    ref.listen(gameProvider, (previous, next) {
      final card = next.drawnCard;
      if (card != null && card != previous?.drawnCard) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('You drew ${words(card)}. Only you can see it.'),
            duration: const Duration(seconds: 3),
          ),
        );
        _controller.clearFeedback();
      }
    });
    return Scaffold(
      backgroundColor: _sand,
      body: SafeArea(
        child: snapshot == null ? _waiting(view) : _table(view, snapshot),
      ),
    );
  }

  Widget _table(GameView view, GameSnapshot snapshot) => LayoutBuilder(
    builder: (context, constraints) {
      final landscape =
          constraints.maxWidth >= 740 && constraints.maxHeight < 600;
      final board = IslandBoard(
        snapshot: snapshot,
        targets: view.selection == null || view.locked
            ? const {}
            : snapshot.targets(
                view.selection!,
                pendingSetupVertex: view.setupVertex,
              ),
        selected: view.target,
        onTarget: _controller.target,
      );
      final panels = ListView(
        key: const Key('game-scroll'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        children: [
          _header(snapshot),
          if (view.message != null) _banner(view.message!, Icons.info_outline),
          if (snapshot.paused)
            _banner(
              (snapshot.public['pauseReasons'] as List).any(
                    (r) => r != 'DISCONNECTED',
                  )
                  ? 'Game saved and paused. The host can resume when required players are online.'
                  : 'Waiting for a required player to reconnect. Your remaining time is saved.',
              Icons.pause_circle_outline,
            ),
          if (!view.connected)
            _banner('Reconnecting to your table…', Icons.wifi_off),
          if (view.pending != null) _pending(view),
          if (!snapshot.paused &&
              (snapshot.public['turnDeadline'] != null ||
                  (snapshot.public['discardDeadlines']
                          as Map)[snapshot.playerId] !=
                      null))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: GameCountdown(
                serverTime:
                    view.serverTime ?? snapshot.json['serverTime'] as String,
                deadline:
                    ((snapshot.public['discardDeadlines']
                                as Map)[snapshot.playerId] ??
                            snapshot.public['turnDeadline'])
                        as String,
                discard: snapshot.phase == 'DISCARD_REQUIRED',
              ),
            ),
          if (widget.isHost && !snapshot.complete)
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: !view.connected || view.pending != null
                      ? null
                      : () => _session(
                          snapshot.paused ? 'RESUME_GAME' : 'PAUSE_GAME',
                          snapshot,
                        ),
                  icon: Icon(snapshot.paused ? Icons.play_arrow : Icons.pause),
                  label: Text(snapshot.paused ? 'Resume game' : 'Pause game'),
                ),
                TextButton(
                  onPressed: !view.connected || view.pending != null
                      ? null
                      : () => _session('ABANDON_GAME', snapshot),
                  child: const Text('Abandon game'),
                ),
              ],
            ),
          const SizedBox(height: 12),
          if (!landscape) board,
          const SizedBox(height: 16),
          if (snapshot.complete) _result(snapshot) else _prompt(view, snapshot),
          const SizedBox(height: 16),
          _players(snapshot),
          const SizedBox(height: 16),
          _hand(view, snapshot),
          const SizedBox(height: 16),
          _activity(view),
        ],
      );
      if (landscape) {
        return Row(
          children: [
            Expanded(
              child: Padding(padding: const EdgeInsets.all(12), child: board),
            ),
            Expanded(child: panels),
          ],
        );
      }
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: panels,
        ),
      );
    },
  );

  Widget _waiting(GameView view) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.landscape_rounded, size: 56, color: _teal),
        const SizedBox(height: 16),
        Text(
          view.message ?? 'Preparing your table…',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        if (!view.connected)
          FilledButton(
            onPressed: () => _controller.connect(),
            child: const Text('Reconnect'),
          ),
      ],
    ),
  );

  Widget _header(GameSnapshot s) {
    final active = s.name(s.public['activePlayerId'] as String);
    final dice = s.public['dice'] as List?;
    return Row(
      children: [
        const Icon(Icons.landscape_rounded, size: 32, color: _teal),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Turn ${s.public['turnNumber']} · ${s.active ? 'Your turn' : "$active's turn"}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              Text(
                words(s.phase),
                style: const TextStyle(color: Color(0xff586b68), fontSize: 12),
              ),
            ],
          ),
        ),
        if (dice != null)
          Semantics(
            label:
                'Dice ${dice[0]} and ${dice[1]}, total ${(dice[0] as int) + (dice[1] as int)}',
            child: Chip(
              avatar: const Icon(Icons.casino_outlined, size: 18),
              label: Text('${dice[0]} + ${dice[1]}'),
            ),
          ),
      ],
    );
  }

  Widget _banner(String message, IconData icon) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Row(
      children: [
        Icon(icon, size: 18, color: _teal),
        const SizedBox(width: 8),
        Expanded(child: Text(message)),
      ],
    ),
  );

  Widget _pending(GameView view) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Row(
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Text('Waiting for the table to confirm your action.'),
        ),
        if (!view.sending)
          TextButton(
            onPressed: () => _controller.retry(),
            child: const Text('Retry'),
          ),
      ],
    ),
  );

  // ---- phase prompt and actions -------------------------------------------------

  Widget _prompt(GameView view, GameSnapshot s) {
    final mine =
        s.active ||
        (s.public['requiredPlayerIds'] as List).contains(s.playerId);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              mine
                  ? _prompts[s.phase]!
                  : 'Waiting for ${s.name(s.public['activePlayerId'] as String)}.',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (view.selection != null) ...[
              const SizedBox(height: 12),
              _confirmation(view, s),
            ] else if (mine || s.phase == 'ACTION') ...[
              const SizedBox(height: 12),
              _actions(view, s),
            ],
          ],
        ),
      ),
    );
  }

  Widget _confirmation(GameView view, GameSnapshot s) {
    final cost = costs[view.selection!];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          view.target == null
              ? 'Choose a highlighted location on the island.'
              : 'Selected ${locationLabel(s, view.target!)}.',
        ),
        if (cost != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Costs ${resourceSummary(cost)}',
              style: const TextStyle(fontSize: 12, color: Color(0xff586b68)),
            ),
          ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          key: ValueKey('${s.version}:${view.selection}:${view.target}'),
          initialValue: view.target,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Choose a location'),
          items: [
            for (final id in s.targets(
              view.selection!,
              pendingSetupVertex: view.setupVertex,
            ))
              DropdownMenuItem(
                value: id,
                child: Text(
                  locationLabel(s, id),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: view.locked
              ? null
              : (id) {
                  if (id != null) _controller.target(id);
                },
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: view.target == null || view.locked
                    ? null
                    : () => _controller.confirmTarget(),
                child: const Text('Confirm placement'),
              ),
            ),
            const SizedBox(width: 10),
            TextButton(
              onPressed: () => _controller.cancelSelection(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _actions(GameView view, GameSnapshot s) {
    final buttons = <Widget>[];
    if (!s.active && s.phase == 'ACTION') {
      return OutlinedButton(
        onPressed: view.locked ? null : () => _openTrade(s),
        child: const Text('Offer a trade'),
      );
    }
    void add(String label, VoidCallback? onPressed, {String? unavailable}) {
      buttons.add(
        Tooltip(
          message: unavailable ?? '',
          child: OutlinedButton(
            onPressed: view.locked ? null : onPressed,
            child: Text(label),
          ),
        ),
      );
    }

    switch (s.phase) {
      case 'SETUP_SETTLEMENT':
        add(
          'Choose settlement',
          () => _controller.select('PLACE_SETUP_SETTLEMENT'),
        );
      case 'SETUP_ROAD':
        add('Choose road', () => _controller.select('PLACE_SETUP_ROAD'));
      case 'AWAIT_ROLL':
        add('Roll dice', () => _controller.command('ROLL_DICE'));
        if (s.cards.any((c) => s.cardUnavailable(c) == null)) {
          add('Play a card', () => _openCards(s));
        }
      case 'DISCARD_REQUIRED':
        if ((s.hand['discardRequired'] as int) > 0) {
          add('Discard cards', () => _openDiscard(s));
        } else {
          buttons.add(
            const Text('Waiting for the other players to finish discarding.'),
          );
        }
      case 'ROBBER_MOVE':
        add('Move robber', () => _controller.select('MOVE_ROBBER'));
      case 'ROBBER_VICTIM':
        for (final id in s.victims) {
          add(
            'Steal from ${s.name(id)}',
            () => _controller.command('CHOOSE_ROBBER_VICTIM', {
              'victimPlayerId': id,
            }),
          );
        }
      case 'ROAD_BUILDING':
        add('Place free road', () => _controller.select('PLACE_FREE_ROAD'));
        final blocked = s.targets('PLACE_FREE_ROAD').isNotEmpty;
        add(
          'Finish roads',
          blocked ? null : () => _controller.command('FINISH_FREE_ROADS'),
          unavailable: blocked
              ? 'Finish only when no legal placement remains'
              : null,
        );
      case 'ACTION':
        for (final entry in const {
          'BUILD_ROAD': 'Build road',
          'BUILD_SETTLEMENT': 'Build settlement',
          'BUILD_CITY': 'Build city',
        }.entries) {
          final targets = s.targets(entry.key);
          add(
            entry.value,
            targets.isEmpty ? null : () => _controller.select(entry.key),
            unavailable: targets.isEmpty
                ? (s.canAfford(entry.key)
                      ? 'No legal location'
                      : 'Costs ${resourceSummary(costs[entry.key]!)}')
                : null,
          );
        }
        add(
          'Buy development card',
          s.canAfford('BUY_DEVELOPMENT_CARD')
              ? () => _controller.command('BUY_DEVELOPMENT_CARD')
              : null,
          unavailable: s.canAfford('BUY_DEVELOPMENT_CARD')
              ? null
              : 'Costs ${resourceSummary(costs['BUY_DEVELOPMENT_CARD']!)}',
        );
        if (s.cards.isNotEmpty) add('Play a card', () => _openCards(s));
        add('Trade', () => _openTrade(s));
        add('End turn', () => _controller.command('END_TURN'));
      default:
        break;
    }
    if (!s.active && s.phase == 'ACTION') {
      buttons.add(
        OutlinedButton(
          onPressed: view.locked ? null : () => _openTrade(s),
          child: const Text('Offer a trade'),
        ),
      );
    }
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }

  // ---- players, hand, activity ---------------------------------------------------

  Widget _players(GameSnapshot s) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          for (final player in s.orderedPlayers)
            Semantics(
              label:
                  '${player['nickname']}, seat ${(player['seatIndex'] as int) + 1}, '
                  '${player['publicPoints']} public points, ${player['resourceCardCount']} resource cards, '
                  '${player['developmentCardCount']} development cards, ${player['playedKnights']} knights played'
                  '${player['id'] == s.public['activePlayerId'] ? ', active player' : ''}',
              child: ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  // The stats reflow below the name rather than overflowing when a
                  // narrow phone is combined with an enlarged text scale.
                  child: LayoutBuilder(
                    builder: (context, constraints) => Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircleAvatar(
                                radius: 14,
                                backgroundColor:
                                    playerColours[player['colour']],
                                child: Text(
                                  '${(player['seatIndex'] as int) + 1}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xff253e38),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Text(
                                  '${player['nickname']}${player['id'] == s.playerId ? ' (you)' : ''}',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight:
                                        player['id'] ==
                                            s.public['activePlayerId']
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Wrap(
                          children: [
                            _pill(
                              Icons.star_outline,
                              '${player['publicPoints']}',
                            ),
                            _pill(
                              Icons.style_outlined,
                              '${player['resourceCardCount']}',
                            ),
                            _pill(
                              Icons.credit_card,
                              '${player['developmentCardCount']}',
                            ),
                            _pill(
                              Icons.shield_outlined,
                              '${player['playedKnights']}',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (s.public['longestRoad']['holderPlayerId'] != null ||
              s.public['largestArmy']['holderPlayerId'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Row(
                children: [
                  if (s.public['longestRoad']['holderPlayerId'] != null)
                    Expanded(
                      child: Text(
                        'Longest road · ${s.name(s.public['longestRoad']['holderPlayerId'] as String)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  if (s.public['largestArmy']['holderPlayerId'] != null)
                    Expanded(
                      child: Text(
                        'Largest army · ${s.name(s.public['largestArmy']['holderPlayerId'] as String)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );

  Widget _pill(IconData icon, String value) => Padding(
    padding: const EdgeInsets.only(left: 10),
    // Min size: inside a Wrap a default Row would expand to the whole line.
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: const Color(0xff586b68)),
        const SizedBox(width: 3),
        Text(value),
      ],
    ),
  );

  Widget _hand(GameView view, GameSnapshot s) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Your hand',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Semantics(
            label:
                'Your resources: ${resourceTypes.map((r) => '${s.stock[r]} $r').join(', ')}',
            child: ExcludeSemantics(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final resource in resourceTypes)
                    Chip(
                      label: Text('${words(resource)} ${s.stock[resource]}'),
                      backgroundColor: (s.stock[resource] ?? 0) > 0
                          ? const Color(0xffe7efe6)
                          : null,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Development cards (${s.cards.length})',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (s.cards.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('None yet.', style: TextStyle(fontSize: 12)),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final card in s.cards)
                  ActionChip(
                    label: Text(words(card['type'] as String)),
                    onPressed: view.locked || s.cardUnavailable(card) != null
                        ? null
                        : () => _playCard(s, card),
                    tooltip: s.cardUnavailable(card),
                  ),
              ],
            ),
          const SizedBox(height: 8),
          Text(
            'Total score including hidden points: ${s.hand['totalPoints']}',
            style: const TextStyle(fontSize: 12, color: Color(0xff586b68)),
          ),
          if ((s.hand['discardRequired'] as int) > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton(
                onPressed: view.locked ? null : () => _openDiscard(s),
                child: Text('Discard ${s.hand['discardRequired']} cards'),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _activity(GameView view) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'What happened',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => ref.read(gameProvider.notifier).loadHistory(),
            child: const Text('Load earlier activity'),
          ),
          if (view.activity.isEmpty)
            const Text('Nothing yet.', style: TextStyle(fontSize: 12))
          else
            for (final entry in view.activity.reversed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('· $entry', style: const TextStyle(fontSize: 12)),
              ),
        ],
      ),
    ),
  );

  Widget _result(GameSnapshot s) {
    final winner = s.public['winnerPlayerId'] as String?;
    final points = s.public['finalPoints'] as Map;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              winner == s.playerId
                  ? 'You won!'
                  : '${s.name(winner ?? '')} won the game.',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
            ),
            const SizedBox(height: 10),
            for (final player in s.orderedPlayers)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                // Spread across the line normally; the score drops below the name
                // instead of overflowing at the largest text scales.
                child: LayoutBuilder(
                  builder: (context, constraints) => Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 12,
                    runSpacing: 2,
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: constraints.maxWidth,
                        ),
                        child: Text(
                          '${player['nickname']}${player['id'] == s.playerId ? ' (you)' : ''}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text('${points[player['id']] ?? 0} points'),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Text(
              'Revealed victory point cards: ${(s.public['winnerVictoryPointCardIds'] as List).length}',
              style: const TextStyle(fontSize: 12, color: Color(0xff586b68)),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: widget.createRematch == null ? null : _rematch,
              icon: const Icon(Icons.replay),
              label: const Text('Invite to a rematch'),
            ),
            if (widget.onExit != null)
              TextButton(
                onPressed: widget.onExit,
                child: const Text('Back to tables'),
              ),
            if (widget.createRematch == null)
              const Text(
                'The host can invite everyone to a rematch.',
                style: TextStyle(fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _session(String type, GameSnapshot basedOn) async {
    if (type == 'ABANDON_GAME') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Abandon this game?'),
          content: const Text(
            'This ends the game for everyone without a winner. The saved result cannot be resumed.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep playing'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('End game for everyone'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await _controller.command(type, {}, basedOn);
  }

  // ---- modal flows ---------------------------------------------------------------

  Future<void> _rematch() async {
    if (_creatingRematch || widget.createRematch == null) return;
    _creatingRematch = true;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('Play another island?'),
          content: const Text(
            'Create a new private table and invite your friends. Everyone will join and ready up again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Create invitation'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final uri = await widget.createRematch!();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Invite your friends'),
          content: SingleChildScrollView(child: SelectableText(uri.toString())),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: uri.toString()));
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy invitation'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The invitation could not be created. Please try again.',
            ),
          ),
        );
      }
    } finally {
      _creatingRematch = false;
    }
  }

  Future<void> _openDiscard(GameSnapshot s) async {
    final required = s.hand['discardRequired'] as int;
    final chosen = await _pickResources(
      title: 'Discard $required cards',
      holdings: s.stock,
      available: s.stock,
      exactly: required,
    );
    if (chosen != null && mounted) {
      await _controller.command('DISCARD_RESOURCES', {'resources': chosen}, s);
    }
  }

  Future<void> _openCards(GameSnapshot s) async {
    final playable = s.cards
        .where((c) => s.cardUnavailable(c) == null)
        .toList();
    if (playable.isEmpty) return;
    final card = await showModalBottomSheet<JsonMap>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: ListView(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Play a development card',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              for (final card in playable)
                ListTile(
                  title: Text(words(card['type'] as String)),
                  onTap: () => Navigator.pop(context, card),
                ),
            ],
          ),
        ),
      ),
    );
    if (card != null && mounted) await _playCard(s, card);
  }

  Future<void> _playCard(GameSnapshot s, JsonMap card) async {
    final type = card['type'] as String;
    JsonMap? choice = const <String, dynamic>{};
    if (type == 'MONOPOLY') {
      final resource = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Claim every card of one resource'),
          children: [
            for (final resource in resourceTypes)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, resource),
                child: Text(words(resource)),
              ),
          ],
        ),
      );
      choice = resource == null ? null : {'resourceType': resource};
    } else if (type == 'YEAR_OF_PLENTY') {
      final picked = await _pickResources(
        title: 'Take two resources',
        holdings: s.stock,
        available: null,
        exactly: 2,
      );
      choice = picked == null ? null : {'resources': picked};
    }
    if (choice == null || !mounted) return;
    await _controller.command('PLAY_DEVELOPMENT_CARD', {
      'cardId': card['id'],
      'choice': choice,
    }, s);
  }

  Future<void> _openTrade(GameSnapshot s) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _TradeSheet(snapshot: s, controller: _controller),
    );
  }

  /// Shared counter used by discards and Year of Plenty. [available] caps each type.
  Future<Map<String, int>?> _pickResources({
    required String title,
    required Map<String, int> holdings,
    required Map<String, int>? available,
    required int exactly,
  }) => showDialog<Map<String, int>>(
    context: context,
    builder: (context) {
      final chosen = {for (final resource in resourceTypes) resource: 0};
      return StatefulBuilder(
        builder: (context, setSheetState) {
          final total = chosen.values.fold(0, (a, b) => a + b);
          return AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final resource in resourceTypes)
                    _ResourceCounter(
                      label: words(resource),
                      value: chosen[resource]!,
                      hint: 'you hold ${holdings[resource]}',
                      onChanged: (delta) => setSheetState(
                        () => chosen[resource] = chosen[resource]! + delta,
                      ),
                      canAdd:
                          total < exactly &&
                          (available == null ||
                              chosen[resource]! < available[resource]!),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    '$total of $exactly selected',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: total == exactly
                    ? () => Navigator.pop(context, chosen)
                    : null,
                child: const Text('Confirm'),
              ),
            ],
          );
        },
      );
    },
  );
}

/// Explicit give/receive composition, bank exchange and responses to open offers.
class _TradeSheet extends StatefulWidget {
  const _TradeSheet({required this.snapshot, required this.controller});
  final GameSnapshot snapshot;
  final GameController controller;
  @override
  State<_TradeSheet> createState() => _TradeSheetState();
}

class _TradeSheetState extends State<_TradeSheet> {
  final give = {for (final resource in resourceTypes) resource: 0};
  final receive = {for (final resource in resourceTypes) resource: 0};
  String? target;
  @override
  void initState() {
    super.initState();
    if (!s.active) target = s.public['activePlayerId'] as String;
  }

  GameSnapshot get s => widget.snapshot;
  int get giving => give.values.fold(0, (a, b) => a + b);
  int get receiving => receive.values.fold(0, (a, b) => a + b);
  bool get overlaps =>
      resourceTypes.any((r) => give[r]! > 0 && receive[r]! > 0);
  bool get proposable =>
      giving > 0 &&
      receiving > 0 &&
      !overlaps &&
      resourceTypes.every((r) => give[r]! <= s.stock[r]!);

  Future<void> _send(String type, JsonMap payload) async {
    Navigator.pop(context);
    await widget.controller.command(type, payload, s);
  }

  @override
  Widget build(BuildContext context) {
    final offers = (s.public['trades'] as Map).values
        .cast<Map>()
        .where((t) => t['status'] == 'OPEN')
        .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Trade',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const SizedBox(height: 12),
              for (final offer in offers) _offer(offer),
              if (offers.isNotEmpty) const Divider(height: 24),
              const Text(
                'You give',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              for (final resource in resourceTypes)
                _ResourceCounter(
                  label: words(resource),
                  value: give[resource]!,
                  hint: receive[resource]! > 0
                      ? 'asked for below'
                      : 'you hold ${s.stock[resource]}',
                  canAdd:
                      give[resource]! < s.stock[resource]! &&
                      receive[resource]! == 0,
                  onChanged: (delta) =>
                      setState(() => give[resource] = give[resource]! + delta),
                ),
              const SizedBox(height: 8),
              const Text(
                'You receive',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              for (final resource in resourceTypes)
                _ResourceCounter(
                  label: words(resource),
                  value: receive[resource]!,
                  hint: give[resource]! > 0 ? 'offered above' : null,
                  canAdd: receive[resource]! < 19 && give[resource]! == 0,
                  onChanged: (delta) => setState(
                    () => receive[resource] = receive[resource]! + delta,
                  ),
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: target,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Offer to'),
                items: [
                  if (s.active)
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Everyone'),
                    ),
                  for (final player in s.orderedPlayers)
                    if (player['id'] != s.playerId &&
                        (s.active ||
                            player['id'] == s.public['activePlayerId']))
                      DropdownMenuItem<String?>(
                        value: player['id'] as String,
                        child: Text(player['nickname'] as String),
                      ),
                ],
                onChanged: (value) => setState(() => target = value),
              ),
              if (overlaps)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'A resource cannot be on both sides of an offer.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: !proposable
                    ? null
                    : () => _send('PROPOSE_TRADE', {
                        'targetPlayerId': target,
                        'give': give,
                        'receive': receive,
                      }),
                child: const Text('Propose trade'),
              ),
              const SizedBox(height: 8),
              if (s.active) _bank(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _offer(Map offer) {
    final mine = offer['proposerPlayerId'] == s.playerId;
    final targeted = offer['targetPlayerId'];
    final canRespond =
        !mine &&
        (targeted == null || targeted == s.playerId) &&
        (s.active || offer['proposerPlayerId'] == s.public['activePlayerId']);
    final canPay = resourceTypes.every(
      (r) => s.stock[r]! >= (offer['receive'][r] as int),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${s.name(offer['proposerPlayerId'] as String)} gives ${resourceSummary(offer['give'] as Map)} '
            'for ${resourceSummary(offer['receive'] as Map)}',
          ),
          const SizedBox(height: 6),
          // Wrap: at large text scales Accept plus Decline exceed a narrow line.
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (canRespond) ...[
                FilledButton(
                  onPressed: !canPay
                      ? null
                      : () => _send('ACCEPT_TRADE', {
                          'offerId': offer['offerId'],
                          'offerRevision': offer['revision'],
                        }),
                  child: const Text('Accept'),
                ),
                OutlinedButton(
                  onPressed: (offer['declinedBy'] as List).contains(s.playerId)
                      ? null
                      : () => _send('DECLINE_TRADE', {
                          'offerId': offer['offerId'],
                          'offerRevision': offer['revision'],
                        }),
                  child: const Text('Decline'),
                ),
              ],
              if (mine)
                OutlinedButton(
                  onPressed: () => _send('CANCEL_TRADE', {
                    'offerId': offer['offerId'],
                    'offerRevision': offer['revision'],
                  }),
                  child: const Text('Cancel offer'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bank() {
    final giveType = resourceTypes.firstWhere(
      (r) => give[r]! > 0,
      orElse: () => '',
    );
    final receiveType = resourceTypes.firstWhere(
      (r) => receive[r]! > 0,
      orElse: () => '',
    );
    final rate = giveType.isEmpty ? 4 : s.bankRate(giveType);
    final exact =
        s.active &&
        resourceTypes.where((r) => give[r]! > 0).length == 1 &&
        resourceTypes.where((r) => receive[r]! > 0).length == 1 &&
        proposable &&
        giveType.isNotEmpty &&
        receiveType.isNotEmpty &&
        giveType != receiveType &&
        receiving >= 1 &&
        giving == rate * receiving;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          giveType.isEmpty
              ? 'Bank exchange: choose one resource to give and one to receive.'
              : 'Bank rate for ${words(giveType)} is $rate:1.',
          style: const TextStyle(fontSize: 12, color: Color(0xff586b68)),
        ),
        const SizedBox(height: 6),
        OutlinedButton(
          onPressed: !exact
              ? null
              : () => _send('BANK_TRADE', {
                  'giveType': giveType,
                  'receiveType': receiveType,
                  'receiveCount': receiving,
                }),
          child: Text(
            exact
                ? 'Exchange with the bank'
                : 'Bank needs an exact $rate:1 amount',
          ),
        ),
      ],
    );
  }
}

class _ResourceCounter extends StatelessWidget {
  const _ResourceCounter({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.canAdd,
    this.hint,
  });
  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final bool canAdd;

  /// Shown beside the label, e.g. how many of this resource the player holds.
  final String? hint;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text.rich(
          TextSpan(
            text: label,
            children: hint == null
                ? null
                : [
                    TextSpan(
                      text: '  $hint',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ],
          ),
        ),
      ),
      IconButton(
        tooltip: 'One fewer $label',
        onPressed: value > 0 ? () => onChanged(-1) : null,
        icon: const Icon(Icons.remove_circle_outline),
      ),
      Semantics(
        label: hint == null ? '$label $value' : '$label $value, $hint',
        child: ExcludeSemantics(child: Text('$value')),
      ),
      IconButton(
        tooltip: 'One more $label',
        onPressed: canAdd ? () => onChanged(1) : null,
        icon: const Icon(Icons.add_circle_outline),
      ),
    ],
  );
}
