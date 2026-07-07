/// A single telemetry sample captured during a ride.
///
/// Each sample records the device's GPS position, speed, heading, linear
/// acceleration (with gravity removed), and the elapsed time since ride
/// start.  Samples are serialised to JSON and persisted alongside video
/// segments when a ride session ends.
class TelemetryData {
  /// GPS latitude in decimal degrees (WGS 84).
  final double latitude;

  /// GPS longitude in decimal degrees (WGS 84).
  final double longitude;

  /// Filtered ground speed in **km/h**.
  final double speed;

  /// GPS bearing / heading in degrees (0–360).
  final double bearing;

  /// Smoothed linear acceleration magnitude in **g** (gravity removed).
  final double accelerationG;

  /// Milliseconds elapsed since the ride session started.
  final int elapsedMs;

  /// Cumulative ride distance in **km** at the time of this sample.
  final double distanceKm;

  /// Wall-clock time when this sample was captured.
  final DateTime timestamp;

  TelemetryData({
    required this.latitude,
    required this.longitude,
    required this.speed,
    required this.bearing,
    required this.accelerationG,
    required this.elapsedMs,
    required this.distanceKm,
    required this.timestamp,
  });

  /// Creates a zero-value sample anchored to the current time.
  factory TelemetryData.empty() {
    return TelemetryData(
      latitude: 0.0,
      longitude: 0.0,
      speed: 0.0,
      bearing: 0.0,
      accelerationG: 0.0,
      elapsedMs: 0,
      distanceKm: 0.0,
      timestamp: DateTime.now(),
    );
  }

  /// Returns a copy of this sample with the specified fields replaced.
  TelemetryData copyWith({
    double? latitude,
    double? longitude,
    double? speed,
    double? bearing,
    double? accelerationG,
    int? elapsedMs,
    double? distanceKm,
    DateTime? timestamp,
  }) {
    return TelemetryData(
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      speed: speed ?? this.speed,
      bearing: bearing ?? this.bearing,
      accelerationG: accelerationG ?? this.accelerationG,
      elapsedMs: elapsedMs ?? this.elapsedMs,
      distanceKm: distanceKm ?? this.distanceKm,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  /// Serialises this sample to a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'speed': speed,
      'bearing': bearing,
      'accelerationG': accelerationG,
      'elapsedMs': elapsedMs,
      'distanceKm': distanceKm,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  /// Deserialises a sample from a JSON-compatible map.
  ///
  /// Falls back to sensible defaults (`0.0`, `DateTime.now()`) when fields
  /// are missing or malformed.
  factory TelemetryData.fromJson(Map<String, dynamic> json) {
    return TelemetryData(
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
      speed: (json['speed'] as num?)?.toDouble() ?? 0.0,
      bearing: (json['bearing'] as num?)?.toDouble() ?? 0.0,
      accelerationG: (json['accelerationG'] as num?)?.toDouble() ?? 0.0,
      elapsedMs: (json['elapsedMs'] as num?)?.toInt() ?? 0,
      distanceKm: (json['distanceKm'] as num?)?.toDouble() ?? 0.0,
      timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}
