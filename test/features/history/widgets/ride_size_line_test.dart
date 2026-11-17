import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/features/history/models/ride_record.dart';
import 'package:motocam/features/history/widgets/ride_size_line.dart';

RideRecord _ride({int? bytes}) => RideRecord(
  videoPath: '/r/REC1.mp4',
  segmentPaths: const <String>['/r/REC1.mp4'],
  lockedSegmentPaths: const <String>[],
  createdAt: DateTime.utc(2026, 5, 3),
  telemetryPath: null,
  rideSessionId: null,
  isSessionComplete: true,
  distanceKm: 0,
  maxSpeedKmh: 0,
  averageSpeedKmh: 0,
  segmentTimeline: const [],
  samples: const [],
  integrity: const RideIntegrityReport.unknown(),
  quarantinedSegmentPaths: const <String>[],
  totalSegmentBytes: bytes,
);

Future<void> _pump(WidgetTester tester, RideRecord ride) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: RideSizeLine(ride: ride)),
  ),
);

void main() {
  testWidgets('shows the size of the ride clips', (tester) async {
    await _pump(tester, _ride(bytes: 1080000000));
    expect(find.text('Size: 1.08 GB'), findsOneWidget);
  });

  testWidgets('shows nothing when the size is unknown or zero', (tester) async {
    await _pump(tester, _ride());
    expect(find.textContaining('Size'), findsNothing);
    await _pump(tester, _ride(bytes: 0));
    expect(find.textContaining('Size'), findsNothing);
  });

  test('withTotalSegmentBytes changes only the size', () {
    final ride = _ride().withTotalSegmentBytes(42);
    expect(ride.totalSegmentBytes, 42);
    expect(ride.segmentPaths, const <String>['/r/REC1.mp4']);
    expect(ride.integrity.status, RideIntegrityStatus.unknown);
  });
}
