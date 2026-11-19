// lib/core/ui/moto_glyph.dart

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The simple drawn marks of the kit. Each state uses a different shape,
/// so states are told apart without relying on colour.
enum MotoGlyphShape {
  /// An open ring: READY.
  ring,

  /// A ring with a small centre dot: STARTING.
  ringDot,

  /// A filled dot: REC.
  dot,

  /// A filled rounded square: STOP and SAVING.
  square,

  /// A thick ring around a filled dot in [MotoGlyph.accent]: the START mark.
  startMark,
}

/// Draws a [MotoGlyphShape] in a [size] square.
class MotoGlyph extends StatelessWidget {
  /// Creates a glyph.
  const MotoGlyph({
    super.key,
    required this.shape,
    required this.size,
    required this.color,
    this.accent,
  });

  /// What to draw.
  final MotoGlyphShape shape;

  /// Edge length of the square box.
  final double size;

  /// Stroke and fill colour.
  final Color color;

  /// Inner fill of [MotoGlyphShape.startMark]; [color] when null.
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _GlyphPainter(shape, color, accent ?? color),
        ),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.shape, this.color, this.accent);

  final MotoGlyphShape shape;
  final Color color;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    // Geometry follows the 24-unit viewBox of the boards' SVGs (76 units for
    // the START mark).
    final unit = math.min(size.width, size.height) / 24;
    final centre = size.center(Offset.zero);
    final fill = Paint()..color = color;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke;
    switch (shape) {
      case MotoGlyphShape.ring:
        canvas.drawCircle(centre, 8 * unit, stroke..strokeWidth = 2.5 * unit);
      case MotoGlyphShape.ringDot:
        canvas.drawCircle(centre, 8 * unit, stroke..strokeWidth = 2.5 * unit);
        canvas.drawCircle(centre, 3.5 * unit, fill);
      case MotoGlyphShape.dot:
        canvas.drawCircle(centre, 10 * unit, fill);
      case MotoGlyphShape.square:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: centre,
              width: 18 * unit,
              height: 18 * unit,
            ),
            Radius.circular(2 * unit),
          ),
          fill,
        );
      case MotoGlyphShape.startMark:
        final u = math.min(size.width, size.height) / 76;
        canvas.drawCircle(centre, 34 * u, stroke..strokeWidth = 5 * u);
        canvas.drawCircle(centre, 22 * u, Paint()..color = accent);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) =>
      oldDelegate.shape != shape ||
      oldDelegate.color != color ||
      oldDelegate.accent != accent;
}
