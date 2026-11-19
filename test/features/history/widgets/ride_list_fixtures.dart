// A ride for the Ride History list tests, with only the fields the list
// reads.

import 'package:motocam/features/history/models/ride_record.dart';

/// A ride of [clips] segments under /r/, [minutes] long.
RideRecord listRide({
  DateTime? createdAt,
  String? telemetryPath = '/r/ride_x.telemetry.json',
  bool complete = true,
  int clips = 3,
  int locked = 0,
  int missing = 0,
  int quarantined = 0,
  int? incidents,
  int? bytes = 1700000000,
  int minutes = 41,
  RideIntegrityReport integrity = const RideIntegrityReport.unknown(),
  bool mock = false,
}) {
  final segments = <String>[for (var i = 0; i < clips; i++) '/r/s$i.mp4'];
  return RideRecord(
    videoPath: segments.isEmpty ? '/r/v.mp4' : segments.last,
    segmentPaths: segments,
    lockedSegmentPaths: segments.take(locked).toList(),
    missingSegmentPaths: segments.skip(clips - missing).toList(),
    createdAt: createdAt ?? DateTime(2026, 11, 13, 13, 21),
    telemetryPath: telemetryPath,
    rideSessionId: 'x',
    isSessionComplete: complete,
    distanceKm: 0,
    maxSpeedKmh: 0,
    averageSpeedKmh: 0,
    segmentTimeline: const <RideSegmentTimelineEntry>[],
    samples: const [],
    samplesLoaded: false,
    sampleCount: minutes == 0 ? 0 : 10,
    lastSampleElapsedMs: minutes * 60000,
    integrity: integrity,
    quarantinedSegmentPaths: <String>[
      for (var i = 0; i < quarantined; i++) '/q/$i.mp4',
    ],
    totalSegmentBytes: bytes,
    incidents: incidents == null
        ? null
        : <RideIncident>[
            for (var i = 0; i < incidents; i++)
              RideIncident(elapsedMs: 1000 * i),
          ],
    mockLocationDetected: mock,
  );
}
