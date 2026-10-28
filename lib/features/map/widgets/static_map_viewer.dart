// lib/features/map/widgets/static_map_viewer.dart

import 'package:flutter/material.dart';
import '../../telemetry/models/telemetry_data.dart';
import '../route_points.dart';

/// Offline fallback for the route map, used when a ride has fewer than two
/// GPS fixes to plot on the online map.
///
/// Draws the GPS fixes of [telemetryData] on a plain grid without map tiles.
/// Samples without a GPS fix (see [latLngFromSample]) are ignored, and a ride
/// without any fix shows "No GPS fix recorded for this ride".
class StaticMapViewer extends StatelessWidget {
  /// Telemetry samples of the ride; only samples with a GPS fix are drawn.
  final List<TelemetryData> telemetryData;

  /// Width of the viewer.
  final double width;

  /// Height of the viewer.
  final double height;

  /// Creates a static route viewer for [telemetryData].
  const StaticMapViewer({
    super.key,
    required this.telemetryData,
    this.width = double.infinity,
    this.height = 300,
  });

  @override
  Widget build(BuildContext context) {
    final fixes = samplesWithGpsFix(telemetryData);
    if (fixes.isEmpty) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            telemetryData.isEmpty
                ? 'No location data available'
                : 'No GPS fix recorded for this ride',
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue, width: 1),
      ),
      child: CustomPaint(
        painter: MapPainter(fixes),
        child: Stack(
          children: [
            // Map info
            Positioned(
              right: 12,
              bottom: 12,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'GPS fixes: ${fixes.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Start: ${fixes.first.latitude.toStringAsFixed(4)}, ${fixes.first.longitude.toStringAsFixed(4)}',
                      style: const TextStyle(color: Colors.grey, fontSize: 10),
                    ),
                    Text(
                      'End: ${fixes.last.latitude.toStringAsFixed(4)}, ${fixes.last.longitude.toStringAsFixed(4)}',
                      style: const TextStyle(color: Colors.grey, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Paints a route as speed-coloured line segments with start and end dots.
///
/// Expects samples that carry a GPS fix; a single sample is drawn as one
/// start dot in the centre.
class MapPainter extends CustomPainter {
  /// Samples to draw, in recording order.
  final List<TelemetryData> telemetryData;

  /// Creates a painter for [telemetryData].
  MapPainter(this.telemetryData);

  @override
  void paint(Canvas canvas, Size size) {
    if (telemetryData.isEmpty) {
      return;
    }

    // Draw grid background
    final gridPaint = Paint()
      ..color = Colors.grey[800]!
      ..strokeWidth = 0.5;

    for (double x = 0; x < size.width; x += 40) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y < size.height; y += 40) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (telemetryData.length < 2) {
      _drawEndpoint(
        canvas,
        size.center(Offset.zero),
        Colors.green,
        Colors.lightGreen,
      );
      return;
    }

    // Calculate bounds
    double minLat = telemetryData.first.latitude;
    double maxLat = telemetryData.first.latitude;
    double minLon = telemetryData.first.longitude;
    double maxLon = telemetryData.first.longitude;

    for (final point in telemetryData) {
      minLat = point.latitude < minLat ? point.latitude : minLat;
      maxLat = point.latitude > maxLat ? point.latitude : maxLat;
      minLon = point.longitude < minLon ? point.longitude : minLon;
      maxLon = point.longitude > maxLon ? point.longitude : maxLon;
    }

    // Add padding to bounds
    final latPadding = (maxLat - minLat) * 0.1;
    final lonPadding = (maxLon - minLon) * 0.1;
    minLat -= latPadding;
    maxLat += latPadding;
    minLon -= lonPadding;
    maxLon += lonPadding;

    // Calculate scale
    final latRange = maxLat - minLat;
    final lonRange = maxLon - minLon;

    final latScale = size.height / (latRange != 0 ? latRange : 1);
    final lonScale = size.width / (lonRange != 0 ? lonRange : 1);

    // Use smaller scale to ensure everything fits
    final scale = latScale < lonScale ? latScale : lonScale;

    Offset project(TelemetryData point) => Offset(
      (point.longitude - minLon) * scale,
      size.height - ((point.latitude - minLat) * scale),
    );

    // Draw route with speed-based coloring
    final speedPaint = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    var maxSpeed = telemetryData
        .map((t) => t.speed)
        .reduce((a, b) => a > b ? a : b);
    if (maxSpeed == 0) maxSpeed = 1; // Avoid division by zero

    for (int i = 1; i < telemetryData.length; i++) {
      final point = telemetryData[i];
      final speedRatio = (point.speed / maxSpeed).clamp(0.0, 1.0);
      speedPaint.color = _getColorForSpeed(speedRatio);
      canvas.drawLine(
        project(telemetryData[i - 1]),
        project(point),
        speedPaint,
      );
    }

    _drawEndpoint(
      canvas,
      project(telemetryData.first),
      Colors.green,
      Colors.lightGreen,
    );
    _drawEndpoint(canvas, project(telemetryData.last), Colors.red, Colors.pink);
  }

  void _drawEndpoint(Canvas canvas, Offset center, Color fill, Color border) {
    canvas.drawCircle(
      center,
      6,
      Paint()
        ..color = fill
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      center,
      6,
      Paint()
        ..color = border
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  Color _getColorForSpeed(double speedRatio) {
    // Green (slow) -> Yellow (medium) -> Red (fast)
    if (speedRatio < 0.33) {
      // Green to Yellow
      return Color.lerp(Colors.green, Colors.yellow, speedRatio / 0.33)!;
    } else if (speedRatio < 0.66) {
      // Yellow to Orange
      return Color.lerp(
        Colors.yellow,
        Colors.orange,
        (speedRatio - 0.33) / 0.33,
      )!;
    } else {
      // Orange to Red
      return Color.lerp(Colors.orange, Colors.red, (speedRatio - 0.66) / 0.34)!;
    }
  }

  @override
  bool shouldRepaint(MapPainter oldDelegate) {
    return oldDelegate.telemetryData != telemetryData;
  }
}
