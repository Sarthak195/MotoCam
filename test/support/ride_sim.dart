// Synthetic sensor and GPS streams for TelemetryProvider incident tests.

import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:motocam/features/telemetry/providers/telemetry_provider.dart';

/// Drives a [TelemetryProvider] on one synthetic clock: linear acceleration
/// every 20 ms (the game rate), the raw accelerometer for the orientation
/// every 60 ms and, while [speedKmh] is set, one GPS fix per second.
class RideSim {
  /// Starts the clock at [start] (default now; keep it at or after the ride
  /// start so fixes are not dropped).
  RideSim(this.provider, {DateTime? start}) : t = start ?? DateTime.now();

  /// The provider under test.
  final TelemetryProvider provider;

  /// The current synthetic time.
  DateTime t;

  /// Raw accelerometer vector (m/s², gravity included) of the orientation
  /// stream. The default is a phone upright on the mount.
  List<double> gravity = const [0.0, 9.81, 0.0];

  /// GPS speed of each fix in km/h; `null` means no fix.
  double? speedKmh;

  /// How the phone sits in its mount, in degrees counterclockwise (seen
  /// from the screen) from upright portrait: 0 portrait, 90 landscapeLeft
  /// (right edge up), -90 landscapeRight. Every vector this sim feeds
  /// (linear acceleration and [gravity], both given as for a portrait
  /// mount) is turned into that device frame, so the same physical event
  /// can be replayed on a sideways phone. 0 feeds the vectors unchanged.
  double mountDegrees = 0;

  List<double> _toDevice(double x, double y, double z) {
    if (mountDegrees == 0) {
      return [x, y, z];
    }
    final radians = mountDegrees * math.pi / 180;
    final c = math.cos(radians);
    final s = math.sin(radians);
    return [x * c + y * s, -x * s + y * c, z];
  }

  static const Duration _step = Duration(milliseconds: 20);
  static const Duration _orientationStep = Duration(milliseconds: 60);
  static const Duration _fixStep = Duration(seconds: 1);

  DateTime? _nextOrientationAt;
  DateTime? _nextFixAt;

  /// The synthetic time elapsed since [since], in ms.
  int elapsedMsSince(DateTime since) => t.difference(since).inMilliseconds;

  void _tick(double x, double y, double z) {
    final linear = _toDevice(x, y, z);
    provider.updateAccelerometerForTesting(
      linear[0],
      linear[1],
      linear[2],
      timestamp: t,
    );
    final nextOrientationAt = _nextOrientationAt;
    if (nextOrientationAt == null || !t.isBefore(nextOrientationAt)) {
      final g = _toDevice(gravity[0], gravity[1], gravity[2]);
      provider.updateOrientationForTesting(g[0], g[1], g[2], timestamp: t);
      _nextOrientationAt = t.add(_orientationStep);
    }
    final speed = speedKmh;
    final nextFixAt = _nextFixAt;
    if (speed != null && (nextFixAt == null || !t.isBefore(nextFixAt))) {
      provider.updateLocationForTesting(
        Position(
          latitude: 37.7749,
          longitude: -122.4194,
          timestamp: t,
          accuracy: 3.0,
          altitude: 0.0,
          altitudeAccuracy: 0.0,
          heading: 90.0,
          headingAccuracy: 0.0,
          speed: speed / 3.6,
          // A reported speed accuracy makes the provider trust GPS speed.
          speedAccuracy: 0.5,
        ),
      );
      _nextFixAt = t.add(_fixStep);
    }
    t = t.add(_step);
  }

  /// No linear acceleration for [duration].
  void quiet(Duration duration) {
    final end = t.add(duration);
    while (t.isBefore(end)) {
      _tick(0.0, 0.0, 0.0);
    }
  }

  /// Handlebar vibration for [duration]: [g] along x and y with the sign
  /// flipping every sample (25 Hz), so every sample is far above any
  /// trigger but the motion goes nowhere.
  void vibrate(Duration duration, {double g = 8.0}) {
    final end = t.add(duration);
    var sign = 1.0;
    while (t.isBefore(end)) {
      _tick(sign * g * 9.81 * 0.8, sign * g * 9.81 * 0.6, 0.0);
      sign = -sign;
    }
  }

  /// A jolt of [g] along x lasting [length].
  void jolt({
    double g = 6.0,
    Duration length = const Duration(milliseconds: 160),
  }) {
    final end = t.add(length);
    while (t.isBefore(end)) {
      _tick(g * 9.81, 0.0, 0.0);
    }
  }
}

/// Records one confirmed automatic incident without GPS: a 6 g jolt and the
/// phone tipped onto its side for 4 s, at a 2 g trigger.
void recordTipOverIncident(TelemetryProvider provider) {
  provider.setIncidentDetectionConfig(
    triggerGForce: 2.0,
    debounce: const Duration(seconds: 5),
  );
  RideSim(provider)
    ..quiet(const Duration(seconds: 1))
    ..jolt()
    ..gravity = const [9.81, 0.0, 0.0]
    ..quiet(const Duration(seconds: 4));
}
