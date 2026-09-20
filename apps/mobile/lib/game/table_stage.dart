import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'board.dart';
import 'hud.dart';
import 'model.dart';
import 'resource_icon.dart';
import 'roll_presentation.dart';

/// One thing the table shows, played to completion before the next begins, so a
/// roll, its payout and the following roll never overlap.
class _Scene {
  _Scene.roll(this.snapshot) : piece = null;
  _Scene.piece(this.snapshot, this.piece);
  final GameSnapshot snapshot;
  final PlacedPiece? piece;
  bool get isRoll => piece == null;
}

/// The table's animation is local presentation; it never delays game commands.
class TableStage extends StatefulWidget {
  const TableStage({
    super.key,
    required this.snapshot,
    required this.activity,
    required this.onTarget,
    required this.onPlayer,
    this.targets = const {},
    this.selected,
    this.menu,
    this.connected = true,
  });
  final GameSnapshot snapshot;
  final List<ActivityEntry> activity;
  final ValueChanged<String> onTarget;
  final ValueChanged<JsonMap> onPlayer;
  final Set<String> targets;
  final String? selected;
  final Widget? menu;
  final bool connected;

  @override
  State<TableStage> createState() => _TableStageState();
}

class _TableStageState extends State<TableStage>
    with SingleTickerProviderStateMixin {
  final _surface = GlobalKey();
  final _scene = GlobalKey();
  final _viewport = GlobalKey();
  static const _diceMs = 2800.0;
  static const _cameraMs = 600.0;
  static const _flightMs = 1000.0;
  static const _gapMs = 160.0;
  static const _flightStart = _diceMs + _cameraMs;
  static const _holdMs = 1300.0;
  // Below the 1.4 terrain-resolution bucket in board.dart: crossing it rebakes
  // the tiles, which would stutter the very movement meant to be watched.
  static const _pieceZoom = 1.38;
  final _players = <String, GlobalKey>{};
  final _transform = TransformationController();
  late final _animation = AnimationController.unbounded(
    vsync: this,
    animationBehavior: AnimationBehavior.preserve,
  )..addListener(_tick);
  _Scene? _showing;
  // Presentations play in the order the table produced them. Bounded, because a
  // long backlog would narrate a game nobody is still looking at.
  final _queue = <_Scene>[];
  GameSnapshot? _presented;
  List<ResourceFlight> _flights = [];
  Matrix4? _start, _focus;
  bool _reducedMotion = false;

  /// The roll currently on screen, for the parts that only apply to a roll.
  GameSnapshot? get _roll =>
      _showing?.isRoll == true ? _showing!.snapshot : null;

  /// While the table is still catching up, the production rings belong to the
  /// roll it has actually shown; once the queue drains they follow the live game
  /// again, so a skipped presentation cannot strand them on an old roll.
  Set<String> get _rings => _showing == null && _queue.isEmpty
      ? widget.snapshot.producingHexes
      : (_presented ?? widget.snapshot).producingHexes;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    if (_reducedMotion && _animation.isAnimating) _cancel();
  }

  @override
  void didUpdateWidget(TableStage old) {
    super.didUpdateWidget(old);
    final next = widget.snapshot;
    if (!widget.connected ||
        next.paused ||
        next.complete ||
        next.roomId != old.snapshot.roomId ||
        next.version > old.snapshot.version + 1) {
      _cancel();
      return;
    }
    if (isNewRoll(old.snapshot, next)) {
      // Your own roll is what you are waiting on before you can act, so it
      // never queues behind another seat's presentation. Everybody else's takes
      // its turn, which is what keeps a roll, its payout and the next roll in
      // order instead of overlapping.
      if (next.active) {
        _queue.clear();
        _begin(_Scene.roll(next));
      } else {
        _enqueue(_Scene.roll(next));
      }
    } else {
      // Somebody else placing a piece is worth watching too, and the public
      // activity says what was built but not where, so the board is diffed.
      final piece = newPiece(old.snapshot, next);
      if (piece != null) _enqueue(_Scene.piece(next, piece));
    }
    // Activity can follow the snapshot in the next update. Accept it during
    // the dice/camera lead-in, then freeze the order once deliveries start.
    if (_roll != null && _ms < _flightStart) {
      final previousEnd = _endMs;
      _flights = resourceFlights(_roll!, widget.activity);
      if (_endMs != previousEnd) _animateToEnd();
    }
  }

  void _enqueue(_Scene scene) {
    if (_showing == null) {
      _begin(scene);
      return;
    }
    if (_queue.length == 4) _queue.removeAt(0);
    _queue.add(scene);
  }

  void _begin(_Scene scene) {
    _showing = scene;
    if (scene.isRoll) _presented = scene.snapshot;
    _flights = scene.isRoll
        ? resourceFlights(scene.snapshot, widget.activity)
        : const [];
    _start = _transform.value.clone();
    _focus = null;
    _animation.value = 0;
    _animateToEnd();
  }

  void _finish() {
    _animation.stop();
    setState(() {
      _showing = null;
      if (_queue.isNotEmpty) _begin(_queue.removeAt(0));
    });
  }

  /// The board is a child of the panel list, and a sibling appearing or
  /// disappearing above it can leave that child unpositioned for the frame the
  /// list is relaying out. Reading a transform through an unpositioned sliver
  /// child throws, so treat it as not measurable yet and skip a frame instead.
  RenderBox? _box(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    for (RenderObject? node = box; node != null; node = node.parent) {
      final data = node.parentData;
      if (data is SliverMultiBoxAdaptorParentData &&
          data.layoutOffset == null) {
        return null;
      }
    }
    return box;
  }

  // Controller values are elapsed milliseconds, so a late payout can extend
  // the sequence without jumping forward or changing a flight's speed.
  double get _ms => _animation.value;
  double get _returnAt =>
      _flightStart +
      _flights.length * (_flightMs + _gapMs) -
      (_flights.isEmpty ? 0 : _gapMs) +
      200;
  double get _endMs {
    final scene = _showing!;
    if (!scene.isRoll) {
      return _reducedMotion ? _holdMs : 2 * _cameraMs + _holdMs;
    }
    return _reducedMotion || scene.snapshot.producingHexes.isEmpty
        ? _diceMs
        : _returnAt + _cameraMs;
  }

  /// A camera that puts a scene point in the middle of the viewer at [zoom]
  /// without panning past the edge of the board.
  Matrix4 _look(Offset centre, double zoom, Size viewport) {
    // Scene coordinates are 720x650. The viewer child is fitted to its width.
    final scale = viewport.width / boardSize.width;
    final target = centre * scale;
    final dx = (viewport.width / 2 - target.dx * zoom).clamp(
      viewport.width * (1 - zoom),
      0.0,
    );
    final dy = (viewport.height / 2 - target.dy * zoom).clamp(
      viewport.height * (1 - zoom),
      0.0,
    );
    return Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(zoom, zoom, 1, 1);
  }

  /// Zoom to the piece somebody else just placed, hold long enough to register,
  /// then hand the board back centred.
  void _tickPiece(_Scene scene) {
    if (_reducedMotion) {
      if (_ms >= _endMs) _finish();
      return;
    }
    if (_focus == null) {
      final viewport = _viewerBox()?.size;
      if (viewport == null) return;
      _focus = _look(
        centreOf(scene.snapshot, scene.piece!.locationId),
        _pieceZoom,
        viewport,
      );
    }
    if (_ms <= _cameraMs) {
      _transform.value = Matrix4Tween(begin: _start, end: _focus).transform(
        Curves.easeInOutCubic.transform((_ms / _cameraMs).clamp(0, 1)),
      );
    } else if (_ms < _cameraMs + _holdMs) {
      _transform.value = _focus!.clone();
    } else {
      _transform.value = Matrix4Tween(begin: _focus, end: Matrix4.identity())
          .transform(
            Curves.easeInOutCubic.transform(
              ((_ms - _cameraMs - _holdMs) / _cameraMs).clamp(0, 1),
            ),
          );
    }
    if (_ms >= _endMs) _finish();
  }

  void _animateToEnd() {
    _animation.animateTo(
      _endMs,
      duration: Duration(milliseconds: (_endMs - _ms).ceil()),
    );
  }

  void _tick() {
    final showing = _showing;
    if (showing == null) return;
    if (!showing.isRoll) {
      _tickPiece(showing);
      return;
    }
    if (_reducedMotion || _roll!.producingHexes.isEmpty) {
      if (_ms >= _diceMs) _finish();
      return;
    }
    if (_ms < _diceMs) return;
    final scene = _box(_scene);
    if (scene == null || !scene.attached) return;
    if (_focus == null) {
      // Fit the producing group, not one tile at the expense of the others.
      final points = _roll!.producingHexes
          .map((id) => centreOf(_roll!, id))
          .toList();
      final left = points.map((p) => p.dx).reduce(math.min);
      final right = points.map((p) => p.dx).reduce(math.max);
      final top = points.map((p) => p.dy).reduce(math.min);
      final bottom = points.map((p) => p.dy).reduce(math.max);
      final centre = Offset((left + right) / 2, (top + bottom) / 2);
      final viewport = _viewerBox()?.size;
      if (viewport == null) return;
      // Fit every producing tile and stay below the next texture-resolution
      // bucket so a roll never rebakes the terrain at the default zoom.
      final zoom = math
          .min(
            1.32,
            math.min(
              boardSize.width / (right - left + 150),
              boardSize.height / (bottom - top + 150),
            ),
          )
          .clamp(1.0, 1.32);
      _focus = _look(centre, zoom, viewport);
    }
    if (_ms <= _flightStart) {
      _transform.value = Matrix4Tween(begin: _start, end: _focus).transform(
        Curves.easeInOutCubic.transform(
          ((_ms - _diceMs) / _cameraMs).clamp(0, 1),
        ),
      );
    } else if (_ms < _returnAt) {
      _transform.value = _focus!.clone();
    } else {
      // Hand the board back centred rather than wherever the camera started,
      // so the next roll always begins from the same view of the island.
      _transform.value = Matrix4Tween(begin: _focus, end: Matrix4.identity())
          .transform(
            Curves.easeInOutCubic.transform(
              ((_ms - _returnAt) / _cameraMs).clamp(0, 1),
            ),
          );
    }
    if (_ms >= _endMs) _finish();
  }

  RenderBox? _viewerBox() => _box(_viewport);

  void _cancel() {
    _queue.clear();
    if (_showing == null) return;
    _animation.stop();
    // Keep the current camera position when interrupted; the user's next
    // gesture takes over without an unexpected snap back.
    setState(() => _showing = null);
  }

  @override
  void dispose() {
    _animation.dispose();
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    return Listener(
      onPointerDown: (_) => _cancel(),
      onPointerSignal: (_) => _cancel(),
      child: Stack(
        key: _surface,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 560
                      ? 4
                      : constraints.maxWidth >= 280 &&
                            MediaQuery.textScalerOf(context).scale(12) <= 18
                      ? 2
                      : 1;
                  final width =
                      (constraints.maxWidth - (columns - 1) * 6) / columns;
                  return Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final player in s.orderedPlayers)
                        SizedBox(
                          width: width,
                          child: PlayerBadge(
                            key: _players.putIfAbsent(
                              player['id'] as String,
                              GlobalKey.new,
                            ),
                            player: player,
                            own: player['id'] == s.playerId,
                            active: player['id'] == s.public['activePlayerId'],
                            onTap: () => widget.onPlayer(player),
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 4),
              IslandBoard(
                snapshot: s,
                producing: _rings,
                targets: widget.targets,
                selected: widget.selected,
                onTarget: widget.onTarget,
                menu: widget.menu,
                transformationController: _transform,
                sceneKey: _scene,
                viewportKey: _viewport,
                onInteraction: _cancel,
              ),
            ],
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _animation,
                builder: (context, _) => _overlay(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _overlay() {
    final showing = _showing;
    if (showing != null && !showing.isRoll) return _pieceLabel(showing);
    final roll = _roll;
    final scene = _box(_scene), surface = _box(_surface);
    if (roll == null || scene == null || surface == null) {
      return const SizedBox.shrink();
    }
    Offset local(Offset point) =>
        surface.globalToLocal(scene.localToGlobal(point));
    if (_ms < _diceMs) {
      final viewer = _viewerBox();
      if (viewer == null) return const SizedBox.shrink();
      final centre = surface.globalToLocal(
        viewer.localToGlobal(viewer.size.center(Offset.zero)),
      );
      final dice = (roll.public['dice'] as List).cast<int>();
      final settling = !_reducedMotion && _ms < 520;
      final fade = _reducedMotion
          ? 1.0
          : ((_diceMs - _ms) / 250).clamp(0.0, 1.0);
      return Stack(
        children: [
          Positioned(
            left: centre.dx,
            top: centre.dy,
            child: FractionalTranslation(
              translation: const Offset(-.5, -.5),
              child: SizedBox(
                width: math.min(200, viewer.size.width - 16),
                child: Opacity(
                  opacity: fade,
                  child: Semantics(
                    liveRegion: true,
                    label:
                        '${roll.name(roll.public['activePlayerId'] as String)} rolled ${dice[0]} and ${dice[1]}, total ${dice[0] + dice[1]}',
                    child: ExcludeSemantics(
                      child: RepaintBoundary(
                        child: Container(
                          key: const Key('roll-dice-overlay'),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xee173e43),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: const Color(0xffd5ba78)),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  for (var i = 0; i < 2; i++)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                      ),
                                      child: Transform.rotate(
                                        angle: settling
                                            ? math.sin(_ms / 55 + i) * .16
                                            : 0,
                                        child: CustomPaint(
                                          size: const Size.square(48),
                                          painter: _DiePainter(
                                            settling
                                                ? ((_ms ~/ 75 + i * 2) % 6) + 1
                                                : dice[i],
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                settling
                                    ? 'Rolling…'
                                    : '${dice[0]} + ${dice[1]} = ${dice[0] + dice[1]}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 18,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (_reducedMotion || _ms < _flightStart) return const SizedBox.shrink();
    final index = ((_ms - _flightStart) / (_flightMs + _gapMs)).floor();
    final elapsed = _ms - _flightStart - index * (_flightMs + _gapMs);
    // Exactly one icon, with a gap after arrival. The return camera waits for
    // the last delivery regardless of how many cards the roll awarded.
    if (index >= _flights.length || elapsed >= _flightMs) {
      return const SizedBox.shrink();
    }
    return Stack(
      children: [
        _flyingResource(
          _flights[index],
          local,
          surface,
          elapsed / _flightMs,
          index,
        ),
      ],
    );
  }

  /// Names what another seat just placed. The camera shows where; this says who
  /// and what, because a road appearing at the edge of vision is easy to miss.
  Widget _pieceLabel(_Scene scene) {
    final surface = _box(_surface), viewer = _viewerBox();
    if (surface == null || viewer == null) return const SizedBox.shrink();
    final piece = scene.piece!;
    final says = piece.what == 'city'
        ? 'upgraded to a city'
        : 'built a ${piece.what}';
    final message = '${scene.snapshot.name(piece.playerId)} $says';
    final fade = _reducedMotion
        ? 1.0
        : math.min(
            (_ms / 200).clamp(0.0, 1.0),
            ((_endMs - _ms) / 250).clamp(0.0, 1.0),
          );
    final origin = surface.globalToLocal(viewer.localToGlobal(Offset.zero));
    return Stack(
      children: [
        Positioned(
          left: origin.dx,
          top: origin.dy + 10,
          width: viewer.size.width,
          child: Center(
            child: Opacity(
              opacity: fade,
              child: Semantics(
                liveRegion: true,
                label: message,
                child: ExcludeSemantics(
                  child: RepaintBoundary(
                    child: Container(
                      key: const Key('build-focus-label'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xee173e43),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: const Color(0xffd5ba78)),
                      ),
                      child: Text(
                        message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _flyingResource(
    ResourceFlight flight,
    Offset Function(Offset) local,
    RenderBox surface,
    double progress,
    int index,
  ) {
    final target = _box(_players[flight.playerId]!);
    if (target == null) return const SizedBox.shrink();
    final from = local(centreOf(_roll!, flight.hexId));
    final to = surface.globalToLocal(
      target.localToGlobal(target.size.center(Offset.zero)),
    );
    final eased = Curves.easeInOutCubic.transform(progress);
    final point =
        Offset.lerp(from, to, eased)! -
        Offset(0, math.sin(progress * math.pi) * 34);
    return Positioned(
      key: ValueKey('resource-flight-$index'),
      left: point.dx - 18,
      top: point.dy - 18,
      child: Transform.scale(
        scale: .7 + .3 * math.sin(progress * math.pi),
        child: RepaintBoundary(child: ResourceIcon(flight.resource, size: 36)),
      ),
    );
  }
}

class PlayerBadge extends StatelessWidget {
  const PlayerBadge({
    super.key,
    required this.player,
    required this.own,
    required this.active,
    required this.onTap,
  });
  final JsonMap player;
  final bool own, active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colour = playerColours[player['colour']] ?? hudTeal;
    final bot = player['kind'] == 'BOT';
    return Semantics(
      label:
          '${player['nickname']}${own ? ', you' : ''}${bot ? ', bot' : ''}, '
          '${player['publicPoints']} public points, ${player['resourceCardCount']} resource cards, '
          '${player['developmentCardCount']} development cards, ${player['playedKnights']} knights played'
          '${active ? ', active player' : ''}',
      button: true,
      child: Material(
        color: active ? colour.withValues(alpha: .13) : hudSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: active ? colour : hudBorder,
            width: active ? 2 : 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 15,
                        backgroundColor: colour,
                        child: Icon(
                          bot ? Icons.smart_toy_outlined : Icons.person_outline,
                          color: inkOn(colour),
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${player['nickname']}${own
                              ? ' · You'
                              : bot
                              ? ' · Bot'
                              : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      if (active)
                        Icon(Icons.arrow_right, color: colour, size: 18),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 9,
                    runSpacing: 4,
                    children: [
                      _stat(
                        context,
                        Icons.star_rounded,
                        player['publicPoints'],
                        'Points',
                      ),
                      _stat(
                        context,
                        Icons.style_outlined,
                        player['resourceCardCount'],
                        'Resource cards',
                      ),
                      _stat(
                        context,
                        Icons.credit_card,
                        player['developmentCardCount'],
                        'Development cards',
                      ),
                      _stat(
                        context,
                        Icons.shield_outlined,
                        player['playedKnights'],
                        'Knights played',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stat(
    BuildContext context,
    IconData icon,
    Object value,
    String label,
  ) => Tooltip(
    message: label,
    child: InkWell(
      onTap: label == 'Points'
          ? onTap
          : () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                icon: Icon(icon, color: hudTeal),
                title: Text(label),
                content: Text(switch (label) {
                  'Knights played' =>
                    '${player['nickname']} has played $value knights. Three or more, and the most of anyone, takes Largest Army and its two points.',
                  'Development cards' =>
                    '${player['nickname']} holds $value unplayed development cards. Their kinds stay hidden until played.',
                  _ =>
                    '${player['nickname']} holds $value resource cards. Everyone sees the count; only their owner sees which.',
                }),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: hudMuted),
          const SizedBox(width: 3),
          Text(
            '$value',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

class ResourceDock extends StatelessWidget {
  const ResourceDock({super.key, required this.stock, this.gains});
  final Map<String, int> stock;
  final Map<String, int>? gains;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: Color(0xff173e43),
      border: Border(top: BorderSide(color: Color(0xffbb9d63), width: 2)),
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Semantics(
          label:
              'Your resources: ${resourceTypes.map((r) => '${stock[r]} $r').join(', ')}',
          child: ExcludeSemantics(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final resource in resourceTypes)
                  Expanded(
                    child: Tooltip(
                      message:
                          '${words(resource)}: ${stock[resource]}${(gains?[resource] ?? 0) > 0 ? ', +${gains![resource]} this roll' : ''}',
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              ResourceIcon(resource, size: 36),
                              if ((gains?[resource] ?? 0) > 0)
                                Positioned(
                                  right: -9,
                                  top: -3,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: const Color(0xffe9d28e),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                      child: Text(
                                        '+${gains![resource]}',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: hudInk,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${words(resource)} ${stock[resource]}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _DiePainter extends CustomPainter {
  const _DiePainter(this.value);
  final int value;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint();
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(10)),
      paint..color = const Color(0xfffff5dd),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(1), const Radius.circular(9)),
      paint
        ..color = const Color(0xffd1b77e)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    paint
      ..style = PaintingStyle.fill
      ..color = hudInk;
    final points = <Offset>[
      if (value.isOdd) const Offset(.5, .5),
      if (value >= 2) ...[const Offset(.25, .25), const Offset(.75, .75)],
      if (value >= 4) ...[const Offset(.75, .25), const Offset(.25, .75)],
      if (value == 6) ...[const Offset(.25, .5), const Offset(.75, .5)],
    ];
    for (final p in points) {
      canvas.drawCircle(
        Offset(p.dx * size.width, p.dy * size.height),
        size.width * .075,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DiePainter old) => old.value != value;
}
