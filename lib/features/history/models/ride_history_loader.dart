import 'dart:io';

import '../../../core/utils/path_utils.dart' as path_utils;
import 'ride_record.dart';

/// Loads the ride history from the files found in the recordings directory.
///
/// Every `*.telemetry.json` file becomes a ride through
/// [RideRecord.fromTelemetryFile]; files that fail to load are skipped.
/// Video files that no loaded ride references (for example the segments of
/// a ride interrupted before STOP) are added as video-only rides through
/// [RideRecord.fromVideoFile]. Rides are returned newest first.
///
/// This does blocking-heavy work (JSON decoding, sample parsing, payload
/// hashing) and is meant to run off the UI isolate, e.g. in `Isolate.run`.
Future<List<RideRecord>> loadRideHistory(List<String> recordingPaths) async {
  final rides = <RideRecord>[];
  for (final path in recordingPaths) {
    if (!path.toLowerCase().endsWith('.telemetry.json')) {
      continue;
    }
    try {
      final ride = await RideRecord.fromTelemetryFile(File(path));
      if (ride != null) {
        rides.add(ride);
      }
    } catch (_) {
      // Skip malformed telemetry entries and continue loading others.
    }
  }

  final orphanVideoPaths = findOrphanVideoPaths(
    recordingPaths: recordingPaths,
    rides: rides,
  );
  for (final path in orphanVideoPaths) {
    try {
      rides.add(await RideRecord.fromVideoFile(File(path)));
    } catch (_) {
      // The file may have been deleted while the history was loading.
    }
  }

  rides.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return rides;
}

/// Returns the video files in [recordingPaths] that none of [rides]
/// references as a segment, main video or quarantined path, in input order.
List<String> findOrphanVideoPaths({
  required Iterable<String> recordingPaths,
  required Iterable<RideRecord> rides,
}) {
  final referenced = <String>{};
  for (final ride in rides) {
    for (final path in <String>[
      ride.videoPath,
      ...ride.segmentPaths,
      ...ride.quarantinedSegmentPaths,
    ]) {
      if (path.trim().isNotEmpty) {
        referenced.add(path_utils.normalizePath(path));
      }
    }
  }

  final orphans = <String>[];
  final seen = <String>{};
  for (final path in recordingPaths) {
    if (!RideRecord.isVideoFilePath(path)) {
      continue;
    }
    final normalized = path_utils.normalizePath(path);
    if (referenced.contains(normalized) || !seen.add(normalized)) {
      continue;
    }
    orphans.add(path);
  }
  return orphans;
}
