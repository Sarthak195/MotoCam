import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../map/map_source_config.dart';
import '../../map/route_points.dart';
import '../../map/widgets/osm_attribution.dart';
import '../../map/widgets/static_map_viewer.dart';
import '../../telemetry/models/telemetry_data.dart';

/// Online route map for ride playback.
///
/// Plots the GPS route of [telemetryData] over OpenStreetMap tiles (see
/// [MapSourceConfig]) with start, end and current-position markers. Building
/// this widget fetches tiles from the tile server, so callers should build it
/// only while the rider is looking at it. Rides with fewer than two GPS fixes
/// fall back to [StaticMapViewer], which needs no network.
///
/// The route, its bounds, the tile and polyline layers and the start and end
/// markers are computed once per [telemetryData] list. The current-position
/// marker follows [currentSampleListenable], which rebuilds only that marker
/// layer: a playback tick does not rebuild this widget.
class RouteMapView extends StatefulWidget {
  /// Creates a route map for [telemetryData].
  const RouteMapView({
    super.key,
    required this.telemetryData,
    this.currentSample,
    this.currentSampleListenable,
    this.height = 180,
  });

  /// Telemetry samples of the ride, in recording order.
  final List<TelemetryData> telemetryData;

  /// Sample at the current playback position, drawn as a cyan marker. Used
  /// when [currentSampleListenable] is `null`.
  final TelemetryData? currentSample;

  /// Source of the sample at the current playback position. Each change
  /// moves the cyan marker without rebuilding the map.
  final ValueListenable<TelemetryData?>? currentSampleListenable;

  /// Height of the map.
  final double height;

  @override
  State<RouteMapView> createState() => _RouteMapViewState();
}

class _RouteMapViewState extends State<RouteMapView> {
  List<LatLng> _routePoints = const <LatLng>[];
  int _gpsFixCount = 0;
  LatLngBounds? _bounds;
  PolylineLayer? _polylineLayer;
  MarkerLayer? _endpointLayer;
  TileLayer? _tileLayer;
  StaticMapViewer? _fallbackView;
  bool _tileLoadFailed = false;

  @override
  void initState() {
    super.initState();
    _computeRoute();
  }

  @override
  void didUpdateWidget(covariant RouteMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.telemetryData, widget.telemetryData)) {
      _computeRoute();
    }
  }

  void _computeRoute() {
    _fallbackView = null;
    final fixes = routePointsFromSamples(widget.telemetryData);
    _gpsFixCount = fixes.length;
    _routePoints = downsampleRoute(fixes);
    if (_routePoints.length < 2) {
      _bounds = null;
      _polylineLayer = null;
      _endpointLayer = null;
      return;
    }
    _bounds = LatLngBounds.fromPoints(_routePoints);
    _polylineLayer = PolylineLayer(
      polylines: [
        Polyline(
          points: _routePoints,
          strokeWidth: 4,
          color: Colors.lightBlueAccent,
        ),
      ],
    );
    _endpointLayer = MarkerLayer(
      markers: [
        Marker(
          point: _routePoints.first,
          width: 26,
          height: 26,
          child: const _RouteMarker(
            color: Colors.green,
            icon: Icons.play_arrow,
          ),
        ),
        Marker(
          point: _routePoints.last,
          width: 26,
          height: 26,
          child: const _RouteMarker(color: Colors.red, icon: Icons.stop),
        ),
      ],
    );
  }

  /// The layer with the current-position marker for [sample]; empty without
  /// a GPS position.
  Widget _currentLayer(TelemetryData? sample) {
    final point = latLngFromSample(sample);
    return MarkerLayer(
      markers: [
        if (point != null)
          Marker(
            point: point,
            width: 20,
            height: 20,
            child: const _CurrentMarker(),
          ),
      ],
    );
  }

  /// Returns the tile layer, creating it (and its single tile provider) on
  /// first use. The same instance is reused for every rebuild so flutter_map
  /// keeps one HTTP client; TileLayer's State disposes the provider when the
  /// map is removed.
  TileLayer _obtainTileLayer() {
    return _tileLayer ??= TileLayer(
      urlTemplate: MapSourceConfig.tileUrlTemplate,
      userAgentPackageName: MapSourceConfig.userAgentPackageName,
      maxNativeZoom: MapSourceConfig.maxNativeZoom,
      tileProvider: NetworkTileProvider(
        headers: <String, String>{'User-Agent': MapSourceConfig.userAgent},
        cachingProvider: BuiltInMapCachingProvider.getOrCreateInstance(
          maxCacheSize: MapSourceConfig.maxTileCacheBytes,
        ),
      ),
      errorTileCallback: _onTileLoadError,
    );
  }

  void _onTileLoadError(TileImage tile, Object error, StackTrace? stackTrace) {
    if (!mounted || _tileLoadFailed) {
      return;
    }
    setState(() {
      _tileLoadFailed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bounds = _bounds;
    final polylineLayer = _polylineLayer;
    final endpointLayer = _endpointLayer;
    if (bounds == null || polylineLayer == null || endpointLayer == null) {
      // The map subtree (if any) is being removed, and its TileLayer State
      // disposes the tile provider, so a later map must create a new one.
      _tileLayer = null;
      // Reusing the same widget instance lets Flutter skip rebuilding it (and
      // re-filtering every sample) on each playback tick.
      final cached = _fallbackView;
      if (cached != null && cached.height == widget.height) {
        return cached;
      }
      return _fallbackView = StaticMapViewer(
        telemetryData: widget.telemetryData,
        width: double.infinity,
        height: widget.height,
      );
    }

    final listenable = widget.currentSampleListenable;

    return Container(
      height: widget.height,
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
                initialCameraFit: CameraFit.bounds(
                  bounds: bounds,
                  padding: const EdgeInsets.all(20),
                  maxZoom: 16,
                ),
                maxZoom: MapSourceConfig.maxZoom,
                backgroundColor: Colors.grey.shade900,
                interactionOptions: const InteractionOptions(
                  flags:
                      InteractiveFlag.pinchZoom |
                      InteractiveFlag.drag |
                      InteractiveFlag.doubleTapZoom |
                      InteractiveFlag.flingAnimation |
                      InteractiveFlag.scrollWheelZoom,
                ),
              ),
              children: [
                _obtainTileLayer(),
                polylineLayer,
                endpointLayer,
                if (listenable == null)
                  _currentLayer(widget.currentSample)
                else
                  ValueListenableBuilder<TelemetryData?>(
                    valueListenable: listenable,
                    builder: (context, sample, _) => _currentLayer(sample),
                  ),
                const OsmAttribution(),
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
                  'GPS fixes: $_gpsFixCount',
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                ),
              ),
            ),
            if (_tileLoadFailed)
              Positioned(
                left: 8,
                bottom: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'Map tiles unavailable (offline?)',
                    style: TextStyle(color: Colors.white70, fontSize: 10),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
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
