import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../map/map_source_config.dart';
import '../../map/widgets/static_map_viewer.dart';
import '../../telemetry/models/telemetry_data.dart';

class RouteMapView extends StatelessWidget {
  const RouteMapView({
    super.key,
    required this.telemetryData,
    this.currentSample,
    this.height = 180,
  });

  final List<TelemetryData> telemetryData;
  final TelemetryData? currentSample;
  final double height;

  @override
  Widget build(BuildContext context) {
    final routePoints = _downsample(_extractPoints(telemetryData));
    if (routePoints.length < 2) {
      return StaticMapViewer(
        telemetryData: telemetryData,
        width: double.infinity,
        height: height,
      );
    }

    final bounds = LatLngBounds.fromPoints(routePoints);
    final center = LatLng(
      (bounds.south + bounds.north) / 2,
      (bounds.west + bounds.east) / 2,
    );

    final currentPoint = _toLatLng(currentSample);

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            FlutterMap(
              options: MapOptions(
                initialCenter: center,
                initialZoom: _initialZoomForBounds(bounds),
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.pinchZoom |
                      InteractiveFlag.drag |
                      InteractiveFlag.doubleTapZoom |
                      InteractiveFlag.flingAnimation |
                      InteractiveFlag.scrollWheelZoom,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: MapSourceConfig.tileUrlTemplate,
                  userAgentPackageName: MapSourceConfig.userAgentPackageName,
                  maxNativeZoom: MapSourceConfig.maxNativeZoom,
                  maxZoom: MapSourceConfig.maxZoom,
                ),
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: routePoints,
                      strokeWidth: 4,
                      color: Colors.lightBlueAccent,
                    ),
                  ],
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: routePoints.first,
                      width: 26,
                      height: 26,
                      child: const _RouteMarker(
                        color: Colors.green,
                        icon: Icons.play_arrow,
                      ),
                    ),
                    Marker(
                      point: routePoints.last,
                      width: 26,
                      height: 26,
                      child: const _RouteMarker(
                        color: Colors.red,
                        icon: Icons.stop,
                      ),
                    ),
                    if (currentPoint != null)
                      Marker(
                        point: currentPoint,
                        width: 20,
                        height: 20,
                        child: const _CurrentMarker(),
                      ),
                  ],
                ),
              ],
            ),
            Positioned(
              left: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Points: ${routePoints.length}',
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                ),
              ),
            ),
            Positioned(
              right: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  MapSourceConfig.attribution,
                  style: TextStyle(color: Colors.white70, fontSize: 10),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static List<LatLng> _extractPoints(List<TelemetryData> samples) {
    final points = <LatLng>[];
    for (final sample in samples) {
      final point = _toLatLng(sample);
      if (point != null) {
        points.add(point);
      }
    }
    return points;
  }

  static LatLng? _toLatLng(TelemetryData? sample) {
    if (sample == null) {
      return null;
    }

    final lat = sample.latitude;
    final lon = sample.longitude;
    if (lat == 0 && lon == 0) {
      return null;
    }
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      return null;
    }
    return LatLng(lat, lon);
  }

  static List<LatLng> _downsample(List<LatLng> points) {
    const maxPoints = 1800;
    if (points.length <= maxPoints) {
      return points;
    }

    final sampled = <LatLng>[];
    final step = (points.length / maxPoints).ceil();
    for (var i = 0; i < points.length; i += step) {
      sampled.add(points[i]);
    }

    if (sampled.isEmpty || sampled.last != points.last) {
      sampled.add(points.last);
    }
    return sampled;
  }

  static double _initialZoomForBounds(LatLngBounds bounds) {
    final latSpan = (bounds.north - bounds.south).abs();
    final lonSpan = (bounds.east - bounds.west).abs();
    final span = latSpan > lonSpan ? latSpan : lonSpan;

    if (span <= 0.002) return 16;
    if (span <= 0.01) return 14;
    if (span <= 0.05) return 12;
    if (span <= 0.2) return 10;
    if (span <= 1.0) return 8;
    return 6;
  }
}

class _RouteMarker extends StatelessWidget {
  const _RouteMarker({required this.color, required this.icon});

  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      child: Icon(icon, size: 14, color: Colors.white),
    );
  }
}

class _CurrentMarker extends StatelessWidget {
  const _CurrentMarker();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.cyanAccent,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.black, width: 1.5),
      ),
    );
  }
}
