// lib/features/map/widgets/map_view.dart

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import '../../../core/services/location_service.dart';

class MapView extends StatefulWidget {
  const MapView({Key? key}) : super(key: key);

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  GoogleMapController? _mapController;
  final LocationService _locationService = LocationService();
  
  LatLng _currentPosition = const LatLng(0, 0);
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};

  @override
  void initState() {
    super.initState();
    _initializeLocation();
  }

  Future<void> _initializeLocation() async {
    final position = await _locationService.getCurrentLocation();
    if (position != null) {
      setState(() {
        _currentPosition = LatLng(position.latitude, position.longitude);
        _markers.add(
          Marker(
            markerId: const MarkerId('current'),
            position: _currentPosition,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueBlue,
            ),
          ),
        );
      });

      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(_currentPosition, 15),
      );
    }

    // Start tracking
    _locationService.startTracking().listen((position) {
      setState(() {
        _currentPosition = LatLng(position.latitude, position.longitude);
        _updateMarker(_currentPosition);
      });

      _mapController?.animateCamera(
        CameraUpdate.newLatLng(_currentPosition),
      );
    });
  }

  void _updateMarker(LatLng position) {
    _markers.removeWhere((m) => m.markerId.value == 'current');
    _markers.add(
      Marker(
        markerId: const MarkerId('current'),
        position: position,
        icon: BitmapDescriptor.defaultMarkerWithHue(
          BitmapDescriptor.hueBlue,
        ),
        rotation: _locationService.currentPosition?.heading ?? 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GoogleMap(
      initialCameraPosition: CameraPosition(
        target: _currentPosition,
        zoom: 15,
      ),
      onMapCreated: (controller) {
        _mapController = controller;
      },
      markers: _markers,
      polylines: _polylines,
      myLocationEnabled: true,
      myLocationButtonEnabled: false,
      compassEnabled: true,
      mapType: MapType.normal,
      zoomControlsEnabled: false,
      trafficEnabled: true,
    );
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }
}