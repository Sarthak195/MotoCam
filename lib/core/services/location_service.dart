// lib/core/services/location_service.dart

import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';

class LocationService {
  Stream<Position>? _positionStream;
  Position? _currentPosition;
  double _currentSpeed = 0.0;

  // Get current location
  Future<Position?> getCurrentLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return null;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return null;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return null;
    }

    _currentPosition = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    return _currentPosition;
  }

  // Start tracking location
  Stream<Position> startTracking() {
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10, // Update every 10 meters
    );

    _positionStream = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    );

    return _positionStream!;
  }

  // Calculate speed from position
  double getSpeedInKmh(Position position) {
    // position.speed is in m/s, convert to km/h
    _currentSpeed = position.speed * 3.6;
    return _currentSpeed;
  }

  double get currentSpeed => _currentSpeed;
  Position? get currentPosition => _currentPosition;
}