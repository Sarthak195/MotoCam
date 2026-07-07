/// Convenience wrapper around the [Geolocator] plugin for continuous GPS
/// tracking and speed calculation.
///
/// Call [startTracking] to begin receiving position updates and
/// [stopTracking] to cancel the subscription.  Always call [dispose] when
/// the service is no longer needed to release platform resources.
library;

import 'dart:async';

import 'package:geolocator/geolocator.dart';

/// Provides location access and speed calculation for the app.
///
/// This is a lower-level utility used by [TelemetryProvider] for ride
/// tracking.  It is **not** a singleton — the caller is responsible for
/// lifecycle management.
class LocationService {
  StreamSubscription<Position>? _positionSubscription;
  Position? _currentPosition;
  double _currentSpeed = 0.0;

  /// Requests the device's current position using high accuracy.
  ///
  /// Returns `null` when the location service is disabled or the user
  /// has denied location permission.
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
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
    );
    return _currentPosition;
  }

  /// Begins streaming position updates every 10 metres of movement.
  ///
  /// Returns the broadcast [Stream] of [Position] events.  Calling this
  /// method while tracking is already active is a no-op and returns the
  /// existing stream.
  Stream<Position> startTracking() {
    if (_positionSubscription != null) {
      return Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        ),
      );
    }

    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10, // Update every 10 meters
    );

    final stream = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    );

    _positionSubscription = stream.listen((position) {
      _currentPosition = position;
      _currentSpeed = position.speed * 3.6;
    });

    return stream;
  }

  /// Stops listening to position updates.
  void stopTracking() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
  }

  /// Converts [position]'s speed from m/s to km/h and caches the result.
  double getSpeedInKmh(Position position) {
    _currentSpeed = position.speed * 3.6;
    return _currentSpeed;
  }

  /// Last computed speed in km/h.
  double get currentSpeed => _currentSpeed;

  /// Last received position, or `null` if no fix has been obtained.
  Position? get currentPosition => _currentPosition;

  /// Releases all resources. Must be called when the service is no longer
  /// needed.
  void dispose() {
    stopTracking();
  }
}