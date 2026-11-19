/// A single telemetry sample captured during a ride.
///
/// Each sample records the device's GPS position, speed, heading, linear
/// acceleration (with gravity removed), and the elapsed time since ride
/// start.  Samples are serialised to JSON and persisted alongside video
/// segments when a ride session ends.
class TelemetryData {
  /// GPS latitude in decimal degrees (WGS 84).
  ///
  /// Only meaningful when [hasFix] is `true`; before the first fix it is `0.0`.
  final double latitude;

  /// GPS longitude in decimal degrees (WGS 84).
  ///
  /// Only meaningful when [hasFix] is `true`; before the first fix it is `0.0`.
  final double longitude;

  /// Filtered ground speed in **km/h**.
  ///
  /// When [hasFix] is `false` this is the last value computed from a fix and
  /// may be stale.
  final double speed;

  /// GPS course over ground in degrees (0–360).
  ///
  /// The provider keeps the previous course when the platform reports none,
  /// but files written by older versions or by other tools
  /// may contain negative values, which mean "unavailable".
  final double bearing;

  /// Smoothed linear acceleration magnitude in **g** (gravity removed).
  final double accelerationG;

  /// Milliseconds elapsed since the ride session started.
  final int elapsedMs;

  /// Cumulative ride distance in **km** at the time of this sample.
  final double distanceKm;

  /// Wall-clock time when this sample was captured.
  ///
  /// Serialised as UTC ISO-8601; [TelemetryData.fromJson] returns local time.
  /// A sample read from JSON parses its timestamp on first access, because
  /// playback rarely reads it and parsing it for every sample of a long ride
  /// is expensive.
  DateTime get timestamp =>
      _timestamp ??= _parseTimestamp(_rawTimestamp) ?? DateTime.now();

  /// The parsed timestamp, or `null` until a sample read from JSON is first
  /// asked for it.
  DateTime? _timestamp;

  /// The `timestamp` string of a sample read from JSON, parsed lazily.
  final String? _rawTimestamp;

  /// Whether a recent GPS fix backed this sample.
  ///
  /// `false` before the first fix and when the last fix is too old, in which
  /// case [latitude], [longitude] and [speed] must not be treated as real
  /// measurements.
  final bool hasFix;

  /// Age of the GPS fix behind this sample in milliseconds, or `null` when
  /// unknown (no fix yet, or a file written before this field existed).
  final int? fixAgeMs;

  /// Creates a sample. [hasFix] defaults to `true` so existing callers that
  /// build samples from real fixes keep their meaning.
  TelemetryData({
    required this.latitude,
    required this.longitude,
    required this.speed,
    required this.bearing,
    required this.accelerationG,
    required this.elapsedMs,
    required this.distanceKm,
    required DateTime timestamp,
    this.hasFix = true,
    this.fixAgeMs,
  }) : _timestamp = timestamp,
       _rawTimestamp = null;

  TelemetryData._fromJsonFields({
    required this.latitude,
    required this.longitude,
    required this.speed,
    required this.bearing,
    required this.accelerationG,
    required this.elapsedMs,
    required this.distanceKm,
    required String rawTimestamp,
    required this.hasFix,
    required this.fixAgeMs,
  }) : _timestamp = null,
       _rawTimestamp = rawTimestamp;

  /// Creates a zero-value sample anchored to the current time, with no fix.
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
      hasFix: false,
    );
  }

  /// Returns a copy of this sample with the specified fields replaced.
  ///
  /// [fixAgeMs] cannot be reset to `null` through this method.
  TelemetryData copyWith({
    double? latitude,
    double? longitude,
    double? speed,
    double? bearing,
    double? accelerationG,
    int? elapsedMs,
    double? distanceKm,
    DateTime? timestamp,
    bool? hasFix,
    int? fixAgeMs,
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
      hasFix: hasFix ?? this.hasFix,
      fixAgeMs: fixAgeMs ?? this.fixAgeMs,
    );
  }

  /// Serialises this sample to a JSON-compatible map.
  ///
  /// The timestamp is written in UTC (with a trailing `Z`).
  Map<String, dynamic> toJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'speed': speed,
      'bearing': bearing,
      'accelerationG': accelerationG,
      'elapsedMs': elapsedMs,
      'distanceKm': distanceKm,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'hasFix': hasFix,
      if (fixAgeMs != null) 'fixAgeMs': fixAgeMs,
    };
  }

  /// Deserialises a sample from a JSON-compatible map.
  ///
  /// Missing, `null` or unparseable numeric fields (numbers and numeric
  /// strings are accepted) fall back to `0`, and a missing or invalid
  /// timestamp falls back to `DateTime.now()` (evaluated when [timestamp]
  /// is first read). Timestamps are returned in local time and parsed on
  /// first access. When `hasFix` is absent (files written before it
  /// existed), a sample at exactly (0, 0) is treated as having no fix.
  factory TelemetryData.fromJson(Map<String, dynamic> json) {
    final latitude = _readDouble(json['latitude']);
    final longitude = _readDouble(json['longitude']);
    final rawHasFix = json['hasFix'];
    final fixAge = _readNullableDouble(json['fixAgeMs']);
    return TelemetryData._fromJsonFields(
      latitude: latitude,
      longitude: longitude,
      speed: _readDouble(json['speed']),
      bearing: _readDouble(json['bearing']),
      accelerationG: _readDouble(json['accelerationG']),
      elapsedMs: _readDouble(json['elapsedMs']).toInt(),
      distanceKm: _readDouble(json['distanceKm']),
      rawTimestamp: json['timestamp']?.toString() ?? '',
      hasFix: rawHasFix is bool
          ? rawHasFix
          : !(latitude == 0.0 && longitude == 0.0),
      fixAgeMs: fixAge?.toInt(),
    );
  }

  static DateTime? _parseTimestamp(String? raw) =>
      raw == null ? null : DateTime.tryParse(raw)?.toLocal();

  static double _readDouble(Object? value) => _readNullableDouble(value) ?? 0.0;

  static double? _readNullableDouble(Object? value) {
    final parsed = value is num
        ? value.toDouble()
        : (value is String ? double.tryParse(value.trim()) : null);
    if (parsed == null || !parsed.isFinite) {
      return null;
    }
    return parsed;
  }
}
