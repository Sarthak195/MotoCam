// lib/features/telemetry/providers/telemetry_provider.dart

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../models/telemetry_data.dart';

class TelemetryProvider extends ChangeNotifier {
  TelemetryData _currentData = TelemetryData.empty();
  List<TelemetryData> _telemetryHistory = [];

  TelemetryData get currentData => _currentData;
  List<TelemetryData> get telemetryHistory => _telemetryHistory;

  // Update from location
  void updateLocation(Position position) {
    _currentData = _currentData.copyWith(
      latitude: position.latitude,
      longitude: position.longitude,
      speed: position.speed * 3.6, // m/s to km/h
      bearing: position.heading,
      timestamp: DateTime.now(),
    );
    
    _telemetryHistory.add(_currentData);
    notifyListeners();
  }

  // Listen to accelerometer for crash detection
  void startAccelerometerTracking() {
    accelerometerEvents.listen((AccelerometerEvent event) {
      // Calculate G-force magnitude
      double gForce = (event.x * event.x + 
                       event.y * event.y + 
                       event.z * event.z).abs() / 9.81;

      _currentData = _currentData.copyWith(
        accelerationG: gForce,
      );

      // Detect potential crash (>3G sudden deceleration)
      if (gForce > 3.0) {
        _detectCrash(gForce);
      }

      notifyListeners();
    });
  }

  void _detectCrash(double gForce) {
    debugPrint('⚠️ CRASH DETECTED! G-Force: $gForce');
    // Trigger emergency recording save
    // Mark event in database
    // Possibly send alert
  }

  void clearHistory() {
    _telemetryHistory.clear();
    notifyListeners();
  }
}