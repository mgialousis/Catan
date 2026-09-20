import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'model.dart';

/// Board presentation is entirely procedural. Every tile, piece, token and wave
/// below is drawn from paths, gradients and seeded noise, so there is no raster
/// dependency, no licensed or traced art, nothing to download, and the board
/// stays crisp at any zoom level.
///
/// The layout maths (`vertexPoint`, `centreOf`) is deliberately untouched by the
/// visual work: depth comes from layered painting inside each tile's existing
/// footprint rather than from a canvas transform, so hit testing, the semantics
/// tree and the device-matrix layout tests all keep working against the same
/// coordinates they always used.

// ---------------------------------------------------------------------------
// Design tokens
// ---------------------------------------------------------------------------

const playerColours = {
  'RED': Color(0xffbd493d),
  'BLUE': Color(0xff3276ae),
  'ORANGE': Color(0xffdf942d),
  'PURPLE': Color(0xff7d4ea3),
  'BLACK': Color(0xff32383d),
  // Still rendered for games that already use it, but no longer handed out:
  // ivory pieces sit badly against the board's own rims and number tokens.
  'WHITE': Color(0xffeee4d0),
};

const _oceanDeep = Color(0xff14567c);
const _oceanMid = Color(0xff2b81a8);
const _oceanLight = Color(0xff57aac4);
const _shelf = Color(0xff7fd0d8);
const _foam = Color(0xffe4f4f0);
const _sand = Color(0xffe6d3a3);
const _sandShade = Color(0xffc3a874);
const _ink = Color(0xff1b3130);
const _parchment = Color(0xfffdf6e4);
const _parchmentEdge = Color(0xffd9c79b);
const _tokenRed = Color(0xffa5352b);

/// One terrain's complete palette: three tones for the sunlit-to-shaded gradient
/// across the top face, the extruded side wall, and two inks for decoration.
class TerrainStyle {
  const TerrainStyle({
    required this.high,
    required this.base,
    required this.low,
    required this.wall,
    required this.detail,
    required this.accent,
  });
  final Color high, base, low, wall, detail, accent;
}

const terrainStyles = <String, TerrainStyle>{
  'FOREST': TerrainStyle(
    high: Color(0xff62a478),
    base: Color(0xff428459),
    low: Color(0xff2b6044),
    wall: Color(0xff1d4030),
    detail: Color(0xff1f6b45),
    accent: Color(0xff8bc98f),
  ),
  'PASTURE': TerrainStyle(
    high: Color(0xffa8d37f),
    base: Color(0xff80b560),
    low: Color(0xff5d9149),
    wall: Color(0xff3d6935),
    detail: Color(0xff4f8340),
    accent: Color(0xfff4f8ea),
  ),
  'FIELDS': TerrainStyle(
    high: Color(0xfff1ce71),
    base: Color(0xffdcae4a),
    low: Color(0xffbb8b31),
    wall: Color(0xff8a6321),
    detail: Color(0xffa9762a),
    accent: Color(0xfffbe9ab),
  ),
  'HILLS': TerrainStyle(
    high: Color(0xffdd9268),
    base: Color(0xffc0714c),
    low: Color(0xff965239),
    wall: Color(0xff6b3928),
    detail: Color(0xff8a4a33),
    accent: Color(0xffedbe97),
  ),
  'MOUNTAINS': TerrainStyle(
    high: Color(0xffbcc6cc),
    base: Color(0xff8e9aa2),
    low: Color(0xff69747d),
    wall: Color(0xff49535b),
    detail: Color(0xff5b666e),
    accent: Color(0xfff4f9fc),
  ),
  'DESERT': TerrainStyle(
    high: Color(0xfff4e5bc),
    base: Color(0xffe2cd97),
    low: Color(0xffc4a970),
    wall: Color(0xff998151),
    detail: Color(0xffb89a63),
    accent: Color(0xfffaf1d9),
  ),
};

/// Retained for callers that only need a single representative tone per terrain.
final terrainColours = {
  for (final e in terrainStyles.entries) e.key: e.value.base,
};

Color _shift(Color colour, double amount) {
  final hsl = HSLColor.fromColor(colour);
  return hsl.withLightness((hsl.lightness + amount).clamp(0.0, 1.0)).toColor();
}

Color lighten(Color colour, [double amount = 0.12]) => _shift(colour, amount);
Color darken(Color colour, [double amount = 0.12]) => _shift(colour, -amount);

/// Readable text colour for a label sitting on an arbitrary player colour.
Color inkOn(Color colour) =>
    colour.computeLuminance() > 0.45 ? const Color(0xff23342c) : Colors.white;

/// Stable per-feature seed so procedural decoration never shimmers between
/// repaints. `String.hashCode` is not guaranteed stable, so hash explicitly.
int featureSeed(String id) {
  var hash = 0x811c9dc5;
  for (final unit in id.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0x3fffffff;
  }
  return hash;
}

// ---------------------------------------------------------------------------
// Layout (unchanged)
// ---------------------------------------------------------------------------

const boardSize = Size(720, 650);
Offset vertexPoint(Map vertex) => Offset(
  360 + (vertex['x'] as num) * 28 * math.sqrt(3),
  325 + (vertex['y'] as num) * 28,
);
Offset centreOf(GameSnapshot s, String id) {
  if (id.startsWith('v-')) return vertexPoint(s.vertices[id]);
  final ids =
      (id.startsWith('e-') ? s.edges[id] : s.hexes[id])['vertexIds'] as List;
  return ids.map((v) => vertexPoint(s.vertices[v])).reduce((a, b) => a + b) /
      ids.length.toDouble();
}

String locationLabel(GameSnapshot s, String id) {
  if (id.startsWith('h-')) {
    return '${words(s.hexes[id]['terrain'] as String)} ${s.hexes[id]['number'] ?? 'desert'}';
  }
  final refs =
      (id.startsWith('v-') ? s.vertices[id]['hexIds'] : s.edges[id]['hexIds'])
          as List;
  return '${id.startsWith('v-') ? 'Junction' : 'Road'} ${id.substring(2)} · ${refs.map((h) => '${words(s.hexes[h]['terrain'] as String)} ${s.hexes[h]['number'] ?? ''}').join(' / ')}';
}

List<Offset> _hexPoints(GameSnapshot s, String id) =>
    (s.hexes[id]['vertexIds'] as List)
        .map((v) => vertexPoint(s.vertices[v]))
        .toList();

/// Union of every tile, used for the drop shadow, reef shelf and coastline.
/// Memoised: the combine is the one non-trivial geometry cost in the terrain
/// layer, and a snapshot's board is immutable for the life of the game.
GameSnapshot? _outlineKey;
Path? _outlineValue;
Path islandOutline(GameSnapshot s) {
  if (identical(_outlineKey, s) && _outlineValue != null) return _outlineValue!;
  var union = Path();
  for (final id in s.hexes.keys) {
    union = Path.combine(
      PathOperation.union,
      union,
      Path()..addPolygon(_hexPoints(s, id), true),
    );
  }
  _outlineKey = s;
  _outlineValue = union;
  return union;
}

// Snapshots are deep-frozen copies, so identity changes even when a trade or
// resource update leaves the board unchanged. Compare only each layer's inputs.
bool _sameJson(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _sameJson(a[key], b[key]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

class IslandBoard extends StatefulWidget {
  const IslandBoard({
    super.key,
    required this.snapshot,
    this.targets = const {},
    this.selected,
    required this.onTarget,
    this.producing,
    this.menu,
    this.transformationController,
    this.sceneKey,
    this.viewportKey,
    this.onInteraction,
  });
  final GameSnapshot snapshot;
  final Set<String> targets;
  final String? selected;
  final ValueChanged<String> onTarget;

  /// Hexes to ring as having just paid out. Defaults to the snapshot's own last
  /// roll; an animating table overrides it with the roll it is presenting, so
  /// the rings and the dice on screen always describe the same roll.
  final Set<String>? producing;

  /// Optional control placed beside the title, so the table's own actions sit
  /// with the board rather than scattered through the panels below it.
  final Widget? menu;
  final TransformationController? transformationController;
  final GlobalKey? sceneKey;
  final GlobalKey? viewportKey;
  final VoidCallback? onInteraction;
  @override
  State<IslandBoard> createState() => _IslandBoardState();
}

class _IslandBoardState extends State<IslandBoard>
    with SingleTickerProviderStateMixin {
  late final transform =
      widget.transformationController ?? TransformationController();
  String? hovered;

  /// Resolution multiplier the terrain is baked at. Bucketed, and capped at 2:
  /// a 3x bake of this board would be about seventeen megabytes of texture for
  /// a detail level the eye barely resolves through a pinch.
  int terrainResolution = 1;

  void _trackZoom() {
    final scale = transform.value.getMaxScaleOnAxis();
    final bucket = scale < 1.4 ? 1 : 2;
    if (bucket != terrainResolution) {
      setState(() => terrainResolution = bucket);
    }
  }

  /// A bounded one-shot, never a repeating pulse: the widget tests drive this
  /// board through `pumpAndSettle`, which never returns while an animation is
  /// still scheduled. Feedback therefore animates on change and then rests.
  late final AnimationController reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    transform.addListener(_trackZoom);
  }

  @override
  void didUpdateWidget(covariant IslandBoard old) {
    super.didUpdateWidget(old);
    if (!setEquals(old.targets, widget.targets) ||
        old.selected != widget.selected) {
      reveal.forward(from: 0);
    }
  }

  @override
  void dispose() {
    reveal.dispose();
    transform.removeListener(_trackZoom);
    if (widget.transformationController == null) transform.dispose();
    super.dispose();
  }

  void _hover(Offset at) {
    if (widget.snapshot.hexes.isEmpty) return;
    final near = widget.snapshot.hexes.keys.reduce(
      (a, b) =>
          (centreOf(widget.snapshot, a) - at).distance <
              (centreOf(widget.snapshot, b) - at).distance
          ? a
          : b,
    );
    final hit = (centreOf(widget.snapshot, near) - at).distance < 52
        ? near
        : null;
    if (hit != hovered) setState(() => hovered = hit);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, outer) {
      final header = <Widget>[
        const Expanded(
          child: Text(
            'THE ISLAND',
            style: TextStyle(
              letterSpacing: 2,
              fontWeight: FontWeight.w700,
              color: Color(0xff335f5b),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Zoom in',
          onPressed: () {
            widget.onInteraction?.call();
            final scale = transform.value.getMaxScaleOnAxis();
            final factor = math.min(1.25, 3.5 / scale);
            transform.value = transform.value.clone()
              ..scaleByDouble(factor, factor, 1, 1);
          },
          icon: const Icon(Icons.zoom_in),
        ),
        IconButton(
          tooltip: 'Fit island',
          onPressed: () {
            widget.onInteraction?.call();
            transform.value = Matrix4.identity();
          },
          icon: const Icon(Icons.center_focus_strong),
        ),
        ?widget.menu,
      ];
      final island = ClipRRect(
        key: widget.viewportKey,
        borderRadius: BorderRadius.circular(24),
        child: AspectRatio(
          aspectRatio: boardSize.aspectRatio,
          child: LayoutBuilder(
            builder: (context, constraints) => InteractiveViewer(
              onInteractionStart: (_) => widget.onInteraction?.call(),
              transformationController: transform,
              minScale: 1,
              maxScale: 3.5,
              boundaryMargin: const EdgeInsets.all(50),
              child: SizedBox(
                width: constraints.maxWidth,
                height: constraints.maxHeight,
                child: FittedBox(
                  child: GestureDetector(
                    onTapUp: (details) {
                      if (widget.targets.isNotEmpty) {
                        final sorted = widget.targets.toList()
                          ..sort(
                            (a, b) =>
                                (centreOf(widget.snapshot, a) -
                                        details.localPosition)
                                    .distance
                                    .compareTo(
                                      (centreOf(widget.snapshot, b) -
                                              details.localPosition)
                                          .distance,
                                    ),
                          );
                        if ((centreOf(widget.snapshot, sorted.first) -
                                    details.localPosition)
                                .distance <
                            36) {
                          widget.onTarget(sorted.first);
                        }
                      } else {
                        final hex = widget.snapshot.hexes.keys.reduce(
                          (a, b) =>
                              (centreOf(widget.snapshot, a) -
                                          details.localPosition)
                                      .distance <
                                  (centreOf(widget.snapshot, b) -
                                          details.localPosition)
                                      .distance
                              ? a
                              : b,
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(locationLabel(widget.snapshot, hex)),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                    child: MouseRegion(
                      onHover: (event) => _hover(event.localPosition),
                      onExit: (_) {
                        if (hovered != null) setState(() => hovered = null);
                      },
                      child: SizedBox.fromSize(
                        key: widget.sceneKey,
                        size: boardSize,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // Retain the expensive artwork below the zoom
                            // transform, independently of pieces and feedback.
                            RepaintBoundary(
                              child: CustomPaint(
                                isComplex: true,
                                willChange: false,
                                painter: _TerrainPainter(
                                  widget.snapshot,
                                  terrainResolution,
                                ),
                              ),
                            ),
                            RepaintBoundary(
                              child: CustomPaint(
                                isComplex: true,
                                painter: _PiecesPainter(widget.snapshot),
                              ),
                            ),
                            RepaintBoundary(
                              child: CustomPaint(
                                painter: IslandPainter(
                                  widget.snapshot,
                                  widget.targets,
                                  widget.selected,
                                  widget.onTarget,
                                  widget.producing ??
                                      widget.snapshot.producingHexes,
                                  hovered: hovered,
                                  reveal: reveal,
                                ),
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
      );
      return Column(
        children: [
          Row(children: header),
          // Flexible only when the parent bounds our height; a scroll view leaves it unbounded.
          if (outer.maxHeight.isFinite) Flexible(child: island) else island,
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Pinch to zoom · drag to explore · tap a tile for details',
              style: TextStyle(fontSize: 12, color: Color(0xff586b68)),
            ),
          ),
        ],
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Tile decoration toolkit
// ---------------------------------------------------------------------------

/// The drawing surface handed to each terrain decorator. It carries the tile's
/// footprint, palette and seeded RNG so decorators stay short and declarative,
/// and it is the reason adding a terrain means adding one palette plus one
/// function rather than editing the painter.
class TileBrush {
  TileBrush(
    this.canvas,
    this.centre,
    this.halfWidth,
    this.radius,
    this.style,
    this.rng,
  );
  final Canvas canvas;
  final Offset centre;

  /// Half width and half height of the hexagon, measured from its own vertices.
  final double halfWidth, radius;
  final TerrainStyle style;
  final math.Random rng;

  final _paint = Paint();

  Offset at(double dx, double dy) => centre + Offset(dx, dy);
  double vary(double span) => (rng.nextDouble() - 0.5) * span;

  bool inside(double dx, double dy, double margin) {
    final w = halfWidth - margin, r = radius - margin;
    if (w <= 0 || r <= 0 || dx.abs() > w) return false;
    return dy.abs() <= r - (dx.abs() / w) * (r / 2);
  }

  /// Rejection-sampled points inside the hexagon, avoiding the number token.
  List<Offset> scatter(int count, {Offset? avoid, double avoidRadius = 34}) {
    final points = <Offset>[];
    for (var tries = 0; tries < count * 40 && points.length < count; tries++) {
      final dx = (rng.nextDouble() - 0.5) * halfWidth * 2;
      final dy = (rng.nextDouble() - 0.5) * radius * 2;
      if (!inside(dx, dy, 13)) continue;
      final p = at(dx, dy);
      if (avoid != null && (p - avoid).distance < avoidRadius) continue;
      if (points.any((q) => (q - p).distance < 19)) continue;
      points.add(p);
    }
    return points;
  }

  void fill(Path path, Color colour) =>
      canvas.drawPath(path, _paint..color = colour);

  void stroke(Path path, Color colour, double width) => canvas.drawPath(
    path,
    Paint()
      ..color = colour
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round,
  );

  void line(Offset a, Offset b, Color colour, double width) => canvas.drawLine(
    a,
    b,
    Paint()
      ..color = colour
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round,
  );

  void oval(Offset at, double w, double h, Color colour) => canvas.drawOval(
    Rect.fromCenter(center: at, width: w, height: h),
    _paint..color = colour,
  );

  /// Soft contact shadow that plants a decoration on the ground.
  ///
  /// Shaded with a radial gradient rather than a blurred oval: at these sizes
  /// the two are indistinguishable, and a blur costs an offscreen allocation
  /// and composite for every one of the ~130 the board draws.
  void contact(Offset base, double width) {
    final rect = Rect.fromCenter(
      center: base,
      width: width,
      height: width * 0.34,
    );
    canvas.drawOval(rect, Paint()..shader = _softShadow.createShader(rect));
  }

  /// Broad low-contrast ground mottling; the reason tiles do not read as flat
  /// colour even before their decorations land.
  void mottle(int count, Color colour, {double alpha = 0.16}) {
    for (var i = 0; i < count; i++) {
      final dx = (rng.nextDouble() - 0.5) * halfWidth * 1.8;
      final dy = (rng.nextDouble() - 0.5) * radius * 1.8;
      if (!inside(dx, dy, 6)) continue;
      final rect = Rect.fromCenter(
        center: at(dx, dy),
        width: 20 + rng.nextDouble() * 26,
        height: 12 + rng.nextDouble() * 16,
      );
      canvas.drawOval(
        rect,
        Paint()
          ..shader = RadialGradient(
            colors: [
              colour.withValues(alpha: alpha),
              colour.withValues(alpha: 0),
            ],
          ).createShader(rect),
      );
    }
  }

  /// A two-tone cone: the single most useful primitive here, because splitting
  /// any silhouette into a lit and a shaded half is what makes flat vector
  /// shapes read as solid objects.
  void cone(Offset base, double width, double height, Color lit, Color shade) {
    final apex = base - Offset(0, height);
    fill(
      Path()
        ..moveTo(apex.dx, apex.dy)
        ..lineTo(base.dx - width / 2, base.dy)
        ..lineTo(base.dx, base.dy)
        ..close(),
      lit,
    );
    fill(
      Path()
        ..moveTo(apex.dx, apex.dy)
        ..lineTo(base.dx, base.dy)
        ..lineTo(base.dx + width / 2, base.dy)
        ..close(),
      shade,
    );
  }

  void capsule(Offset at, double w, double h, Color colour) => canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromCenter(center: at, width: w, height: h),
      Radius.circular(w / 2),
    ),
    _paint..color = colour,
  );
}

const _softShadow = RadialGradient(
  colors: [Color(0x3d102018), Color(0x00102018)],
);

typedef Decorator = void Function(TileBrush brush);

/// One entry per terrain; the painter never branches on terrain type itself.
const decorators = <String, Decorator>{
  'FOREST': _forest,
  'PASTURE': _pasture,
  'FIELDS': _fields,
  'HILLS': _hills,
  'MOUNTAINS': _mountains,
  'DESERT': _desert,
};

void _forest(TileBrush b) {
  b.mottle(4, b.style.low, alpha: 0.3);
  b.mottle(2, b.style.high, alpha: 0.18);
  final trees = b.scatter(8, avoid: b.at(0, 12));
  trees.sort((p, q) => p.dy.compareTo(q.dy));
  for (final p in trees) {
    final height = 20 + b.rng.nextDouble() * 11;
    final width = height * 0.56;
    b.contact(p + const Offset(1, 1), width * 1.15);
    b.capsule(
      p - Offset(0, height * 0.1),
      3.4,
      height * 0.3,
      const Color(0xff4a3524),
    );
    for (var tier = 2; tier >= 0; tier--) {
      final base = p - Offset(0, height * (0.16 + tier * 0.24));
      final tierWidth = width * (1 - tier * 0.2);
      b.cone(
        base,
        tierWidth,
        height * 0.42,
        lighten(b.style.detail, 0.15),
        darken(b.style.detail, 0.04),
      );
    }
  }
}

void _pasture(TileBrush b) {
  b.mottle(4, b.style.high, alpha: 0.26);
  b.mottle(3, b.style.low, alpha: 0.22);
  // Rolling crests: a lit arc with its own shadow beneath reads as a hillside.
  for (var i = 0; i < 3; i++) {
    final y = -b.radius * 0.45 + i * b.radius * 0.4 + b.vary(8);
    final w = b.halfWidth * (1.25 - i * 0.16);
    final crest = Path()
      ..moveTo(b.centre.dx - w / 2, b.centre.dy + y)
      ..quadraticBezierTo(
        b.centre.dx + b.vary(16),
        b.centre.dy + y - 15,
        b.centre.dx + w / 2,
        b.centre.dy + y,
      );
    b.stroke(crest, b.style.high.withValues(alpha: 0.5), 5);
    b.stroke(
      crest.shift(const Offset(0, 4)),
      b.style.low.withValues(alpha: 0.32),
      3,
    );
  }
  for (final p in b.scatter(9, avoid: b.at(0, 12), avoidRadius: 32)) {
    if (b.rng.nextDouble() < 0.26) {
      // A grazing animal: the cheapest possible "this board is alive" detail.
      b.contact(p + const Offset(0, 5), 16);
      b.oval(p, 15, 10, b.style.accent);
      b.oval(p + const Offset(-7, -3), 7, 6, darken(b.style.accent, 0.42));
      b.line(
        p + const Offset(-3, 4),
        p + const Offset(-3, 8),
        darken(b.style.accent, 0.42),
        2,
      );
      b.line(
        p + const Offset(4, 4),
        p + const Offset(4, 8),
        darken(b.style.accent, 0.42),
        2,
      );
    } else {
      for (var i = -1; i <= 1; i++) {
        b.line(
          p + Offset(i * 3.0, 4),
          p + Offset(i * 4.5, -5 - i.abs() * 2),
          b.style.detail,
          2,
        );
      }
    }
  }
}

void _fields(TileBrush b) {
  b.mottle(4, b.style.low, alpha: 0.22);
  // Crop rows bow slightly and taper towards the top of the tile, which is
  // enough perspective cue to tilt the field away from the viewer.
  for (var i = 0; i < 11; i++) {
    final t = i / 10;
    final y = -b.radius * 0.72 + t * b.radius * 1.44;
    final w = b.halfWidth * 2 * (0.34 + 0.62 * t) * 0.82;
    final row = Path()
      ..moveTo(b.centre.dx - w / 2, b.centre.dy + y)
      ..quadraticBezierTo(
        b.centre.dx,
        b.centre.dy + y + 4,
        b.centre.dx + w / 2,
        b.centre.dy + y,
      );
    b.stroke(row, i.isEven ? b.style.detail : b.style.accent, 3.4);
    b.stroke(
      row.shift(const Offset(0, 2.4)),
      b.style.low.withValues(alpha: 0.4),
      1.6,
    );
  }
  for (final p in b.scatter(3, avoid: b.at(0, 12), avoidRadius: 40)) {
    b.contact(p + const Offset(0, 7), 15);
    for (var i = -1; i <= 1; i++) {
      b.line(
        p + Offset(i * 4.0, 8),
        p + Offset(i * 6.0, -8),
        b.style.detail,
        3,
      );
    }
    b.oval(p + const Offset(0, -9), 12, 7, b.style.accent);
  }
}

void _hills(TileBrush b) {
  b.mottle(4, b.style.low, alpha: 0.28);
  // Stacked clay terraces, drawn back to front with a lit lip on each.
  for (var i = 0; i < 4; i++) {
    final y = -b.radius * 0.5 + i * b.radius * 0.34;
    final w = b.halfWidth * (1.2 - (i - 1.5).abs() * 0.2);
    final bank = Path()
      ..moveTo(b.centre.dx - w / 2, b.centre.dy + y + 12)
      ..quadraticBezierTo(
        b.centre.dx + b.vary(20),
        b.centre.dy + y - 16,
        b.centre.dx + w / 2,
        b.centre.dy + y + 12,
      )
      ..close();
    b.fill(bank, i.isEven ? b.style.detail : darken(b.style.detail, 0.06));
    b.stroke(
      Path()
        ..moveTo(b.centre.dx - w / 2, b.centre.dy + y + 12)
        ..quadraticBezierTo(
          b.centre.dx + b.vary(6),
          b.centre.dy + y - 16,
          b.centre.dx + w / 2,
          b.centre.dy + y + 12,
        ),
      b.style.accent.withValues(alpha: 0.55),
      2.6,
    );
  }
  for (final p in b.scatter(5, avoid: b.at(0, 12), avoidRadius: 32)) {
    final size = 5 + b.rng.nextDouble() * 4;
    b.contact(p + Offset(0, size * 0.6), size * 2.4);
    b.canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: p, width: size * 2.2, height: size * 1.5),
        const Radius.circular(3),
      ),
      Paint()..color = darken(b.style.detail, 0.12),
    );
    b.canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: p - Offset(0, size * 0.35),
          width: size * 1.9,
          height: size * 0.7,
        ),
        const Radius.circular(3),
      ),
      Paint()..color = b.style.accent.withValues(alpha: 0.6),
    );
  }
}

void _mountains(TileBrush b) {
  b.mottle(4, b.style.low, alpha: 0.3);
  final peaks = <(Offset, double)>[
    (b.at(-22 + b.vary(6), 6), 42),
    (b.at(4 + b.vary(6), 14), 56),
    (b.at(26 + b.vary(6), 4), 36),
  ];
  peaks.sort((a, c) => a.$2.compareTo(c.$2));
  for (final (base, height) in peaks) {
    final width = height * 1.05;
    b.contact(base + const Offset(0, 2), width * 0.9);
    b.cone(base, width, height, b.style.high, b.style.detail);
    // Snow cap: clip a small cone at the apex so it follows the same silhouette.
    final capHeight = height * 0.3;
    final apex = base - Offset(0, height);
    b.fill(
      Path()
        ..moveTo(apex.dx, apex.dy)
        ..lineTo(apex.dx - width * 0.15, apex.dy + capHeight)
        ..lineTo(apex.dx - width * 0.05, apex.dy + capHeight * 0.72)
        ..lineTo(apex.dx + width * 0.07, apex.dy + capHeight)
        ..lineTo(apex.dx + width * 0.15, apex.dy + capHeight * 0.78)
        ..close(),
      b.style.accent,
    );
  }
  for (final p in b.scatter(4, avoid: b.at(0, 12), avoidRadius: 30)) {
    b.oval(p, 6, 4, darken(b.style.detail, 0.08));
  }
}

void _desert(TileBrush b) {
  b.mottle(5, b.style.low, alpha: 0.3);
  for (var i = 0; i < 4; i++) {
    final y = -b.radius * 0.55 + i * b.radius * 0.36 + b.vary(6);
    final w = b.halfWidth * (1.3 - (i - 1.5).abs() * 0.22);
    final dune = Path()
      ..moveTo(b.centre.dx - w / 2, b.centre.dy + y)
      ..cubicTo(
        b.centre.dx - w * 0.2,
        b.centre.dy + y - 13,
        b.centre.dx + w * 0.2,
        b.centre.dy + y + 9,
        b.centre.dx + w / 2,
        b.centre.dy + y - 4,
      );
    b.stroke(
      dune.shift(const Offset(0, 4)),
      b.style.low.withValues(alpha: 0.75),
      5.5,
    );
    b.stroke(dune, b.style.high, 3.6);
    b.stroke(
      dune.shift(const Offset(0, -1.6)),
      b.style.accent.withValues(alpha: 0.9),
      1.6,
    );
  }
  for (final p in b.scatter(6, avoid: b.at(0, 12), avoidRadius: 32)) {
    if (b.rng.nextDouble() < 0.3) {
      b.contact(p + const Offset(0, 10), 16);
      b.capsule(p, 7, 22, const Color(0xff6f9158));
      b.capsule(p + const Offset(-6, -1), 5, 12, const Color(0xff6f9158));
      b.capsule(p + const Offset(6, 3), 5, 10, const Color(0xff6f9158));
      b.capsule(
        p + const Offset(-1.4, 0),
        2,
        18,
        const Color(0xff88ad6c).withValues(alpha: 0.7),
      );
    } else {
      b.contact(p + const Offset(0, 2), 10);
      b.oval(p, 7, 5, b.style.detail);
      b.oval(
        p - const Offset(0, 1),
        5,
        2.6,
        b.style.accent.withValues(alpha: 0.7),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

/// Original vector presentation shared by the independently retained layers.
class _IslandArtwork {
  _IslandArtwork(this.s);
  final GameSnapshot s;

  /// Height of the extruded tile wall. Everything else that needs to look like
  /// it is standing on the island is offset against this one number.
  static const depth = 13.0;

  void line(Canvas c, Offset a, Offset b, Color colour, double width) =>
      c.drawLine(
        a,
        b,
        Paint()
          ..color = colour
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round,
      );

  void text(
    Canvas c,
    String value,
    Offset centre,
    double size, {
    Color colour = const Color(0xff183d3b),
    FontWeight weight = FontWeight.w700,
    Color? halo,
  }) {
    final p = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontSize: size,
          color: colour,
          fontWeight: weight,
          fontFamily: 'sans-serif',
          shadows: halo == null ? null : [Shadow(color: halo, blurRadius: 3.5)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    p.paint(c, centre - Offset(p.width / 2, p.height / 2));
  }

  void terrain(Canvas canvas, Size size) {
    _ocean(canvas, size);
    _coast(canvas);
    _tiles(canvas);
    _ports(canvas);
  }

  void pieces(Canvas canvas) {
    _roads(canvas);
    _buildings(canvas);
    _robber(canvas);
  }

  void hover(Canvas c, String? hovered) {
    if (hovered == null || !s.hexes.containsKey(hovered)) return;
    final path = Path()..addPolygon(_hexPoints(s, hovered), true);
    c.save();
    c.clipPath(path);
    c.drawPath(path, Paint()..color = Colors.white.withValues(alpha: 0.12));
    c.drawPath(
      path,
      Paint()
        ..color = _foam.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7,
    );
    c.restore();
  }

  // -- water ----------------------------------------------------------------

  void _ocean(Canvas c, Size size) {
    final bounds = Offset.zero & size;
    c.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_oceanDeep, _oceanMid, Color(0xff1f6d95)],
          stops: [0, 0.55, 1],
        ).createShader(bounds),
    );
    // A broad light pool under the island lifts it off the deep water.
    c.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.width * 0.42,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                _oceanLight.withValues(alpha: 0.55),
                _oceanLight.withValues(alpha: 0),
              ],
            ).createShader(
              Rect.fromCircle(
                center: Offset(size.width / 2, size.height / 2),
                radius: size.width * 0.42,
              ),
            ),
    );
    // Three wave bands at different scales and opacities; seeded once so the
    // sea is identical on every repaint.
    final rng = math.Random(0x5eab);
    for (final band in [
      (34.0, 62.0, 2.4, 0.20, 15.0),
      (47.0, 78.0, 1.8, 0.13, 22.0),
      (29.0, 96.0, 1.3, 0.09, 9.0),
    ]) {
      final (stepY, stepX, width, alpha, span) = band;
      final paint = Paint()
        ..color = _foam.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round;
      for (var y = 12.0; y < size.height; y += stepY) {
        for (var x = 8.0; x < size.width; x += stepX) {
          final ox = x + rng.nextDouble() * stepX * 0.75,
              oy = y + rng.nextDouble() * stepY * 0.8;
          c.drawPath(
            Path()
              ..moveTo(ox, oy)
              ..quadraticBezierTo(ox + span / 2, oy + 6, ox + span, oy)
              ..quadraticBezierTo(ox + span * 1.5, oy - 6, ox + span * 2, oy),
            paint,
          );
        }
      }
    }
  }

  void _coast(Canvas c) {
    final outline = islandOutline(s);
    // Cast shadow on the water, then the reef shelf, then wet sand, then foam.
    c.drawPath(
      outline.shift(const Offset(0, 14)),
      Paint()
        ..color = const Color(0x59062a3c)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    for (final ring in [
      (42.0, _shelf.withValues(alpha: 0.32), 16.0),
      (26.0, _shelf.withValues(alpha: 0.5), 8.0),
      (14.0, _sandShade, 2.0),
      (9.0, _sand, 0.0),
    ]) {
      final (width, colour, blur) = ring;
      c.drawPath(
        outline,
        Paint()
          ..color = colour
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeJoin = StrokeJoin.round
          ..maskFilter = blur == 0
              ? null
              : MaskFilter.blur(BlurStyle.normal, blur),
      );
    }
    // Foam breaking on the shore, drawn only outside the land so it reads as
    // surf rather than as an outline.
    c.save();
    c.clipPath(outline);
    c.drawPath(
      outline,
      Paint()
        ..color = _foam.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7,
    );
    c.restore();

    // The island's own cliff. Only the seaward edges of the slab are ever
    // visible, which is exactly the impression wanted: land standing above water.
    final cliff = outline.shift(const Offset(0, depth));
    c.drawPath(
      cliff,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [Color(0xff8d6f47), Color(0xff5b452b)],
        ).createShader(cliff.getBounds()),
    );
    c.drawPath(
      cliff,
      Paint()
        ..color = const Color(0xff42301d)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  // -- terrain --------------------------------------------------------------

  void _tiles(Canvas c) {
    // Back to front, so the extruded walls of nearer tiles overlap farther ones.
    final ids = s.hexes.keys.toList()
      ..sort((a, b) => centreOf(s, a).dy.compareTo(centreOf(s, b).dy));
    for (final id in ids) {
      _tile(c, id);
    }
  }

  void _tile(Canvas c, String id) {
    final hex = s.hexes[id] as Map;
    final style = terrainStyles[hex['terrain']] ?? terrainStyles['DESERT']!;
    final points = _hexPoints(s, id);
    final path = Path()..addPolygon(points, true);
    final centre = centreOf(s, id);
    final bounds = path.getBounds();

    // Side wall: the top face stays exactly on the hit-tested polygon and the
    // thickness is drawn beneath it, so depth costs no geometry accuracy.
    final wall = path.shift(const Offset(0, depth));
    final wallBounds = wall.getBounds();
    c.drawPath(
      wall,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(const Color(0xff9a7a4f), style.wall, 0.4)!,
            const Color(0xff533f27),
          ],
        ).createShader(wallBounds),
    );
    c.drawPath(
      wall,
      Paint()
        ..color = const Color(0xff3c2c1a)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );

    c.save();

    c.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [style.high, style.base, style.low],
          stops: const [0, 0.52, 1],
        ).createShader(bounds),
    );

    c.save();
    c.clipPath(path);
    // Seeded decoration, clipped so nothing crosses a tile edge.
    final brush = TileBrush(
      c,
      centre,
      (bounds.width / 2),
      (bounds.height / 2),
      style,
      math.Random(featureSeed(id)),
    );
    (decorators[hex['terrain']] ?? _desert)(brush);
    // Bevel and inner shadow, feathered by stacking translucent strokes rather
    // than by blurring. Three blurs per tile is 57 offscreen allocations across
    // the island; these passes are plain geometry and read the same at size.
    _feather(c, path.shift(const Offset(0, 5)), Colors.white, 0.16, 8);
    _feather(c, path.shift(const Offset(0, -6)), style.wall, 0.2, 10);
    _feather(c, path, style.wall, 0.15, 13);
    c.restore();

    // Tile seam.
    c.drawPath(
      path,
      Paint()
        ..color = const Color(0x4d0f2018)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2,
    );

    if (hex['number'] != null) {
      _token(c, centre + const Offset(0, 12), hex['number'] as int);
    }
    c.restore();
  }

  /// Gradient-shaded contact shadow, for the same reason TileBrush.contact uses
  /// one: the terrain layer draws twenty-seven of these and a blur each would
  /// cost twenty-seven offscreen passes.
  void _dropShadow(Canvas c, Rect rect, Color colour) => c.drawOval(
    rect,
    Paint()
      ..shader = RadialGradient(
        colors: [colour, colour.withValues(alpha: 0)],
      ).createShader(rect),
  );

  /// Approximates a blurred stroke with a few concentric translucent ones. The
  /// alpha compounds where they overlap, giving a soft inner edge for a cost
  /// that scales with stroke count instead of with blur radius.
  void _feather(Canvas c, Path path, Color colour, double alpha, double width) {
    for (var pass = 0; pass < 3; pass++) {
      c.drawPath(
        path,
        Paint()
          ..color = colour.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * (1 - pass * 0.3),
      );
    }
  }

  void _token(Canvas c, Offset at, int number) {
    final hot = number == 6 || number == 8;
    final ink = hot ? _tokenRed : const Color(0xff2c3f38);
    const radius = 18.0;
    _dropShadow(
      c,
      Rect.fromCenter(
        center: at + const Offset(0, 6),
        width: radius * 2.1,
        height: 11,
      ),
      const Color(0x4d101f18),
    );
    c.drawCircle(
      at,
      radius,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.35, -0.45),
          colors: [Color(0xfffffdf5), _parchment, Color(0xffe9d9b4)],
          stops: [0, 0.55, 1],
        ).createShader(Rect.fromCircle(center: at, radius: radius)),
    );
    c.drawCircle(
      at,
      radius - 0.8,
      Paint()
        ..color = _parchmentEdge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    c.drawCircle(
      at,
      radius - 3.4,
      Paint()
        ..color = ink.withValues(alpha: hot ? 0.5 : 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = hot ? 1.8 : 1,
    );
    text(
      c,
      '$number',
      at - const Offset(0, 3),
      hot ? 21 : 19,
      colour: ink,
      weight: hot ? FontWeight.w900 : FontWeight.w800,
    );
    final pips = 6 - (7 - number).abs();
    for (var i = 0; i < pips; i++) {
      c.drawCircle(
        at + Offset((i - (pips - 1) / 2) * 4.0, 10.5),
        hot ? 1.8 : 1.5,
        Paint()..color = ink,
      );
    }
  }

  // -- ports ----------------------------------------------------------------

  void _ports(Canvas c) {
    for (final port in (s.board['ports'] as Map).values.cast<Map>()) {
      final a = vertexPoint(s.vertices[port['vertexIds'][0]]),
          b = vertexPoint(s.vertices[port['vertexIds'][1]]),
          middle = (a + b) / 2;
      final direction = middle - const Offset(360, 325),
          point = middle + direction / direction.distance * 40;
      // Two jetties running from the shore vertices out to the trading post.
      for (final shore in [a, b]) {
        line(c, shore, point, const Color(0x4d0a2030), 9);
        line(c, shore, point, const Color(0xff8a6743), 6);
        line(c, shore, point, const Color(0xffb08a5d), 2.4);
        final along = point - shore, steps = (along.distance / 11).floor();
        final unit = along / along.distance;
        final across = Offset(-unit.dy, unit.dx) * 4.5;
        for (var i = 1; i < steps; i++) {
          final p = shore + unit * (i * 11.0);
          line(c, p - across, p + across, const Color(0xff6f5133), 1.6);
        }
      }
      // A small sail so the post reads as a harbour at a glance.
      final sail = point + const Offset(0, -30);
      line(
        c,
        sail + const Offset(0, 14),
        sail + const Offset(0, -12),
        const Color(0xff6f5133),
        2.4,
      );
      c.drawPath(
        Path()
          ..moveTo(sail.dx + 1, sail.dy - 12)
          ..lineTo(sail.dx + 15, sail.dy + 6)
          ..lineTo(sail.dx + 1, sail.dy + 6)
          ..close(),
        Paint()..color = const Color(0xfff4efe1),
      );
      c.drawPath(
        Path()
          ..moveTo(sail.dx - 1, sail.dy - 8)
          ..lineTo(sail.dx - 11, sail.dy + 6)
          ..lineTo(sail.dx - 1, sail.dy + 6)
          ..close(),
        Paint()..color = const Color(0xffdad2bd),
      );
      // Trading post plaque, matching the number tokens so the board reads as
      // one set of components.
      _dropShadow(
        c,
        Rect.fromCenter(
          center: point + const Offset(0, 7),
          width: 46,
          height: 14,
        ),
        const Color(0x4d0a2030),
      );
      c.drawCircle(
        point,
        23,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(-0.35, -0.45),
            colors: [Color(0xfffffdf5), _parchment, Color(0xffe6d4ac)],
          ).createShader(Rect.fromCircle(center: point, radius: 23)),
      );
      c.drawCircle(
        point,
        22,
        Paint()
          ..color = _parchmentEdge
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2,
      );
      text(c, '${port['ratio']}:1', point - const Offset(0, 6), 17);
      text(
        c,
        port['resourceType'] == null
            ? 'ANY'
            : (port['resourceType'] as String).toUpperCase(),
        point + const Offset(0, 10),
        9,
        colour: const Color(0xff5d5239),
      );
    }
  }

  // -- pieces ---------------------------------------------------------------

  void _roads(Canvas c) {
    for (final road in s.roads.entries) {
      final vertices = s.edges[road.key]['vertexIds'] as List,
          owner = s.players[road.value['ownerPlayerId']] as Map;
      final colour = playerColours[owner['colour']]!;
      final a = vertexPoint(s.vertices[vertices[0]]),
          b = vertexPoint(s.vertices[vertices[1]]);
      final unit = (b - a) / (b - a).distance;
      // Pull the ends in so neighbouring roads read as separate pieces.
      final from = a + unit * 7, to = b - unit * 7;
      line(
        c,
        from + const Offset(0, 8),
        to + const Offset(0, 8),
        const Color(0x4d0d1c16),
        18,
      );
      line(
        c,
        from + const Offset(0, 5),
        to + const Offset(0, 5),
        darken(colour, 0.3),
        17,
      );
      line(c, from, to, _ink, 17);
      line(c, from, to, colour, 13.5);
      line(
        c,
        from - const Offset(0, 3),
        to - const Offset(0, 3),
        lighten(colour, 0.18).withValues(alpha: 0.9),
        4,
      );
      text(
        c,
        '${(owner['seatIndex'] as int) + 1}',
        (from + to) / 2,
        10,
        colour: inkOn(colour),
      );
    }
  }

  void _buildings(Canvas c) {
    // Back to front so overlapping pieces stack believably.
    final ids = s.buildings.keys.toList()
      ..sort((a, b) => centreOf(s, a).dy.compareTo(centreOf(s, b).dy));
    for (final id in ids) {
      final building = s.buildings[id] as Map;
      final at = vertexPoint(s.vertices[id]);
      final owner = s.players[building['ownerPlayerId']] as Map;
      final colour = playerColours[owner['colour']]!;
      final seat = '${(owner['seatIndex'] as int) + 1}';
      if (building['type'] == 'CITY') {
        _city(c, at, colour, seat);
      } else {
        _settlement(c, at, colour, seat);
      }
    }
  }

  void _outlined(Canvas c, Path path, Color fill, {double width = 2.4}) {
    c.drawPath(path, Paint()..color = fill);
    c.drawPath(
      path,
      Paint()
        ..color = _ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _settlement(Canvas c, Offset at, Color colour, String seat) {
    c.drawOval(
      Rect.fromCenter(center: at + const Offset(1, 13), width: 34, height: 12),
      Paint()
        ..color = const Color(0x520d1c16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    // Walls, then a roof split into a lit and a shaded slope.
    _outlined(
      c,
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: at + const Offset(0, 5),
            width: 25,
            height: 17,
          ),
          const Radius.circular(2),
        ),
      ),
      colour,
    );
    _outlined(
      c,
      Path()
        ..moveTo(at.dx, at.dy - 19)
        ..lineTo(at.dx + 16, at.dy - 3.5)
        ..lineTo(at.dx - 16, at.dy - 3.5)
        ..close(),
      lighten(colour, 0.08),
    );
    c.drawPath(
      Path()
        ..moveTo(at.dx, at.dy - 19)
        ..lineTo(at.dx + 16, at.dy - 3.5)
        ..lineTo(at.dx, at.dy - 3.5)
        ..close(),
      Paint()..color = darken(colour, 0.16),
    );
    c.drawRect(
      Rect.fromCenter(center: at + const Offset(0, 8), width: 7, height: 10),
      Paint()..color = darken(colour, 0.3),
    );
    text(c, seat, at + const Offset(0, 1), 10, colour: inkOn(colour));
  }

  void _city(Canvas c, Offset at, Color colour, String seat) {
    c.drawOval(
      Rect.fromCenter(center: at + const Offset(1, 15), width: 48, height: 15),
      Paint()
        ..color = const Color(0x520d1c16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    // A tower beside a main hall: the silhouette alone separates it from a
    // settlement even when the board is fully zoomed out.
    _outlined(
      c,
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: at + const Offset(-11, -2),
            width: 16,
            height: 34,
          ),
          const Radius.circular(2),
        ),
      ),
      colour,
    );
    _outlined(
      c,
      Path()
        ..moveTo(at.dx - 11, at.dy - 30)
        ..lineTo(at.dx - 2, at.dy - 19)
        ..lineTo(at.dx - 20, at.dy - 19)
        ..close(),
      lighten(colour, 0.08),
    );
    _outlined(
      c,
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: at + const Offset(7, 6),
            width: 27,
            height: 22,
          ),
          const Radius.circular(2),
        ),
      ),
      colour,
    );
    _outlined(
      c,
      Path()
        ..moveTo(at.dx + 7, at.dy - 13)
        ..lineTo(at.dx + 22, at.dy - 4)
        ..lineTo(at.dx - 8, at.dy - 4)
        ..close(),
      lighten(colour, 0.08),
    );
    c.drawPath(
      Path()
        ..moveTo(at.dx + 7, at.dy - 13)
        ..lineTo(at.dx + 22, at.dy - 4)
        ..lineTo(at.dx + 7, at.dy - 4)
        ..close(),
      Paint()..color = darken(colour, 0.16),
    );
    for (final w in [
      at + const Offset(-11, -10),
      at + const Offset(1, 6),
      at + const Offset(13, 6),
    ]) {
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: w, width: 6, height: 7),
          const Radius.circular(1.5),
        ),
        Paint()..color = const Color(0xfff6dc94),
      );
    }
    text(c, seat, at + const Offset(7, -8), 10, colour: inkOn(colour));
  }

  void _robber(Canvas c) {
    final at =
        centreOf(s, s.public['robberHexId'] as String) + const Offset(30, -8);
    c.drawOval(
      Rect.fromCenter(center: at + const Offset(1, 20), width: 36, height: 13),
      Paint()
        ..color = const Color(0x660a1712)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    // A hooded figure: cloak, cowl, then a lit edge down one side.
    final cloak = Path()
      ..moveTo(at.dx, at.dy - 20)
      ..cubicTo(
        at.dx + 15,
        at.dy - 14,
        at.dx + 17,
        at.dy + 8,
        at.dx + 15,
        at.dy + 17,
      )
      ..lineTo(at.dx - 15, at.dy + 17)
      ..cubicTo(
        at.dx - 17,
        at.dy + 8,
        at.dx - 15,
        at.dy - 14,
        at.dx,
        at.dy - 20,
      )
      ..close();
    c.drawPath(cloak, Paint()..color = const Color(0xff2a3b3d));
    c.drawPath(
      Path()
        ..moveTo(at.dx, at.dy - 20)
        ..cubicTo(
          at.dx + 15,
          at.dy - 14,
          at.dx + 17,
          at.dy + 8,
          at.dx + 15,
          at.dy + 17,
        )
        ..lineTo(at.dx, at.dy + 17)
        ..close(),
      Paint()..color = const Color(0xff1b2a2c),
    );
    c.drawPath(
      cloak,
      Paint()
        ..color = const Color(0xff0e1a1b)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2,
    );
    c.drawCircle(
      at + const Offset(0, -19),
      9.5,
      Paint()..color = const Color(0xff35484a),
    );
    c.drawCircle(
      at + const Offset(-2.5, -21),
      6,
      Paint()..color = const Color(0xff4a6062),
    );
  }

  // -- selection feedback ---------------------------------------------------

  /// Rings the hexes the last roll paid out from. It belongs to the feedback
  /// layer because it changes on every roll, while the terrain beneath it does
  /// not and stays baked.
  void producing(Canvas c, Set<String> hexes) {
    for (final id in hexes) {
      final path = Path()..addPolygon(_hexPoints(s, id), true);
      c.save();
      c.clipPath(path);
      c.drawPath(
        path,
        Paint()..color = const Color(0xff1fd6cb).withValues(alpha: 0.16),
      );
      // Banded dark-then-bright, because no single colour reads on all six
      // terrains: a light ring disappears into the desert and the fields, a
      // dark one into the forest. The dark band backs the bright one so the
      // pair stays legible on any of them. Cyan is nobody's player colour.
      for (final band in [
        (18.0, const Color(0xcc07343a)),
        (11.0, const Color(0xff1fd6cb)),
        (4.0, const Color(0xffe6fffb)),
      ]) {
        final (width, colour) = band;
        c.drawPath(
          path,
          Paint()
            ..color = colour
            ..style = PaintingStyle.stroke
            ..strokeWidth = width
            ..strokeJoin = StrokeJoin.round,
        );
      }
      c.restore();
    }
  }

  void targets(
    Canvas c,
    Set<String> targets,
    String? selected,
    double revealValue,
  ) {
    final t = Curves.easeOutBack.transform(revealValue.clamp(0.0, 1.0));
    for (final id in targets) {
      final at = centreOf(s, id), chosen = id == selected;
      final scale = chosen ? 1.0 : (0.55 + 0.45 * t);
      final radius = (chosen ? 19.0 : 13.0) * scale;
      // Glow first, so a legal spot is findable without hunting the board.
      c.drawCircle(
        at,
        radius + 10,
        Paint()
          ..color = (chosen ? const Color(0xfff7c45a) : const Color(0xff8fe6d2))
              .withValues(alpha: 0.5 * t)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
      );
      c.drawCircle(
        at,
        radius,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.3, -0.4),
            colors: chosen
                ? const [Color(0xffffe6a6), Color(0xfff3b53f)]
                : const [Colors.white, Color(0xffe8f6ef)],
          ).createShader(Rect.fromCircle(center: at, radius: radius)),
      );
      c.drawCircle(
        at,
        radius,
        Paint()
          ..color = chosen ? const Color(0xff8a5a12) : const Color(0xff1d6256)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.6,
      );
      if (chosen) {
        text(c, '✓', at, 22, colour: const Color(0xff5c3a06));
      }
    }
  }
}

/// Bakes the terrain to an image and blits it.
///
/// A retained layer is re-rasterised whenever the transform's scale changes, so
/// during a pinch the whole island is redrawn every frame and the retention
/// buys nothing. Drawing a baked image instead costs one textured quad at any
/// scale. The bake is repeated only when the caller's resolution bucket
/// changes, so a pinch triggers at most a couple of them.
class _TerrainPainter extends CustomPainter {
  _TerrainPainter(this.s, this.resolution);
  final GameSnapshot s;
  final int resolution;

  static GameSnapshot? _key;
  static int? _keyResolution;
  static Size? _keySize;
  static ui.Image? _cached;
  static ui.Image? _retired;

  ui.Image _image(Size size) {
    if (_cached != null &&
        _keyResolution == resolution &&
        _keySize == size &&
        _key != null &&
        _sameJson(_key!.board, s.board)) {
      return _cached!;
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & size);
    canvas.scale(resolution.toDouble());
    _IslandArtwork(s).terrain(canvas, size);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      (size.width * resolution).round(),
      (size.height * resolution).round(),
    );
    picture.dispose();
    // Retire one generation behind rather than disposing inline: a picture
    // recorded this frame may still reference the outgoing image, and anything
    // that schedules work from paint() re-enters the frame loop.
    _retired?.dispose();
    _retired = _cached;
    _cached = image;
    _key = s;
    _keyResolution = resolution;
    _keySize = size;
    return image;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final image = _image(size);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant _TerrainPainter old) =>
      old.resolution != resolution || !_sameJson(old.s.board, s.board);
}

class _PiecesPainter extends CustomPainter {
  _PiecesPainter(this.s);
  final GameSnapshot s;

  @override
  void paint(Canvas canvas, Size size) => _IslandArtwork(s).pieces(canvas);

  @override
  bool shouldRepaint(covariant _PiecesPainter old) =>
      !_sameJson(old.s.board, s.board) ||
      !_sameJson(old.s.roads, s.roads) ||
      !_sameJson(old.s.buildings, s.buildings) ||
      old.s.public['robberHexId'] != s.public['robberHexId'] ||
      !mapEquals(
        old.s.players.map((id, player) => MapEntry(id, player['colour'])),
        s.players.map((id, player) => MapEntry(id, player['colour'])),
      );
}

/// Interactive feedback and accessibility, separate from the expensive artwork.
class IslandPainter extends CustomPainter {
  IslandPainter(
    this.s,
    this.targets,
    this.selected,
    this.onTarget,
    this.producing, {
    this.hovered,
    this.reveal,
  }) : super(repaint: reveal);

  final GameSnapshot s;
  final Set<String> targets;
  final String? selected;
  final ValueChanged<String> onTarget;
  final Set<String> producing;
  final String? hovered;
  final Animation<double>? reveal;

  @override
  void paint(Canvas canvas, Size size) {
    final artwork = _IslandArtwork(s);
    artwork.producing(canvas, producing);
    artwork.hover(canvas, hovered);
    // Read the live value on each tick; capturing it in the constructor freezes
    // the effect while still scheduling all the animation's repaints.
    artwork.targets(canvas, targets, selected, reveal?.value ?? 1);
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder =>
      (size) => [
        for (final id in s.hexes.keys)
          CustomPainterSemantics(
            rect: Rect.fromCenter(
              center: centreOf(s, id),
              width: 60,
              height: 60,
            ),
            properties: SemanticsProperties(
              label:
                  '${locationLabel(s, id)}${id == s.public['robberHexId'] ? ', robber' : ''}',
              textDirection: TextDirection.ltr,
            ),
          ),
        for (final id in targets)
          CustomPainterSemantics(
            rect: Rect.fromCenter(
              center: centreOf(s, id),
              width: 44,
              height: 44,
            ),
            properties: SemanticsProperties(
              label: 'Select ${locationLabel(s, id)}',
              button: true,
              selected: id == selected,
              onTap: () => onTarget(id),
              textDirection: TextDirection.ltr,
            ),
          ),
        for (final e in s.buildings.entries)
          CustomPainterSemantics(
            rect: Rect.fromCenter(
              center: centreOf(s, e.key),
              width: 36,
              height: 36,
            ),
            properties: SemanticsProperties(
              label:
                  '${s.name(e.value['ownerPlayerId'])}, ${words(e.value['type'])}, ${locationLabel(s, e.key)}',
              textDirection: TextDirection.ltr,
            ),
          ),
      ];
  @override
  bool shouldRepaint(covariant IslandPainter oldDelegate) =>
      !_sameJson(oldDelegate.s.board, s.board) ||
      // The board itself never changes mid-game, so a new roll would otherwise
      // never reach this layer.
      !setEquals(oldDelegate.producing, producing) ||
      !setEquals(oldDelegate.targets, targets) ||
      oldDelegate.selected != selected ||
      oldDelegate.hovered != hovered ||
      oldDelegate.reveal != reveal;
  @override
  bool shouldRebuildSemantics(covariant IslandPainter oldDelegate) =>
      oldDelegate.s != s ||
      !setEquals(oldDelegate.targets, targets) ||
      oldDelegate.selected != selected ||
      oldDelegate.onTarget != onTarget;
}
