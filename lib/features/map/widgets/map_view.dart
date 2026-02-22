// lib/features/map/widgets/map_view.dart

import 'package:flutter/material.dart';
import 'package:mappls_gl/mappls_gl.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import '../../telemetry/providers/telemetry_provider.dart';

class MapView extends StatefulWidget {
  const MapView({Key? key}) : super(key: key);

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  MapplsMapController? _mapController;
  LatLng _currentPosition = const LatLng(22.7196, 75.8577); // Indore
  Line? _routeLine;
  final List<LatLng> _routePoints = [];

  @override
  void initState() {
    super.initState();
    _initializeLocation();
  }

  Future<void> _initializeLocation() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      setState(() {
        _currentPosition = LatLng(position.latitude, position.longitude);
      });

      // Move camera to current location
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(_currentPosition, 15.0),
      );

      // Start tracking
      _startLocationTracking();
    } catch (e) {
      debugPrint('Error initializing location: $e');
    }
  }

  void _startLocationTracking() {
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    );

    Geolocator.getPositionStream(locationSettings: locationSettings)
        .listen((Position position) {
      final newPosition = LatLng(position.latitude, position.longitude);
      
      setState(() {
        _currentPosition = newPosition;
        _routePoints.add(newPosition);
      });

      // Update telemetry
      context.read<TelemetryProvider>().updateLocation(position);

      // Update route line
      _updateRouteLine();

      // Follow user
      _mapController?.animateCamera(
        CameraUpdate.newLatLng(newPosition),
      );
    });
  }

  Future<void> _updateRouteLine() async {
    if (_mapController == null || _routePoints.length < 2) return;

    try {
      // Remove old line
      if (_routeLine != null) {
        await _mapController!.removeLine(_routeLine!);
      }

      // Add new line
      _routeLine = await _mapController!.addLine(
        LineOptions(
          geometry: _routePoints,
          lineColor: "#0000FF",
          lineWidth: 5.0,
        ),
      );
    } catch (e) {
      debugPrint('Error updating route line: $e');
    }
  }

  void _onMapCreated(MapplsMapController controller) {
    _mapController = controller;
    
    _mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(_currentPosition, 15.0),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MapplsMap(
      initialCameraPosition: CameraPosition(
        target: _currentPosition,
        zoom: 15.0,
      ),
      onMapCreated: _onMapCreated,
      myLocationEnabled: true,
      myLocationTrackingMode: MyLocationTrackingMode.TrackingGPS,
      myLocationRenderMode: MyLocationRenderMode.GPS,
      compassEnabled: true,
      tiltGesturesEnabled: true,
      rotateGesturesEnabled: true,
      scrollGesturesEnabled: true,
      zoomGesturesEnabled: true,
      styleString: MapplsStyles.STANDARD_DAY,
    );
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }
}