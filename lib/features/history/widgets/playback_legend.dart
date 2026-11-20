import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import 'playback_seekbar_track_shape.dart';
import 'playback_timeline.dart';

/// The row under the timeline that names each kind of range and marker
/// present in [marks], each with the shape the timeline draws: a triangle
/// for incidents, a diamond for locked clips, a tick for clip edges and a
/// bar for each kind of range. Empty when nothing is marked.
///
/// Lock markers are named "Locked", not "Your mark": a clip can also be
/// locked automatically by a detected incident.
class PlaybackLegend extends StatelessWidget {
  /// Creates the legend for [marks].
  const PlaybackLegend({super.key, required this.marks});

  /// What the timeline marks.
  final PlaybackTimelineMarks marks;

  @override
  Widget build(BuildContext context) {
    if (marks.isEmpty && marks.clipEdgeMs.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        if (marks.incidentMarkerMs.isNotEmpty)
          const _LegendEntry(
            _LegendShape.triangle,
            incidentMarkerColor,
            'Incident',
          ),
        if (marks.lockMarkerMs.isNotEmpty)
          const _LegendEntry(_LegendShape.diamond, lockMarkerColor, 'Locked'),
        if (marks.clipEdgeMs.isNotEmpty)
          const _LegendEntry(_LegendShape.tick, clipEdgeColor, 'Clip edge'),
        if (marks.noVideoRanges.isNotEmpty)
          const _LegendEntry(_LegendShape.bar, noVideoColor, 'No video'),
        if (marks.missingRanges.isNotEmpty)
          const _LegendEntry(
            _LegendShape.bar,
            missingFootageColor,
            'Missing segment',
          ),
        if (marks.failedCheckRanges.isNotEmpty)
          const _LegendEntry(
            _LegendShape.bar,
            failedCheckColor,
            'Failed integrity check',
          ),
      ],
    );
  }
}

enum _LegendShape { triangle, diamond, tick, bar }

class _LegendEntry extends StatelessWidget {
  const _LegendEntry(this.shape, this.color, this.label);

  final _LegendShape shape;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          size: Size(shape == _LegendShape.bar ? 14 : 12, 12),
          painter: _LegendShapePainter(shape, color),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            style: MotoFonts.bodyStyle(13, color: MotoColors.dim),
          ),
        ),
      ],
    );
  }
}

class _LegendShapePainter extends CustomPainter {
  const _LegendShapePainter(this.shape, this.color);

  final _LegendShape shape;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final w = size.width;
    final h = size.height;
    switch (shape) {
      case _LegendShape.triangle:
        canvas.drawPath(
          Path()
            ..moveTo(w / 2, h)
            ..lineTo(0, h * 0.12)
            ..lineTo(w, h * 0.12)
            ..close(),
          paint,
        );
      case _LegendShape.diamond:
        canvas.drawPath(
          Path()
            ..moveTo(w / 2, 0)
            ..lineTo(w, h / 2)
            ..lineTo(w / 2, h)
            ..lineTo(0, h / 2)
            ..close(),
          paint,
        );
      case _LegendShape.tick:
        canvas.drawLine(
          Offset(w / 2, 0),
          Offset(w / 2, h),
          paint..strokeWidth = 2,
        );
      case _LegendShape.bar:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(0, h / 2 - 4, w, 8),
            const Radius.circular(4),
          ),
          paint,
        );
    }
  }

  @override
  bool shouldRepaint(covariant _LegendShapePainter oldDelegate) =>
      oldDelegate.shape != shape || oldDelegate.color != color;
}
