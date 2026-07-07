import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:motocam/features/telemetry/providers/telemetry_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Position createMockPosition({
    required double latitude,
    required double longitude,
    required double speed, // in m/s
    required double accuracy,
    required double heading,
    required DateTime timestamp,
  }) {
    return Position(
      latitude: latitude,
      longitude: longitude,
      timestamp: timestamp,
      accuracy: accuracy,
      altitude: 0.0,
      heading: heading,
      speed: speed,
      speedAccuracy: 0.0,
      altitudeAccuracy: 0.0,
      headingAccuracy: 0.0,
    );
  }

  group('TelemetryProvider Tests', () {
    late TelemetryProvider provider;

    setUp(() {
      provider = TelemetryProvider(sampleInterval: const Duration(seconds: 1));
    });

    tearDown(() {
      provider.dispose();
    });

    test('initial state defaults are correct', () {
      expect(provider.isRideActive, isFalse);
      expect(provider.rideDistanceKm, 0.0);
      expect(provider.maxSpeedKmh, 0.0);
      expect(provider.averageSpeedKmh, 0.0);
      expect(provider.currentData.speed, 0.0);
      expect(provider.currentData.distanceKm, 0.0);
      expect(provider.activeRideSamples, isEmpty);
    });

    test('startRideSession sets active state and clears values', () {
      provider.startRideSession();
      expect(provider.isRideActive, isTrue);
      expect(provider.rideDistanceKm, 0.0);
      expect(provider.maxSpeedKmh, 0.0);
      expect(provider.activeRideSamples.length, 1); // captures the start sample
      expect(provider.activeRideSamples.first.distanceKm, 0.0);
    });

    test('ignores location updates timestamped before ride start', () {
      final now = DateTime.now();
      provider.startRideSession();
      
      // Let's create a position that is before the ride start time
      final stalePosition = createMockPosition(
        latitude: 37.7749,
        longitude: -122.4194,
        speed: 10.0, // 36 km/h
        accuracy: 5.0,
        heading: 90.0,
        timestamp: now.subtract(const Duration(minutes: 5)),
      );

      provider.updateLocationForTesting(stalePosition);
      expect(provider.rideDistanceKm, 0.0);
      expect(provider.currentData.latitude, 0.0); // should not be updated
    });

    test('updates location and calculates distance during active ride', () {
      final now = DateTime.now();
      provider.startRideSession();

      // First valid position update (initializes lastRidePosition, no distance added yet)
      final pos1 = createMockPosition(
        latitude: 37.7749,
        longitude: -122.4194,
        speed: 5.0, // 18 km/h
        accuracy: 3.0,
        heading: 90.0,
        timestamp: now.add(const Duration(seconds: 1)),
      );
      provider.updateLocationForTesting(pos1);
      expect(provider.rideDistanceKm, 0.0);
      expect(provider.currentData.latitude, 37.7749);
      expect(provider.currentData.longitude, -122.4194);

      // Second valid position update (100 meters away)
      // Moving from 37.7749, -122.4194 to 37.7749, -122.4183 is ~96.7 meters
      final pos2 = createMockPosition(
        latitude: 37.7749,
        longitude: -122.4183,
        speed: 10.0, // 36 km/h
        accuracy: 3.0,
        heading: 90.0,
        timestamp: now.add(const Duration(seconds: 3)),
      );
      provider.updateLocationForTesting(pos2);
      expect(provider.rideDistanceKm, greaterThan(0.0));
      expect(provider.rideDistanceKm, closeTo(0.096, 0.01));
    });

    test('stationary detection filters out very slow speed', () {
      final now = DateTime.now();
      provider.startRideSession();

      // Update location with extremely slow speed (less than 0.6 km/h)
      // 0.1 m/s = 0.36 km/h
      final slowPos = createMockPosition(
        latitude: 37.7749,
        longitude: -122.4194,
        speed: 0.1,
        accuracy: 2.0,
        heading: 0.0,
        timestamp: now.add(const Duration(seconds: 1)),
      );

      provider.updateLocationForTesting(slowPos);
      expect(provider.currentData.speed, 0.0); // Filtered to 0
    });

    test('incident detection requires two consecutive hits and registers crash', () {
      provider.startRideSession();
      provider.setIncidentDetectionConfig(
        triggerGForce: 2.0,
        debounce: const Duration(seconds: 5),
      );
      expect(provider.incidentCount, 0);

      // We send 1 high g-force event. It should increment consecutiveIncidentHits but not detect a crash yet.
      // Trigger threshold set to 2.0g. Send 30m/s^2 linear acceleration (~3.05g)
      provider.updateAccelerometerForTesting(30.0, 0.0, 0.0);
      expect(provider.incidentCount, 0);

      // Send a second consecutive high g-force event (32m/s^2 linear acceleration, ~3.26g)
      provider.updateAccelerometerForTesting(32.0, 0.0, 0.0);
      expect(provider.incidentCount, 1);
      expect(provider.lastIncidentDetectedAt, isNotNull);
      expect(provider.lastIncidentGForce, greaterThan(2.0));
    });

    test('non-consecutive high g-force event resets consecutive count', () {
      provider.startRideSession();
      provider.setIncidentDetectionConfig(
        triggerGForce: 2.0,
        debounce: const Duration(seconds: 5),
      );
      expect(provider.incidentCount, 0);

      // High g-force: 20 m/s^2 linear acceleration (~2.04g)
      provider.updateAccelerometerForTesting(20.0, 0.0, 0.0);
      // Smoothed becomes ~2.04g (>= 2.0g trigger). Consecutive hits = 1.
      expect(provider.incidentCount, 0);

      // Normal g-force (0.0): raw linear acceleration = 0.0g.
      provider.updateAccelerometerForTesting(0.0, 0.0, 0.0);
      // Smoothed decays to 2.04 * 0.70 + 0 = 1.43g (< 2.0g trigger).
      // Consecutive hits resets to 0.
      expect(provider.incidentCount, 0);

      // High g-force again (20 m/s^2):
      provider.updateAccelerometerForTesting(20.0, 0.0, 0.0);
      // Smoothed becomes 1.43 * 0.70 + 2.04 * 0.30 = 1.0 + 0.61 = 1.61g (< 2.0g trigger).
      // Consecutive hits remains 0.
      expect(provider.incidentCount, 0);
    });

    test('clearHistory resets all variables', () {
      final now = DateTime.now();
      provider.startRideSession();
      provider.setIncidentDetectionConfig(
        triggerGForce: 2.0,
        debounce: const Duration(seconds: 5),
      );

      final pos = createMockPosition(
        latitude: 37.7749,
        longitude: -122.4194,
        speed: 15.0,
        accuracy: 3.0,
        heading: 90.0,
        timestamp: now.add(const Duration(seconds: 1)),
      );
      provider.updateLocationForTesting(pos);

      // Add accelerometer event to trigger incident
      provider.updateAccelerometerForTesting(30.0, 0.0, 0.0);
      provider.updateAccelerometerForTesting(32.0, 0.0, 0.0);
      
      expect(provider.incidentCount, 1);

      provider.clearHistory();
      expect(provider.rideDistanceKm, 0.0);
      expect(provider.maxSpeedKmh, 0.0);
      expect(provider.averageSpeedKmh, 0.0);
      // Note: incidentCount is not reset by clearHistory() in the provider class, which is correct
      expect(provider.incidentCount, 1);
      expect(provider.currentData.latitude, 0.0); // Reset to empty
    });
  });
}
