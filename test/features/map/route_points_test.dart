import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:motocam/features/map/route_points.dart';
import 'package:motocam/features/map/widgets/static_map_viewer.dart';
import 'package:motocam/features/telemetry/models/telemetry_data.dart';

TelemetryData _sample(double lat, double lon, {int elapsedMs = 0}) {
  return TelemetryData(
    latitude: lat,
    longitude: lon,
    speed: 20,
    bearing: 0,
    accelerationG: 0,
    elapsedMs: elapsedMs,
    distanceKm: 0,
    timestamp: DateTime.utc(2026, 1, 1),
  );
}

void main() {
  group('route points', () {
    test('latLngFromSample rejects (0, 0) and out-of-range coordinates', () {
      expect(latLngFromSample(null), isNull);
      expect(latLngFromSample(_sample(0, 0)), isNull);
      expect(latLngFromSample(_sample(91, 10)), isNull);
      expect(latLngFromSample(_sample(10, -181)), isNull);
      expect(latLngFromSample(_sample(28.6, 77.2)), const LatLng(28.6, 77.2));
      expect(
        latLngFromSample(_sample(28.6, 77.2).copyWith(hasFix: false)),
        isNull,
      );
    });

    test('routePointsFromSamples keeps only GPS fixes in order', () {
      final points = routePointsFromSamples(<TelemetryData>[
        _sample(0, 0),
        _sample(1, 2),
        _sample(3, 4),
      ]);
      expect(points, const <LatLng>[LatLng(1, 2), LatLng(3, 4)]);
    });

    test('downsampleRoute keeps short routes and the last point', () {
      final short = <LatLng>[for (var i = 0; i < 10; i++) LatLng(i * 0.1, 0)];
      expect(downsampleRoute(short), same(short));

      final long = <LatLng>[
        for (var i = 0; i < 5000; i++) LatLng(0, i * 0.001),
      ];
      final sampled = downsampleRoute(long, maxPoints: 1800);
      expect(sampled.length, lessThanOrEqualTo(1801));
      expect(sampled.first, long.first);
      expect(sampled.last, long.last);
    });
  });

  group('StaticMapViewer', () {
    Future<void> pumpViewer(WidgetTester tester, List<TelemetryData> data) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StaticMapViewer(telemetryData: data, height: 120),
          ),
        ),
      );
    }

    testWidgets('says there was no GPS fix instead of printing (0, 0)', (
      tester,
    ) async {
      await pumpViewer(tester, <TelemetryData>[_sample(0, 0), _sample(0, 0)]);
      expect(find.text('No GPS fix recorded for this ride'), findsOneWidget);
      expect(find.textContaining('0.0000'), findsNothing);
      expect(find.text('Start'), findsNothing);
    });

    testWidgets('reports GPS fixes, not raw samples', (tester) async {
      await pumpViewer(tester, <TelemetryData>[
        _sample(0, 0),
        _sample(28.6, 77.2),
      ]);
      expect(find.text('GPS fixes: 1'), findsOneWidget);
      expect(find.text('Start: 28.6000, 77.2000'), findsOneWidget);
    });

    testWidgets('keeps the empty-data message', (tester) async {
      await pumpViewer(tester, const <TelemetryData>[]);
      expect(find.text('No location data available'), findsOneWidget);
    });
  });
}
