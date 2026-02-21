// lib/features/telemetry/models/telemetry_data.dart

class TelemetryData {
  final double latitude;
  final double longitude;
  final double speed; // km/h
  final double bearing; // degrees
  final double accelerationG;
  final DateTime timestamp;

  TelemetryData({
    required this.latitude,
    required this.longitude,
    required this.speed,
    required this.bearing,
    required this.accelerationG,
    required this.timestamp,
  });

  factory TelemetryData.empty() {
    return TelemetryData(
      latitude: 0.0,
      longitude: 0.0,
      speed: 0.0,
      bearing: 0.0,
      accelerationG: 0.0,
      timestamp: DateTime.now(),
    );
  }

  TelemetryData copyWith({
    double? latitude,
    double? longitude,
    double? speed,
    double? bearing,
    double? accelerationG,
    DateTime? timestamp,
  }) {
    return TelemetryData(
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      speed: speed ?? this.speed,
      bearing: bearing ?? this.bearing,
      accelerationG: accelerationG ?? this.accelerationG,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'speed': speed,
      'bearing': bearing,
      'accelerationG': accelerationG,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory TelemetryData.fromJson(Map<String, dynamic> json) {
    return TelemetryData(
      latitude: json['latitude'],
      longitude: json['longitude'],
      speed: json['speed'],
      bearing: json['bearing'],
      accelerationG: json['accelerationG'],
      timestamp: DateTime.parse(json['timestamp']),
    );
  }
}
