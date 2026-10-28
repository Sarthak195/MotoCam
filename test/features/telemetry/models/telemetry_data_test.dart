import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/features/telemetry/models/telemetry_data.dart';

void main() {
  group('TelemetryData', () {
    test('toJson writes UTC timestamps and fromJson returns local time', () {
      final local = DateTime(2026, 10, 20, 22, 54, 1);
      final sample = TelemetryData(
        latitude: 28.6,
        longitude: 77.2,
        speed: 42.0,
        bearing: 180.0,
        accelerationG: 0.1,
        elapsedMs: 1000,
        distanceKm: 1.5,
        timestamp: local,
        fixAgeMs: 250,
      );

      final json = sample.toJson();
      expect(json['timestamp'] as String, endsWith('Z'));
      expect(json['hasFix'], isTrue);
      expect(json['fixAgeMs'], 250);

      final decoded = TelemetryData.fromJson(json);
      expect(decoded.timestamp.isUtc, isFalse);
      expect(decoded.timestamp, local);
      expect(decoded.hasFix, isTrue);
      expect(decoded.fixAgeMs, 250);
    });

    test('fromJson reads legacy offset-less timestamps as local time', () {
      final decoded = TelemetryData.fromJson({
        'latitude': 1.0,
        'longitude': 2.0,
        'timestamp': '2026-10-20T22:54:01.000',
      });
      expect(decoded.timestamp, DateTime(2026, 10, 20, 22, 54, 1));
    });

    test('fromJson accepts numeric strings and defaults bad values', () {
      final decoded = TelemetryData.fromJson({
        'latitude': '28.5',
        'longitude': 77,
        'speed': '12.5',
        'bearing': 'north',
        'accelerationG': null,
        'elapsedMs': '1500',
      });
      expect(decoded.latitude, 28.5);
      expect(decoded.longitude, 77.0);
      expect(decoded.speed, 12.5);
      expect(decoded.bearing, 0.0);
      expect(decoded.accelerationG, 0.0);
      expect(decoded.elapsedMs, 1500);
      expect(decoded.distanceKm, 0.0);
    });

    test('fromJson infers no fix for legacy (0, 0) samples', () {
      expect(
        TelemetryData.fromJson({'latitude': 0.0, 'longitude': 0.0}).hasFix,
        isFalse,
      );
      expect(
        TelemetryData.fromJson({'latitude': 0.0, 'longitude': 0.5}).hasFix,
        isTrue,
      );
      expect(
        TelemetryData.fromJson({
          'latitude': 28.6,
          'longitude': 77.2,
          'hasFix': false,
        }).hasFix,
        isFalse,
      );
    });

    test('empty() has no fix and the constructor defaults to a fix', () {
      expect(TelemetryData.empty().hasFix, isFalse);
      expect(
        TelemetryData(
          latitude: 0,
          longitude: 0,
          speed: 0,
          bearing: 0,
          accelerationG: 0,
          elapsedMs: 0,
          distanceKm: 0,
          timestamp: DateTime(2026),
        ).hasFix,
        isTrue,
      );
    });
  });
}
