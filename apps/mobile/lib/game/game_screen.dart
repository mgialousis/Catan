import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'board.dart';
import 'controller.dart';
import 'countdown.dart';
import 'hud.dart';
import 'model.dart';
import 'resource_icon.dart';
import 'table_stage.dart';

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
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _tradeNotice;
  void _closeTradeNotice() {
    final notice = _tradeNotice;
    _tradeNotice = null;
    notice?.close();
  }

  /// Declines the proposer has not been told about yet. A dialog is modal, so
  /// a second decline arriving while one is open is queued rather than dropped
  /// or stacked on top.
  final _pendingDeclines = <String>[];
  bool _declineDialogOpen = false;

  void _announceDeclines(GameSnapshot before, GameSnapshot after) {
    final seen = {
      for (final offer in before.ownTrades)
        offer['offerId'] as String: (offer['declinedBy'] as List)
            .cast<String>()
            .toSet(),
    };
    for (final offer in after.ownTrades) {
      final previous = seen[offer['offerId'] as String] ?? const <String>{};
      final declined = (offer['declinedBy'] as List).cast<String>();
      final fresh = declined.where((id) => !previous.contains(id)).toList();
      if (fresh.isEmpty) continue;
      final names = fresh.map(after.name).toList();
      final everyone = after.eligibleFor(offer).every(declined.contains);
      _pendingDeclines.add(
        '${names.length == 1 ? names.single : '${names.take(names.length - 1).join(', ')} and ${names.last}'} '
        'declined your offer of ${resourceSummary(offer['give'] as Map)} '
        'for ${resourceSummary(offer['receive'] as Map)}.'
        '${everyone ? ' Nobody is left who can accept it.' : ''}',
      );
    }
    if (_pendingDeclines.isNotEmpty) unawaited(_drainDeclines());
  }

  Future<void> _drainDeclines() async {
    if (_declineDialogOpen) return;
    _declineDialogOpen = true;
    while (mounted && _pendingDeclines.isNotEmpty) {
      final message = _pendingDeclines.removeAt(0);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.front_hand_outlined, color: _teal),
          title: const Text('Trade declined'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
    _declineDialogOpen = false;
  }

  /// Log events worth interrupting for. Both are things another player did to
  /// the table that are easy to miss in the log alone.
  static const _announced = {'RESOURCES_DISCARDED', 'RESOURCE_STOLEN'};
  int? _announcedThrough;

  /// Whether the full log is open. Collapsed by default: the last few lines are
  /// what a player usually wants, and the rest is history.
  bool _logOpen = false;

  void _announceActivity(GameView next) {
    final snapshot = next.snapshot;
    if (snapshot == null || next.activity.isEmpty) return;
    final highest = next.activity
        .map((e) => e.sequence)
        .reduce((a, b) => a > b ? a : b);
    // First delivery only establishes the high-water mark: joining a game in
    // progress must not replay its whole backlog as notifications.
    if (_announcedThrough == null) {
      _announcedThrough = highest;
      return;
    }
    if (highest <= _announcedThrough!) return;
    final fresh =
        next.activity
            .where(
              (e) =>
                  e.sequence > _announcedThrough! &&
                  _announced.contains(e.type),
            )
            .toList()
          ..sort((a, b) => a.sequence.compareTo(b.sequence));
    _announcedThrough = highest;
    if (fresh.isEmpty) return;
    // A seven makes every over-full player discard at once, so these arrive in
    // batches; one notice listing them beats four that replace each other.
    final lines = fresh.map((e) => e.describe(snapshot)).toList();
    _showFeedback(
      SnackBar(
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [for (final line in lines.take(4)) Text(line)],
        ),
        duration: Duration(seconds: lines.length > 1 ? 6 : 4),
      ),
    );
  }

  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> _showFeedback(
    SnackBar bar,
  ) {
    // Keep one current notice, so a new offer is never hidden behind old feedback.
    final messenger = ScaffoldMessenger.of(context);
    _tradeNotice = null;
    messenger.removeCurrentSnackBar();
    return messenger.showSnackBar(bar);
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(gameProvider);
    final snapshot = view.snapshot;
    ref.listen(gameProvider, (previous, next) {
      final before = previous?.snapshot;
      final after = next.snapshot;
      if (next.rollGains != null &&
          !identical(previous?.rollGains, next.rollGains)) {
        final summary = resourceSummary(next.rollGains!);
        _showFeedback(
          SnackBar(
            content: Text(
              summary.isEmpty
                  ? 'You collected no resources from this roll.'
                  : 'You collected $summary.',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      if (before != null && after != null && after.version > before.version) {
        _announceDeclines(before, after);
        if (after.incomingTrades.isEmpty) _closeTradeNotice();
        final known = before.incomingTrades.map((t) => t['offerId']).toSet();
        final fresh = after.incomingTrades
            .where((t) => !known.contains(t['offerId']))
            .toList();
        if (fresh.isNotEmpty) {
          _closeTradeNotice();
          _tradeNotice = _showFeedback(
            SnackBar(
              content: Text(
                '${after.name(fresh.first['proposerPlayerId'] as String)} wants to trade with you.',
              ),
              duration: const Duration(seconds: 6),
              action: SnackBarAction(
                label: 'Review',
                onPressed: () {
                  final current = ref.read(gameProvider);
                  if (!current.locked &&
                      current.snapshot!.incomingTrades.isNotEmpty) {
                    _openTrade(current.snapshot!);
                  }
                },
              ),
            ),
          );
          final notice = _tradeNotice;
          notice!.closed.then((_) {
            if (identical(_tradeNotice, notice)) _tradeNotice = null;
          });
        }
      }
      _announceActivity(next);
      final card = next.drawnCard;
      if (card != null && card != previous?.drawnCard) {
        _showFeedback(
          SnackBar(
            content: Text('You drew ${words(card)}. Only you can see it.'),
            duration: const Duration(seconds: 3),
          ),
        );
        _controller.clearFeedback();
      }
    });
    return Theme(
      data: hudTheme(context),
      child: Scaffold(
        backgroundColor: hudBackgroundTop,
        bottomNavigationBar: snapshot == null
            ? null
            : ResourceDock(stock: snapshot.stock, gains: view.rollGains),
        body: HudBackground(
          child: SafeArea(
            child: snapshot == null
                ? _waiting(view)
                : Column(
                    children: [
                      if (snapshot.incomingTrades.isNotEmpty)
                        Semantics(
                          liveRegion: true,
                          child: Material(
                            color: const Color(0xfff6e3b4),
                            child: Container(
                              decoration: const BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(color: Color(0xffdcc98f)),
                                ),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.notifications_active_outlined,
                                    color: _teal,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '${snapshot.incomingTrades.length} trade ${snapshot.incomingTrades.length == 1 ? 'request' : 'requests'} for you',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: view.locked
                                        ? null
                                        : () => _openTrade(snapshot),
                                    child: const Text('View trades'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      Expanded(child: _table(view, snapshot)),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _table(GameView view, GameSnapshot snapshot) => LayoutBuilder(
    builder: (context, constraints) {
      // Everything reads top to bottom: the map owns the full width and the
      // actions follow underneath it, in both orientations. Putting the panels
      // beside the map only ever shrank the thing people are looking at.
      Widget inset(Widget child) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: child,
          ),
        ),
      );
      final board = TableStage(
        activity: view.activity,
        connected: view.connected,
        onPlayer: (player) => _points(snapshot, player),
        menu: snapshot.complete ? null : _tableMenu(view, snapshot),
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
      return ListView(
        key: const Key('game-scroll'),
        // No side padding: the map runs edge to edge and every other panel
        // insets itself, so the board is the widest thing on the screen.
        padding: const EdgeInsets.symmetric(vertical: 20),
        children: [
          // The turn, phase and roll now share the board's own header line, so
          // there is no panel of them above the map.
          if (view.message != null)
            inset(_banner(view.message!, Icons.info_outline)),
          if (snapshot.vacantSeats.isNotEmpty)
            inset(_vacancies(view, snapshot)),
          if (snapshot.paused && snapshot.vacantSeats.isEmpty)
            inset(
              _banner(
                (snapshot.public['pauseReasons'] as List).any(
                      (r) => r != 'DISCONNECTED',
                    )
                    ? 'Game saved and paused. The host can resume when required players are online.'
                    : 'Waiting for a required player to reconnect. Your remaining time is saved.',
                Icons.pause_circle_outline,
              ),
            ),
          if (!view.connected)
            inset(_banner('Reconnecting to your table…', Icons.wifi_off)),
          if (view.pending != null) inset(_pending(view)),
          if (!snapshot.paused &&
              (snapshot.public['turnDeadline'] != null ||
                  (snapshot.public['discardDeadlines']
                          as Map)[snapshot.playerId] !=
                      null))
            inset(
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
            ),
          const SizedBox(height: 12),
          // Wider than the panels, capped only so a desktop window does not
          // blow the island up past being one glance.
          //
          // It is deliberately NOT fitted to the viewport height. Doing that
          // shrank the map to about 320 logical pixels on an 800-wide phone in
          // landscape -- tiny, and too narrow to carry the corner seats. A big
          // map you scroll beats a small whole one.
          //
          // The key belongs on the list child itself. The panels above it come
          // and go -- a sending notice, banners, the countdown -- and unkeyed
          // list children are matched by position, so every one of those shifts
          // would otherwise rebuild this subtree and lose the roll it is
          // presenting. Your own roll always arrives with a pending notice,
          // which is why it was the one that never animated.
          Center(
            key: const Key('table-stage'),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: board,
            ),
          ),
          const SizedBox(height: 16),
          inset(
            snapshot.complete ? _result(snapshot) : _prompt(view, snapshot),
          ),
          const SizedBox(height: 16),
          inset(_players(snapshot)),
          const SizedBox(height: 16),
          inset(_hand(view, snapshot)),
          const SizedBox(height: 16),
          inset(_activity(view, snapshot)),
        ],
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

  /// Somebody walked out. The table cannot continue with an empty seat, so this
  /// asks the people still here to decide rather than leaving them waiting.
  Widget _vacancies(GameView view, GameSnapshot s) {
    final seats = s.vacantSeats;
    final names = seats.map((p) => p['nickname'] as String).join(', ');
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: HudPanel(
        accent: hudGold,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              seats.length == 1
                  ? '$names left the game.'
                  : '$names left the game.',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              'The table is paused until the empty seats are filled. A bot can '
              'take over a seat with its cards and position, or you can leave too.',
              style: TextStyle(fontSize: 13, color: hudMuted),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final seat in seats)
                  FilledButton.icon(
                    onPressed: !view.connected || view.pending != null
                        ? null
                        : () => _controller.command('REPLACE_WITH_BOT', {
                            'playerId': seat['id'],
                          }, s),
                    icon: const Icon(Icons.smart_toy_outlined, size: 18),
                    label: Text(
                      seats.length == 1
                          ? 'Let a bot take over'
                          : "Bot for ${seat['nickname']}",
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _banner(String message, IconData icon) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: hudTeal.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: hudTeal.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: _teal),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 13, color: hudInk),
            ),
          ),
        ],
      ),
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
              style: const TextStyle(fontSize: 12, color: hudMuted),
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

  Widget _players(GameSnapshot s) => HudPanel(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 8),
          child: HudHeading('PLAYERS'),
        ),
        for (final player in s.orderedPlayers)
          Semantics(
            label:
                '${player['nickname']}${player['kind'] == 'BOT' ? ', bot' : ''}, seat ${(player['seatIndex'] as int) + 1}, '
                '${player['publicPoints']} public points, ${player['resourceCardCount']} resource cards, '
                '${player['developmentCardCount']} development cards, ${player['playedKnights']} knights played'
                '${player['id'] == s.public['activePlayerId'] ? ', active player' : ''}',
            child: ExcludeSemantics(
              child: Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                decoration: BoxDecoration(
                  color: player['id'] == s.public['activePlayerId']
                      ? (playerColours[player['colour']] ?? hudTeal).withValues(
                          alpha: 0.12,
                        )
                      : hudSurfaceSunk.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: player['id'] == s.public['activePlayerId']
                        ? (playerColours[player['colour']] ?? hudTeal)
                              .withValues(alpha: 0.5)
                        : hudBorder,
                  ),
                ),
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
                            Container(
                              width: 28,
                              height: 28,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: playerColours[player['colour']],
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: hudInk.withValues(alpha: 0.32),
                                  width: 1.4,
                                ),
                                boxShadow: hudShadow,
                              ),
                              child: Text(
                                '${(player['seatIndex'] as int) + 1}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: inkOn(
                                    playerColours[player['colour']] ?? hudTeal,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                '${player['nickname']}${player['id'] == s.playerId ? ' (you)' : ''}${player['kind'] == 'BOT' ? ' (bot)' : ''}',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight:
                                      player['id'] == s.public['activePlayerId']
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
                            emphasis: true,
                            onTap: () => _points(s, player),
                          ),
                          _pill(
                            Icons.style_outlined,
                            '${player['resourceCardCount']}',
                            onTap: () => _explain(
                              Icons.style_outlined,
                              'Resource cards',
                              '${player['nickname']} is holding ${player['resourceCardCount']} resource cards. Everyone can see how many; only their owner sees which.',
                            ),
                          ),
                          _pill(
                            Icons.credit_card,
                            '${player['developmentCardCount']}',
                            onTap: () => _explain(
                              Icons.credit_card,
                              'Development cards',
                              '${player['nickname']} is holding ${player['developmentCardCount']} development cards that have not been played. Their kinds stay hidden until they are.',
                            ),
                          ),
                          _pill(
                            Icons.shield_outlined,
                            '${player['playedKnights']}',
                            onTap: () => _explain(
                              Icons.shield_outlined,
                              'Knights played',
                              '${player['nickname']} has played ${player['playedKnights']} knights. Three or more, and the most of anyone, takes Largest Army and its two points.',
                            ),
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
            padding: const EdgeInsets.only(top: 2, left: 4),
            child: Row(
              children: [
                if (s.public['longestRoad']['holderPlayerId'] != null)
                  Expanded(
                    child: Text(
                      'Longest road · ${s.name(s.public['longestRoad']['holderPlayerId'] as String)}',
                      style: const TextStyle(fontSize: 12, color: hudMuted),
                    ),
                  ),
                if (s.public['largestArmy']['holderPlayerId'] != null)
                  Expanded(
                    child: Text(
                      'Largest army · ${s.name(s.public['largestArmy']['holderPlayerId'] as String)}',
                      style: const TextStyle(fontSize: 12, color: hudMuted),
                    ),
                  ),
              ],
            ),
          ),
      ],
    ),
  );

  Widget _pill(
    IconData icon,
    String value, {
    bool emphasis = false,
    VoidCallback? onTap,
  }) => HudStat(icon, value, emphasis: emphasis, onTap: onTap);

  /// What a number on the roster actually means. Every stat explains itself, so
  /// reading the table never depends on already knowing the rules.
  Future<void> _explain(IconData icon, String title, String body) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: Icon(icon, color: hudTeal),
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );

  /// How a score adds up. Hidden victory-point cards appear only in your own
  /// breakdown, because nobody else is entitled to know about them.
  Future<void> _points(GameSnapshot s, JsonMap player) {
    final id = player['id'] as String;
    final rows = s.pointsBreakdown(id);
    final mine = id == s.playerId;
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.star_outline, color: hudGold),
        title: Text(mine ? 'Your points' : "${player['nickname']}'s points"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (rows.isEmpty)
              const Text('Nothing scoring yet.')
            else
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(child: Text(row.$1)),
                      Text(
                        '${row.$2}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
            const Divider(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(
                    mine ? 'Total, including hidden' : 'Visible total',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  '${mine ? s.hand['totalPoints'] : player['publicPoints']}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            if (!mine)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Victory point cards stay hidden, so a rival may be closer than this shows.',
                  style: TextStyle(fontSize: 12, color: hudMuted),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// What the bank will give you, resource by resource. A port is invisible
  /// otherwise: you own a junction on the board and nothing tells you the rate
  /// changed, so the only way to find out was to try a trade.
  Widget _rates(GameSnapshot s) {
    final rates = {for (final r in resourceTypes) r: s.bankRate(r)};
    final ported = rates.values.any((rate) => rate < 4);
    return Semantics(
      label: ported
          ? 'Your bank rates: ${rates.entries.map((e) => '${e.key} ${e.value} to one').join(', ')}'
          : 'Bank rate four to one on everything; build on a port to improve it',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ported ? 'Your bank rates' : 'Bank rate 4:1 on everything',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              ported
                  ? 'Build on a port junction to improve a rate. Exchange from Trade.'
                  : 'Build a settlement or city on a port junction to trade better.',
              style: const TextStyle(fontSize: 12, color: hudMuted),
            ),
            if (ported) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final entry in rates.entries)
                    HudStat(
                      Icons.swap_horiz,
                      '${words(entry.key)} ${entry.value}:1',
                      emphasis: entry.value < 4,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _hand(GameView view, GameSnapshot s) => HudPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Your hand',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 15,
            color: hudInk,
          ),
        ),
        const SizedBox(height: 10),
        if (s.public['hasRolled'] == true) ...[
          Semantics(
            liveRegion: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'You collected this roll',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                if (view.rollGains == null)
                  const Text(
                    'Collection details unavailable after reconnecting.',
                    style: TextStyle(fontSize: 12),
                  )
                else if (view.rollGains!.values.every((n) => n == 0))
                  Text(
                    (s.public['dice'] as List).cast<int>().reduce(
                              (a, b) => a + b,
                            ) ==
                            7
                        ? 'No resources — a 7 activates the robber.'
                        : 'No resources from this roll.',
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final r in resourceTypes)
                        if (view.rollGains![r]! > 0)
                          Chip(
                            avatar: ResourceIcon(r),
                            label: Text('+${view.rollGains![r]} ${words(r)}'),
                          ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        _rates(s),
        const SizedBox(height: 12),
        Text(
          'Development cards (${s.cards.length})',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        if (s.cards.any(
          (card) =>
              card['type'] != 'VICTORY_POINT' &&
              (card['purchasedOnTurn'] as int) >=
                  (s.public['turnNumber'] as int),
        ))
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'New development cards, including Road Building, can be played from your next turn. Victory points count immediately.',
              style: TextStyle(fontSize: 12),
            ),
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
          style: const TextStyle(fontSize: 12, color: hudMuted),
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
  );

  /// The log grows without limit, so it shows the last few by default and the
  /// rest scroll inside a bounded box rather than pushing the page ever longer.
  Widget _activity(GameView view, GameSnapshot s) {
    const collapsed = 4;
    final entries = view.activity.reversed.toList();
    final overflowing = entries.length > collapsed;
    final shown = _logOpen ? entries : entries.take(collapsed).toList();
    Widget line(ActivityEntry entry) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        '· ${entry.describe(s)}',
        style: const TextStyle(fontSize: 12),
      ),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'What happened',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (overflowing)
                  TextButton(
                    onPressed: () => setState(() => _logOpen = !_logOpen),
                    child: Text(
                      _logOpen ? 'Show less' : 'Show all ${entries.length}',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (entries.isEmpty)
              const Text('Nothing yet.', style: TextStyle(fontSize: 12))
            else if (_logOpen)
              ConstrainedBox(
                // Bounded and scrollable: a long match must not turn this panel
                // into most of the page.
                constraints: const BoxConstraints(maxHeight: 220),
                child: Scrollbar(
                  child: ListView(
                    key: const Key('activity-scroll'),
                    primary: false,
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [for (final entry in shown) line(entry)],
                  ),
                ),
              )
            else
              for (final entry in shown) line(entry),
            if (_logOpen)
              TextButton(
                onPressed: () => ref.read(gameProvider.notifier).loadHistory(),
                child: const Text('Load earlier activity'),
              ),
          ],
        ),
      ),
    );
  }

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
                          '${player['nickname']}${player['id'] == s.playerId ? ' (you)' : ''}${player['kind'] == 'BOT' ? ' (bot)' : ''}',
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
              style: const TextStyle(fontSize: 12, color: hudMuted),
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

  /// Leaving is destructive and irreversible, so it always asks first, and it
  /// asks in the terms of the table you are actually at.
  /// Pausing and leaving are things you do to the table, not moves in the game,
  /// so they live together beside the board rather than among the panels.
  Widget _tableMenu(GameView view, GameSnapshot s) {
    final busy = !view.connected || view.pending != null;
    return PopupMenuButton<String>(
      tooltip: 'Table options',
      icon: const Icon(Icons.settings_outlined),
      onSelected: (value) => value == 'LEAVE'
          ? _leave(s)
          : _session(s.paused ? 'RESUME_GAME' : 'PAUSE_GAME', s),
      itemBuilder: (context) => [
        if (widget.isHost)
          PopupMenuItem(
            value: 'PAUSE',
            enabled: !busy,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(s.paused ? Icons.play_arrow : Icons.pause),
              title: Text(s.paused ? 'Resume game' : 'Pause game'),
            ),
          ),
        PopupMenuItem(
          value: 'LEAVE',
          enabled: !busy,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.logout),
            title: Text(s.soloPractice ? 'Leave practice game' : 'Leave game'),
          ),
        ),
      ],
    );
  }

  Future<void> _leave(GameSnapshot s) async {
    // A practice table has nobody else to consider, so leaving simply ends it.
    if (s.soloPractice) {
      await _session('ABANDON_GAME', s);
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave this game?'),
        content: Text(
          widget.isHost
              ? 'Your seat keeps its cards and position, and the others can hand it to a bot to carry on. Ending the game instead stops it for everyone.'
              : 'Your seat keeps its cards and position, and the others can hand it to a bot to carry on without you.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Keep playing'),
          ),
          if (widget.isHost)
            TextButton(
              onPressed: () => Navigator.pop(context, 'ABANDON_GAME'),
              child: const Text('End game for everyone'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'LEAVE_GAME'),
            child: const Text('Leave the table'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    await _controller.command(choice, {}, s);
  }

  Future<void> _session(String type, GameSnapshot basedOn) async {
    if (type == 'ABANDON_GAME') {
      final practice = basedOn.soloPractice;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            practice ? 'Leave this practice game?' : 'Abandon this game?',
          ),
          content: Text(
            practice
                ? 'The game ends here and the bots stop with it. There is nothing to come back to.'
                : 'This ends the game for everyone without a winner. The saved result cannot be resumed.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep playing'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                practice ? 'Leave practice game' : 'End game for everyone',
              ),
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
        _showFeedback(
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
    if (s.cards.isEmpty) return;
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
              for (final card in s.cards)
                ListTile(
                  title: Text(words(card['type'] as String)),
                  subtitle: s.cardUnavailable(card) == null
                      ? null
                      : Text(s.cardUnavailable(card)!),
                  enabled: s.cardUnavailable(card) == null,
                  onTap: s.cardUnavailable(card) == null
                      ? () => Navigator.pop(context, card)
                      : null,
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
    _closeTradeNotice();
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
          style: const TextStyle(fontSize: 12, color: hudMuted),
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
                : giveType.isEmpty || receiveType.isEmpty
                ? 'Choose what to give and receive'
                : resourceTypes.where((r) => give[r]! > 0).length > 1 ||
                      resourceTypes.where((r) => receive[r]! > 0).length > 1
                // Naming one resource here would misdescribe the selection.
                ? 'The bank takes one resource at a time'
                : 'Give ${rate * (receiving < 1 ? 1 : receiving)} ${words(giveType)} for ${receiving < 1 ? 1 : receiving}',
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
