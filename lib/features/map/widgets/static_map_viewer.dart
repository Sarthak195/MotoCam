// lib/features/map/widgets/static_map_viewer.dart

import 'package:flutter/material.dart';
import '../../telemetry/models/telemetry_data.dart';

class StaticMapViewer extends StatelessWidget {
  final List<TelemetryData> telemetryData;
  final double width;
  final double height;

  const StaticMapViewer({
    super.key,
    required this.telemetryData,
    this.width = double.infinity,
    this.height = 300,
  });

  @override
  Widget build(BuildContext context) {
    if (telemetryData.isEmpty) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(
          child: Text(
            'No location data available',
            style: TextStyle(color: Colors.grey),
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
        painter: MapPainter(telemetryData),
        child: Stack(
          children: [
            // Start marker
            Positioned(
              left: 12,
              top: 12,
              child: Column(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: const BoxDecoration(
                      color: Colors.green,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Start',
                    style: TextStyle(
                      color: Colors.green,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
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
                      'Points: ${telemetryData.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                      ),
                    ),
                    if (telemetryData.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Start: ${telemetryData.first.latitude.toStringAsFixed(4)}, ${telemetryData.first.longitude.toStringAsFixed(4)}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 10,
                        ),
                      ),
                      Text(
                        'End: ${telemetryData.last.latitude.toStringAsFixed(4)}, ${telemetryData.last.longitude.toStringAsFixed(4)}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 10,
                        ),
                      ),
                    ],
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

class MapPainter extends CustomPainter {
  final List<TelemetryData> telemetryData;

  MapPainter(this.telemetryData);

  @override
  void paint(Canvas canvas, Size size) {
    if (telemetryData.isEmpty || telemetryData.length < 2) {
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

    // Draw route with speed-based coloring
    final speedPaint = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    Path routePath = Path();
    bool isFirst = true;

    double maxSpeed = telemetryData.isNotEmpty
        ? telemetryData.map((t) => t.speed).reduce((a, b) => a > b ? a : b)
        : 0;
    if (maxSpeed == 0) maxSpeed = 1; // Avoid division by zero

    for (int i = 0; i < telemetryData.length; i++) {
      final point = telemetryData[i];
      final x = (point.longitude - minLon) * scale;
      final y = size.height - ((point.latitude - minLat) * scale);

      // Use speed-based coloring for route segments
      if (i > 0) {
        final speedRatio = (point.speed / maxSpeed).clamp(0.0, 1.0);
        final color = _getColorForSpeed(speedRatio);
        speedPaint.color = color;

        final prevPoint = telemetryData[i - 1];
        final prevX = (prevPoint.longitude - minLon) * scale;
        final prevY = size.height - ((prevPoint.latitude - minLat) * scale);

        canvas.drawLine(Offset(prevX, prevY), Offset(x, y), speedPaint);
      }

      if (isFirst) {
        routePath.moveTo(x, y);
        isFirst = false;
      } else {
        routePath.lineTo(x, y);
      }
    }

    // Draw start marker
    if (!isFirst) {
      final startPoint = telemetryData.first;
      final startX = (startPoint.longitude - minLon) * scale;
      final startY = size.height - ((startPoint.latitude - minLat) * scale);

      final startMarkerPaint = Paint()
        ..color = Colors.green
        ..style = PaintingStyle.fill;

      canvas.drawCircle(Offset(startX, startY), 6, startMarkerPaint);
      final startBorderPaint = Paint()
        ..color = Colors.lightGreen
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(Offset(startX, startY), 6, startBorderPaint);

      // Draw end marker
      final endPoint = telemetryData.last;
      final endX = (endPoint.longitude - minLon) * scale;
      final endY = size.height - ((endPoint.latitude - minLat) * scale);

      final endMarkerPaint = Paint()
        ..color = Colors.red
        ..style = PaintingStyle.fill;

      canvas.drawCircle(Offset(endX, endY), 6, endMarkerPaint);
      final endBorderPaint = Paint()
        ..color = Colors.pink
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(Offset(endX, endY), 6, endBorderPaint);
    }
  }

  Color _getColorForSpeed(double speedRatio) {
    // Green (slow) -> Yellow (medium) -> Red (fast)
    if (speedRatio < 0.33) {
      // Green to Yellow
      return Color.lerp(Colors.green, Colors.yellow, speedRatio / 0.33)!;
    } else if (speedRatio < 0.66) {
      // Yellow to Orange
      return Color.lerp(Colors.yellow, Colors.orange, (speedRatio - 0.33) / 0.33)!;
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
