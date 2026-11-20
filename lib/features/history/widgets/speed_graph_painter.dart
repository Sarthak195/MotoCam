import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../telemetry/models/telemetry_data.dart';
import 'playback_seekbar_track_shape.dart';
import 'playback_timeline.dart';

/// Number of speed-graph windows one page of the curve spans (see
/// [speedGraphPageIndex]).
const int speedGraphPageWindows = 3;

/// Paints one page of the speed graph's curve: the speed line and dots and
/// the lock and incident ticks for the ride times from [pageStartMs] for
/// [speedGraphPageWindows] windows.
///
/// A page does not depend on the playback position. The strip shows it
/// slid sideways behind a repaint boundary as the position moves, so this
/// painter runs again only when the position enters another page or one of
/// its inputs changes. It draws `windowMs` of ride time over every
/// `viewportWidth` pixels, so the page is [speedGraphPageWindows] viewport
/// widths wide.
class SpeedGraphPagePainter extends CustomPainter {
  /// Creates the painter for the page that starts at [pageStartMs].
  const SpeedGraphPagePainter({
    required this.samples,
    required this.maxSpeed,
    required this.windowMs,
    required this.pageStartMs,
    required this.viewportWidth,
    required this.incidentMarkerMs,
    required this.lockMarkerMs,
  });

  /// Number of times any page has been painted; for tests.
  @visibleForTesting
  static int paintCount = 0;

  /// Telemetry samples of the ride, ordered by elapsed time.
  final List<TelemetryData> samples;

  /// Speed, in km/h, that reaches the top of the strip.
  final double maxSpeed;

  /// Ride time, in milliseconds, that fits in [viewportWidth].
  final int windowMs;

  /// Ride time, in milliseconds, at the left edge of the page.
  final int pageStartMs;

  /// Width, in logical pixels, of the strip that shows [windowMs].
  final double viewportWidth;

  /// Incident marker times.
  final List<int> incidentMarkerMs;

  /// Locked-segment marker times.
  final List<int> lockMarkerMs;

  @override
  void paint(Canvas canvas, Size size) {
    paintCount++;
    if (samples.length < 2 || windowMs <= 0 || viewportWidth <= 0) {
      return;
    }
    final pxPerMs = viewportWidth / windowMs;
    final pageEndMs = pageStartMs + speedGraphPageWindows * windowMs;

    void drawEventMarkers(List<int> markers, Color color) {
      if (markers.isEmpty) {
        return;
      }
      final paint = Paint()
        ..color = color.withValues(alpha: 0.85)
        ..strokeWidth = 1.2;
      for (final marker in markers) {
        if (marker < pageStartMs || marker > pageEndMs) {
          continue;
        }
        final x = (marker - pageStartMs) * pxPerMs;
        canvas.drawLine(
          Offset(x, size.height - 10),
          Offset(x, size.height),
          paint,
        );
      }
    }

    drawEventMarkers(lockMarkerMs, lockMarkerColor);
    drawEventMarkers(incidentMarkerMs, incidentMarkerColor);

    // One sample either side of the page keeps the line running to its edges.
    final firstIndex = math.max(
      firstSampleIndexAtOrAfter(samples, pageStartMs) - 1,
      0,
    );
    final path = Path();
    final points = <Offset>[];
    for (var i = firstIndex; i < samples.length; i++) {
      final sample = samples[i];
      final x = (sample.elapsedMs - pageStartMs) * pxPerMs;
      final point = Offset(x, speedGraphY(sample.speed, maxSpeed, size.height));
      if (points.isEmpty) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
      points.add(point);
      if (sample.elapsedMs > pageEndMs) {
        break;
      }
    }
    if (points.isEmpty) {
      return;
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = MotoColors.text
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    final dotPaint = Paint()
      ..color = MotoColors.text
      ..style = PaintingStyle.fill;
    for (final point in points) {
      canvas.drawCircle(point, 1.7, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant SpeedGraphPagePainter oldDelegate) {
    return oldDelegate.pageStartMs != pageStartMs ||
        oldDelegate.windowMs != windowMs ||
        oldDelegate.viewportWidth != viewportWidth ||
        oldDelegate.maxSpeed != maxSpeed ||
        !identical(oldDelegate.samples, samples) ||
        !identical(oldDelegate.lockMarkerMs, lockMarkerMs) ||
        !identical(oldDelegate.incidentMarkerMs, incidentMarkerMs);
  }
}

/// Colour of the dot that marks the playhead on the speed graph.
const Color speedGraphCursorColor = MotoColors.text;

/// Paints the dot that marks the sample nearest the playback
/// position, at the centre of the strip, on top of the (static) curve.
class SpeedGraphCursorPainter extends CustomPainter {
  /// Creates the cursor for [positionMs].
  const SpeedGraphCursorPainter({
    required this.samples,
    required this.maxSpeed,
    required this.windowMs,
    required this.positionMs,
  });

  /// Number of times the cursor has been painted; for tests.
  @visibleForTesting
  static int paintCount = 0;

  /// Telemetry samples of the ride, ordered by elapsed time.
  final List<TelemetryData> samples;

  /// Speed, in km/h, that reaches the top of the strip.
  final double maxSpeed;

  /// Ride time, in milliseconds, that fits the strip's width.
  final int windowMs;

  /// Playback position in milliseconds from ride start.
  final int positionMs;

  @override
  void paint(Canvas canvas, Size size) {
    paintCount++;
    if (samples.length < 2 || windowMs <= 0) {
      return;
    }
    final index = nearestSampleIndex(samples, positionMs);
    if (index == null) {
      return;
    }
    final sample = samples[index];
    final x =
        size.width / 2 +
        (sample.elapsedMs - positionMs) / windowMs * size.width;
    if (x < -2 || x > size.width + 2) {
      return;
    }
    canvas.drawCircle(
      Offset(x, speedGraphY(sample.speed, maxSpeed, size.height)),
      3.5,
      Paint()
        ..color = speedGraphCursorColor
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant SpeedGraphCursorPainter oldDelegate) {
    return oldDelegate.positionMs != positionMs ||
        oldDelegate.windowMs != windowMs ||
        oldDelegate.maxSpeed != maxSpeed ||
        !identical(oldDelegate.samples, samples);
  }
}

/// Returns the vertical position of [speed] on a strip [height] pixels tall
/// whose top is [maxSpeed], leaving a 4 px margin at both ends.
double speedGraphY(double speed, double maxSpeed, double height) =>
    height - ((speed / maxSpeed) * (height - 8)) - 4;
