// lib/core/ui/dashed_outline.dart

import 'dart:ui' show PathMetric;

import 'package:flutter/widgets.dart';

/// Paints a dashed rounded-rectangle outline over its child, as the boards
/// draw a CSS `dashed` border.
class DashedOutline extends StatelessWidget {
  /// Creates a dashed outline around [child].
  const DashedOutline({
    super.key,
    required this.color,
    required this.radius,
    required this.child,
    this.strokeWidth = 1.5,
    this.dash = 6,
    this.gap = 4,
  });

  /// Dash colour.
  final Color color;

  /// Corner radius.
  final double radius;

  /// Line width.
  final double strokeWidth;

  /// Length of each dash.
  final double dash;

  /// Space between dashes.
  final double gap;

  /// The content inside the outline.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _DashedRRectPainter(
        color: color,
        radius: radius,
        strokeWidth: strokeWidth,
        dash: dash,
        gap: gap,
      ),
      child: child,
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  _DashedRRectPainter({
    required this.color,
    required this.radius,
    required this.strokeWidth,
    required this.dash,
    required this.gap,
  });

  final Color color;
  final double radius;
  final double strokeWidth;
  final double dash;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(strokeWidth / 2);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    for (final PathMetric metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.dash != dash ||
      oldDelegate.gap != gap;
}
