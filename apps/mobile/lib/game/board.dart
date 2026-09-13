import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'model.dart';

const playerColours = {
  'RED': Color(0xffbd493d),
  'BLUE': Color(0xff3276ae),
  'WHITE': Color(0xffeee4d0),
  'ORANGE': Color(0xffdf942d),
};
const terrainColours = {
  'HILLS': Color(0xffbf775e),
  'FOREST': Color(0xff427f68),
  'PASTURE': Color(0xff91b776),
  'FIELDS': Color(0xffd9b758),
  'MOUNTAINS': Color(0xff929ea1),
  'DESERT': Color(0xffd9c596),
};
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

class IslandBoard extends StatefulWidget {
  const IslandBoard({
    super.key,
    required this.snapshot,
    this.targets = const {},
    this.selected,
    required this.onTarget,
  });
  final GameSnapshot snapshot;
  final Set<String> targets;
  final String? selected;
  final ValueChanged<String> onTarget;
  @override
  State<IslandBoard> createState() => _IslandBoardState();
}

class _IslandBoardState extends State<IslandBoard> {
  final transform = TransformationController();
  @override
  void dispose() {
    transform.dispose();
    super.dispose();
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
            final scale = transform.value.getMaxScaleOnAxis();
            final factor = math.min(1.25, 3.5 / scale);
            transform.value = transform.value.clone()
              ..scaleByDouble(factor, factor, 1, 1);
          },
          icon: const Icon(Icons.zoom_in),
        ),
        IconButton(
          tooltip: 'Fit island',
          onPressed: () => transform.value = Matrix4.identity(),
          icon: const Icon(Icons.center_focus_strong),
        ),
      ];
      final island = ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: AspectRatio(
          aspectRatio: boardSize.aspectRatio,
          child: LayoutBuilder(
            builder: (context, constraints) => InteractiveViewer(
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
                    child: CustomPaint(
                      size: boardSize,
                      painter: IslandPainter(
                        widget.snapshot,
                        widget.targets,
                        widget.selected,
                        widget.onTarget,
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

/// Original vector presentation; no licensed board art or raster dependency.
class IslandPainter extends CustomPainter {
  IslandPainter(this.s, this.targets, this.selected, this.onTarget);
  final GameSnapshot s;
  final Set<String> targets;
  final String? selected;
  final ValueChanged<String> onTarget;
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
  }) {
    final p = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontSize: size,
          color: colour,
          fontWeight: weight,
          fontFamily: 'sans-serif',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    p.paint(c, centre - Offset(p.width / 2, p.height / 2));
  }

  @override
  void paint(Canvas c, Size size) {
    c.drawRect(Offset.zero & size, Paint()..color = const Color(0xffd5e9e4));
    for (var y = 28.0; y < size.height; y += 34) {
      for (var x = 18.0; x < size.width; x += 54) {
        final p = Path()
          ..moveTo(x, y)
          ..quadraticBezierTo(x + 8, y + 5, x + 16, y);
        c.drawPath(
          p,
          Paint()
            ..color = const Color(0xffbdd9d3)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
    for (final entry in s.hexes.entries) {
      final hex = entry.value as Map,
          points = (hex['vertexIds'] as List)
              .map((v) => vertexPoint(s.vertices[v]))
              .toList();
      final path = Path()..addPolygon(points, true);
      c.drawShadow(path, const Color(0xff315f55), 3, false);
      c.drawPath(path, Paint()..color = terrainColours[hex['terrain']]!);
      c.drawPath(
        path,
        Paint()
          ..color = const Color(0xfff8f1de)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5,
      );
      final centre = centreOf(s, entry.key);
      _terrain(c, hex['terrain'] as String, centre + const Offset(0, -24));
      if (hex['number'] != null) {
        final at = centre + const Offset(0, 19),
            red = [6, 8].contains(hex['number']);
        c.drawCircle(at, 23, Paint()..color = const Color(0xfffff8e9));
        text(
          c,
          '${hex['number']}',
          at - const Offset(0, 3),
          28,
          colour: red ? const Color(0xffa83d33) : const Color(0xff253e38),
        );
        final count = 6 - (7 - (hex['number'] as int)).abs();
        for (var i = 0; i < count; i++) {
          c.drawCircle(
            at + Offset((i - (count - 1) / 2) * 5, 15),
            1.8,
            Paint()
              ..color = red ? const Color(0xffa83d33) : const Color(0xff253e38),
          );
        }
      }
    }
    for (final port in (s.board['ports'] as Map).values.cast<Map>()) {
      final a = vertexPoint(s.vertices[port['vertexIds'][0]]),
          b = vertexPoint(s.vertices[port['vertexIds'][1]]),
          middle = (a + b) / 2;
      final direction = middle - const Offset(360, 325),
          point = middle + direction / direction.distance * 38;
      line(c, a, point, const Color(0xff648d84), 3);
      line(c, b, point, const Color(0xff648d84), 3);
      c.drawCircle(point, 22, Paint()..color = const Color(0xfffbf6e8));
      text(c, '${port['ratio']}:1', point - const Offset(0, 5), 17);
      text(
        c,
        port['resourceType'] == null
            ? 'ANY'
            : (port['resourceType'] as String).toUpperCase(),
        point + const Offset(0, 11),
        9,
      );
    }
    for (final road in s.roads.entries) {
      final vertices = s.edges[road.key]['vertexIds'] as List,
          owner = s.players[road.value['ownerPlayerId']] as Map;
      final a = vertexPoint(s.vertices[vertices[0]]),
          b = vertexPoint(s.vertices[vertices[1]]);
      line(c, a, b, const Color(0xff253e38), 14);
      line(c, a, b, playerColours[owner['colour']]!, 9);
      text(
        c,
        '${(owner['seatIndex'] as int) + 1}',
        (a + b) / 2,
        13,
        colour: owner['colour'] == 'BLUE' || owner['colour'] == 'RED'
            ? Colors.white
            : const Color(0xff253e38),
      );
    }
    for (final building in s.buildings.entries) {
      final at = vertexPoint(s.vertices[building.key]),
          owner = s.players[building.value['ownerPlayerId']] as Map;
      final city = building.value['type'] == 'CITY', w = city ? 16.0 : 12.0;
      final path = Path()
        ..moveTo(at.dx - w, at.dy + 12)
        ..lineTo(at.dx - w, at.dy - 3)
        ..lineTo(at.dx, at.dy - 16)
        ..lineTo(at.dx + w, at.dy - 3)
        ..lineTo(at.dx + w, at.dy + 12)
        ..close();
      c.drawPath(path, Paint()..color = playerColours[owner['colour']]!);
      c.drawPath(
        path,
        Paint()
          ..color = const Color(0xff253e38)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
      text(
        c,
        '${(owner['seatIndex'] as int) + 1}${city ? '+' : ''}',
        at + const Offset(0, 2),
        13,
        colour: ['RED', 'BLUE'].contains(owner['colour'])
            ? Colors.white
            : const Color(0xff253e38),
      );
    }
    final robber =
        centreOf(s, s.public['robberHexId'] as String) + const Offset(28, -6);
    c.drawCircle(
      robber - const Offset(0, 13),
      9,
      Paint()..color = const Color(0xff243d3a),
    );
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: robber + const Offset(0, 6),
          width: 24,
          height: 29,
        ),
        const Radius.circular(9),
      ),
      Paint()..color = const Color(0xff243d3a),
    );
    for (final id in targets) {
      final at = centreOf(s, id), chosen = id == selected;
      c.drawCircle(
        at,
        chosen ? 18 : 12,
        Paint()
          ..color = chosen ? const Color(0xfff7c45a) : const Color(0xfffdf8eb),
      );
      c.drawCircle(
        at,
        chosen ? 18 : 12,
        Paint()
          ..color = const Color(0xff1d6256)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
      if (chosen) text(c, '✓', at, 23);
    }
  }

  void _terrain(Canvas c, String type, Offset at) {
    final paint = Paint()..color = const Color(0x60304b3f);
    for (var i = -1; i <= 1; i++) {
      final p = at + Offset(i * 20, i == 0 ? -4 : 5);
      switch (type) {
        case 'FOREST':
        case 'MOUNTAINS':
          c.drawPath(
            Path()
              ..moveTo(p.dx - 12, p.dy + 12)
              ..lineTo(p.dx, p.dy - 13)
              ..lineTo(p.dx + 12, p.dy + 12)
              ..close(),
            paint,
          );
          if (type == 'FOREST') {
            line(
              c,
              p + const Offset(0, 5),
              p + const Offset(0, 17),
              const Color(0xff365947),
              4,
            );
          }
        case 'FIELDS':
          line(
            c,
            p + const Offset(0, -12),
            p + const Offset(0, 16),
            const Color(0xff927737),
            3,
          );
          for (var y = -8.0; y < 10; y += 7) {
            line(
              c,
              p + Offset(-6, y - 4),
              p + Offset(0, y),
              const Color(0xff927737),
              3,
            );
            line(
              c,
              p + Offset(6, y - 4),
              p + Offset(0, y),
              const Color(0xff927737),
              3,
            );
          }
        case 'HILLS':
          c.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(center: p, width: 19, height: 12),
              const Radius.circular(2),
            ),
            paint,
          );
        case 'PASTURE':
          c.drawOval(
            Rect.fromCenter(center: p, width: 24, height: 17),
            Paint()..color = const Color(0xaafff7df),
          );
          c.drawCircle(p + const Offset(10, 3), 4, paint);
        default:
          c.drawArc(
            Rect.fromCenter(center: p, width: 30, height: 15),
            0,
            math.pi,
            false,
            Paint()
              ..color = const Color(0xffb19969)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3,
          );
      }
    }
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
      oldDelegate.s != s ||
      oldDelegate.targets != targets ||
      oldDelegate.selected != selected;
  @override
  bool shouldRebuildSemantics(covariant IslandPainter oldDelegate) =>
      shouldRepaint(oldDelegate);
}
