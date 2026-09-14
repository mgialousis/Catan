import 'package:flutter/material.dart';

/// Original, scalable resource illustrations; the adjacent label names the card.
class ResourceIcon extends StatelessWidget {
  const ResourceIcon(this.resource, {super.key, this.size = 30});
  final String resource;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      size: Size.square(size),
      painter: _ResourcePainter(resource),
    ),
  );
}

class _ResourcePainter extends CustomPainter {
  const _ResourcePainter(this.resource);
  final String resource;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 32, size.height / 32);
    final paint = Paint();
    void oval(Rect rect, Color color) =>
        canvas.drawOval(rect, paint..color = color);
    void line(Offset a, Offset b, Color color, [double width = 2]) =>
        canvas.drawLine(
          a,
          b,
          paint
            ..color = color
            ..strokeWidth = width
            ..strokeCap = StrokeCap.round,
        );
    void polygon(List<Offset> points, Color color) =>
        canvas.drawPath(Path()..addPolygon(points, true), paint..color = color);
    canvas.drawCircle(
      const Offset(16, 16),
      15,
      paint..color = const Color(0xfff7efdc),
    );
    switch (resource) {
      case 'brick':
        for (final p in [
          const Offset(5, 18),
          const Offset(17, 18),
          const Offset(11, 9),
        ]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              p & const Size(11, 8),
              const Radius.circular(1.5),
            ),
            paint..color = const Color(0xffb9593f),
          );
          line(
            p + const Offset(2, 2),
            p + const Offset(8, 2),
            const Color(0xffe69a6e),
            1.5,
          );
        }
      case 'lumber':
        for (final x in [11.0, 21.0]) {
          line(Offset(x, 17), Offset(x, 27), const Color(0xff805638), 3);
          polygon([
            Offset(x, 4),
            Offset(x - 7, 20),
            Offset(x + 7, 20),
          ], const Color(0xff286b4b));
          polygon([
            Offset(x, 4),
            Offset(x - 5, 15),
            Offset(x, 13),
          ], const Color(0xff63a16b));
        }
      case 'wool':
        line(
          const Offset(11, 20),
          const Offset(10, 26),
          const Color(0xff695c50),
        );
        line(
          const Offset(22, 20),
          const Offset(23, 26),
          const Color(0xff695c50),
        );
        oval(const Rect.fromLTWH(5, 10, 22, 14), const Color(0xffc9cbb7));
        for (final p in [
          const Offset(10, 13),
          const Offset(15, 10),
          const Offset(20, 13),
          const Offset(13, 18),
          const Offset(19, 18),
        ]) {
          canvas.drawCircle(p, 5, paint..color = const Color(0xfffffdf4));
        }
        oval(const Rect.fromLTWH(23, 12, 6, 9), const Color(0xff695c50));
        canvas.drawCircle(
          const Offset(27, 14),
          0.9,
          paint..color = Colors.white,
        );
      case 'grain':
        for (final x in [11.0, 21.0]) {
          line(Offset(x, 7), Offset(x, 27), const Color(0xffb48727), 1.5);
          for (final y in [9.0, 15.0, 21.0]) {
            oval(Rect.fromLTWH(x - 5, y - 3, 5, 7), const Color(0xffd8a536));
            oval(Rect.fromLTWH(x, y - 5, 5, 7), const Color(0xffefc75e));
          }
        }
      case 'ore':
        polygon(const [
          Offset(4, 24),
          Offset(9, 9),
          Offset(20, 5),
          Offset(28, 20),
          Offset(22, 27),
        ], const Color(0xff697989));
        polygon(const [
          Offset(9, 9),
          Offset(20, 5),
          Offset(17, 18),
          Offset(4, 24),
        ], const Color(0xffa5b4c1));
        polygon(const [
          Offset(17, 18),
          Offset(28, 20),
          Offset(22, 27),
        ], const Color(0xff465567));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ResourcePainter oldDelegate) =>
      oldDelegate.resource != resource;
}
