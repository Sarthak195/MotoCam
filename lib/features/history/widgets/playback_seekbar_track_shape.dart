import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import 'playback_timeline.dart';

/// Colour of footage that is declared but missing or unreadable.
const Color missingFootageColor = MotoColors.rec;

/// Colour of footage that failed the integrity check.
const Color failedCheckColor = Color(0xFFC792FF);

/// Colour of ride time that has no video at all (for example overwritten by
/// loop recording).
const Color noVideoColor = Color(0xFF78909C);

/// Colour of incident markers (an amber triangle above the track).
const Color incidentMarkerColor = MotoColors.amber;

/// Colour of locked-segment markers (a blue diamond under the track).
const Color lockMarkerColor = MotoColors.lock;

/// Colour of the clip-edge ticks under the track.
const Color clipEdgeColor = MotoColors.muted;

/// Slider track for ride playback that also paints timeline ranges and event
/// markers.
///
/// Ranges and markers are drawn inside the slider's own track rectangle, so
/// they line up exactly with the positions the slider reports, and they are
/// always laid out at the slider's size.
class PlaybackSeekbarTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  /// Creates the track shape. All positions are in milliseconds from ride
  /// start, on a timeline [totalDurationMs] long.
  const PlaybackSeekbarTrackShape({
    required this.totalDurationMs,
    this.missingRanges = const <PlaybackRange>[],
    this.failedCheckRanges = const <PlaybackRange>[],
    this.noVideoRanges = const <PlaybackRange>[],
    this.incidentMarkerMs = const <int>[],
    this.lockMarkerMs = const <int>[],
    this.clipEdgeMs = const <int>[],
  });

  /// Length of the timeline in milliseconds.
  final int totalDurationMs;

  /// Declared footage that is missing or unreadable, drawn in
  /// [missingFootageColor].
  final List<PlaybackRange> missingRanges;

  /// Footage that failed the integrity check, drawn in [failedCheckColor].
  final List<PlaybackRange> failedCheckRanges;

  /// Ride time without any video, drawn in [noVideoColor].
  final List<PlaybackRange> noVideoRanges;

  /// Incident marker positions, drawn as [incidentMarkerColor] triangles
  /// above the track.
  final List<int> incidentMarkerMs;

  /// Locked-segment marker positions, drawn as [lockMarkerColor] diamonds
  /// under the track.
  final List<int> lockMarkerMs;

  /// Clip edges: a notch across the track and a [clipEdgeColor] tick under
  /// it.
  final List<int> clipEdgeMs;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    required TextDirection textDirection,
    bool isDiscrete = false,
    bool isEnabled = false,
    Offset? secondaryOffset,
  }) {
    final trackHeight = sliderTheme.trackHeight;
    if (trackHeight == null || trackHeight <= 0) {
      return;
    }

    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (trackRect.width <= 0 || trackRect.height <= 0) {
      return;
    }

    final activeColor = isEnabled
        ? (sliderTheme.activeTrackColor ?? Colors.blueAccent)
        : (sliderTheme.disabledActiveTrackColor ??
              sliderTheme.activeTrackColor ??
              Colors.blueGrey);
    final inactiveColor = isEnabled
        ? (sliderTheme.inactiveTrackColor ?? Colors.white24)
        : (sliderTheme.disabledInactiveTrackColor ??
              sliderTheme.inactiveTrackColor ??
              Colors.white24);

    final canvas = context.canvas;
    final trackRRect = RRect.fromRectAndRadius(
      trackRect,
      Radius.circular(trackRect.height / 2),
    );

    canvas.drawRRect(trackRRect, Paint()..color = inactiveColor);

    final clampedThumbX = thumbCenter.dx.clamp(trackRect.left, trackRect.right);
    final activeRect = textDirection == TextDirection.ltr
        ? Rect.fromLTRB(
            trackRect.left,
            trackRect.top,
            clampedThumbX,
            trackRect.bottom,
          )
        : Rect.fromLTRB(
            clampedThumbX,
            trackRect.top,
            trackRect.right,
            trackRect.bottom,
          );

    if (activeRect.width > 0) {
      canvas.save();
      canvas.clipRRect(trackRRect);
      canvas.drawRect(activeRect, Paint()..color = activeColor);
      canvas.restore();
    }

    if (totalDurationMs <= 0) {
      return;
    }

    double xFor(int elapsedMs) {
      final normalized = (elapsedMs / totalDurationMs).clamp(0.0, 1.0);
      return trackRect.left + (trackRect.width * normalized);
    }

    final centerY = trackRect.center.dy;
    final halfTrack = trackRect.height / 2;

    canvas.save();
    canvas.clipRRect(trackRRect);
    // Clip edges: a background-coloured notch across the track, so the
    // clips read as separate pieces. It goes under the range fills, so a
    // short failed-check, missing or no-video range on an edge still shows.
    final notchPaint = Paint()
      ..color = MotoColors.bg
      ..strokeWidth = 3;
    for (final edgeMs in clipEdgeMs) {
      final x = xFor(edgeMs);
      canvas.drawLine(
        Offset(x, trackRect.top),
        Offset(x, trackRect.bottom),
        notchPaint,
      );
    }

    void drawRanges(List<PlaybackRange> ranges, Color color) {
      final paint = Paint()..color = color.withValues(alpha: 0.86);
      for (final range in ranges) {
        final left = xFor(range.startMs);
        final right = xFor(range.endMs);
        if (right - left <= 0) {
          continue;
        }
        canvas.drawRect(
          Rect.fromLTRB(left, trackRect.top, right, trackRect.bottom),
          paint,
        );
      }
    }

    drawRanges(noVideoRanges, noVideoColor);
    drawRanges(missingRanges, missingFootageColor);
    drawRanges(failedCheckRanges, failedCheckColor);
    canvas.restore();

    // Clip edges: a muted tick under the track.
    final tickPaint = Paint()
      ..color = clipEdgeColor
      ..strokeWidth = 1.5;
    for (final edgeMs in clipEdgeMs) {
      final x = xFor(edgeMs);
      canvas.drawLine(
        Offset(x, centerY + halfTrack + 4),
        Offset(x, centerY + halfTrack + 8),
        tickPaint,
      );
    }

    // Locked clips: a diamond under the track.
    final lockPaint = Paint()..color = lockMarkerColor;
    for (final markerMs in lockMarkerMs) {
      final x = xFor(markerMs);
      final cy = centerY + halfTrack + 12;
      canvas.drawPath(
        Path()
          ..moveTo(x, cy - 6)
          ..lineTo(x + 6, cy)
          ..lineTo(x, cy + 6)
          ..lineTo(x - 6, cy)
          ..close(),
        lockPaint,
      );
    }

    // Incidents: a triangle above the track, pointing down at it.
    final incidentPaint = Paint()..color = incidentMarkerColor;
    for (final markerMs in incidentMarkerMs) {
      final x = xFor(markerMs);
      final tip = centerY - halfTrack - 3;
      canvas.drawPath(
        Path()
          ..moveTo(x, tip)
          ..lineTo(x - 7, tip - 13)
          ..lineTo(x + 7, tip - 13)
          ..close(),
        incidentPaint,
      );
    }
  }
}
