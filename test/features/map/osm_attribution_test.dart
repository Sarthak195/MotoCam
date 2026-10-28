import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:motocam/features/map/map_source_config.dart';
import 'package:motocam/features/map/widgets/osm_attribution.dart';

Widget _map({required Future<bool> Function(Uri uri) openLink}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 360,
        height: 200,
        child: FlutterMap(
          options: const MapOptions(
            initialCenter: LatLng(28.6, 77.2),
            initialZoom: 10,
          ),
          children: [OsmAttribution(openLink: openLink)],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('shows the attribution and opens the copyright page on tap', (
    tester,
  ) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      _map(
        openLink: (uri) async {
          opened.add(uri);
          return true;
        },
      ),
    );

    // The text sits in a popup that the info button opens.
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();

    final line = find.text('© ${MapSourceConfig.attributionText}');
    expect(line, findsOneWidget);

    await tester.tap(line);
    await tester.pump();

    expect(opened, [Uri.parse('https://www.openstreetmap.org/copyright')]);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('tells the rider when the browser cannot be opened', (
    tester,
  ) async {
    await tester.pumpWidget(_map(openLink: (uri) async => false));

    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('© ${MapSourceConfig.attributionText}'));
    await tester.pump();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('openstreetmap.org/copyright'), findsOneWidget);
  });
}
