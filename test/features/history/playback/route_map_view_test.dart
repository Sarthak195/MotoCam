import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/features/history/widgets/route_map_view.dart';
import 'package:motocam/features/telemetry/models/telemetry_data.dart';

TelemetryData _sample(int i) => TelemetryData(
  latitude: 28.6 + i * 0.001,
  longitude: 77.2 + i * 0.001,
  speed: 10,
  bearing: 0,
  accelerationG: 0,
  elapsedMs: i * 1000,
  distanceKm: 0,
  timestamp: DateTime.utc(2026, 1, 1).add(Duration(seconds: i)),
);

void main() {
  testWidgets(
    'the current marker follows the listenable without rebuilding the layers',
    (tester) async {
      final samples = [for (var i = 0; i < 20; i++) _sample(i)];
      final current = ValueNotifier<TelemetryData?>(samples[2]);
      addTearDown(current.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RouteMapView(
              telemetryData: samples,
              height: 120,
              currentSampleListenable: current,
            ),
          ),
        ),
      );
      await tester.pump();

      final tileLayer = tester.widget<TileLayer>(find.byType(TileLayer));
      final polylineLayer = tester.widget<PolylineLayer>(
        find.byType(PolylineLayer),
      );
      final endpointLayers = tester
          .widgetList<MarkerLayer>(find.byType(MarkerLayer))
          .toList();
      // Start and end markers, and the current-position marker.
      expect(endpointLayers, hasLength(2));
      expect(endpointLayers[0].markers, hasLength(2));
      expect(endpointLayers[1].markers.single.point.latitude, 28.602);
      final endpointLayer = endpointLayers[0];

      for (final index in [5, 9, 14]) {
        current.value = samples[index];
        await tester.pump();
      }

      expect(
        identical(tester.widget<TileLayer>(find.byType(TileLayer)), tileLayer),
        isTrue,
      );
      expect(
        identical(
          tester.widget<PolylineLayer>(find.byType(PolylineLayer)),
          polylineLayer,
        ),
        isTrue,
      );
      final after = tester
          .widgetList<MarkerLayer>(find.byType(MarkerLayer))
          .toList();
      expect(identical(after[0], endpointLayer), isTrue);
      expect(after[1].markers.single.point.latitude, 28.614);

      current.value = null;
      await tester.pump();
      expect(
        tester.widgetList<MarkerLayer>(find.byType(MarkerLayer)).last.markers,
        isEmpty,
      );
    },
  );
}
