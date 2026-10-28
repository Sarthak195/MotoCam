import 'dart:io';

import '../../../core/utils/path_utils.dart' as path_utils;
import 'ride_index.dart';
import 'ride_record.dart';
import 'segment_verifier.dart';

/// What [loadRideHistoryIndexed] found.
class RideHistoryLoad {
  /// Creates a load result.
  const RideHistoryLoad({
    required this.rides,
    required this.rideEntries,
    required this.videoChecks,
    required this.readIndex,
    required this.decodedPaths,
  });

  /// Sample-less rides, newest first.
  final List<RideRecord> rides;

  /// Fresh index entries for every telemetry file that loaded, keyed by
  /// [rideIndexKey]. Files that are gone or failed to load are absent, so
  /// storing this map drops their old entries.
  final Map<String, RideIndexEntry> rideEntries;

  /// Video check state of each telemetry ride, keyed by [rideIndexKey] of
  /// its telemetry path, from the segment hashes in the index (nothing is
  /// hashed while loading).
  final Map<String, RideVideoCheck> videoChecks;

  /// The index as read from disk at the start of the load (empty when there
  /// was none), so the UI isolate's store need not read it again.
  final RideIndex readIndex;

  /// Telemetry files that were decoded because the index had no valid
  /// entry for them.
  final List<String> decodedPaths;
}

/// Loads the ride history from the files found in the recordings directory.
///
/// Every `*.telemetry.json` file becomes a sample-less ride
/// ([RideRecord.samplesLoaded] `false`). The index at [indexFilePath] is
/// read first (or [index] is used when given): a ride whose entry matches
/// the telemetry file's path, size, modification time and change time, and
/// whose segments still exist as recorded, is taken from it without reading
/// the file; any other file is decoded and gets a fresh entry. Files that
/// fail to load are skipped. Video files that no loaded ride references (for
/// example the segments of a ride interrupted before STOP) are added as
/// video-only rides through [RideRecord.fromVideoFile]. Rides are returned
/// newest first.
///
/// The index is only read here. The caller stores [RideHistoryLoad.rideEntries]
/// through the UI isolate's [RideIndexStore].
///
/// This does blocking-heavy work (JSON decoding, payload hashing) and is
/// meant to run off the UI isolate, e.g. in `Isolate.run`. [stat] is
/// injectable for tests.
Future<RideHistoryLoad> loadRideHistoryIndexed(
  List<String> recordingPaths, {
  String? indexFilePath,
  RideIndex? index,
  RideFileStatSource stat = statRideFile,
}) async {
  final readIndex =
      index ??
      (indexFilePath == null
          ? RideIndex()
          : await RideIndex.readFile(indexFilePath));
  final rides = <RideRecord>[];
  final rideEntries = <String, RideIndexEntry>{};
  final videoChecks = <String, RideVideoCheck>{};
  final decodedPaths = <String>[];
  final segmentStamps = <String, RideFileStamp?>{};

  Future<RideFileStamp?> segmentStamp(String path) async {
    final key = rideIndexKey(path);
    if (segmentStamps.containsKey(key)) {
      return segmentStamps[key];
    }
    return segmentStamps[key] = await stat(path);
  }

  for (final path in recordingPaths) {
    if (!path.toLowerCase().endsWith('.telemetry.json')) {
      continue;
    }
    try {
      final key = rideIndexKey(path);
      final stamp = await stat(path);
      if (stamp == null) {
        continue;
      }

      RideRecord? ride;
      final cached = readIndex.rides[key];
      if (cached != null &&
          cached.path == path &&
          cached.stamp == stamp &&
          await _segmentsExistAsRecorded(cached.ride, segmentStamp)) {
        ride = cached.ride;
      } else {
        decodedPaths.add(path);
        ride = await RideRecord.fromTelemetryFile(
          File(path),
          loadSamples: false,
        );
      }
      if (ride == null) {
        continue;
      }
      rides.add(ride);
      rideEntries[key] = RideIndexEntry(path: path, stamp: stamp, ride: ride);
      videoChecks[key] = await videoCheckFromIndex(
        ride: ride,
        index: readIndex,
        stat: segmentStamp,
      );
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
      rides.add(await RideRecord.fromVideoFile(File(path), loadSamples: false));
    } catch (_) {
      // The file may have been deleted while the history was loading.
    }
  }

  rides.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return RideHistoryLoad(
    rides: rides,
    rideEntries: rideEntries,
    videoChecks: videoChecks,
    readIndex: readIndex,
    decodedPaths: decodedPaths,
  );
}

/// Loads the ride history without an index (every ride file is decoded);
/// see [loadRideHistoryIndexed].
Future<List<RideRecord>> loadRideHistory(List<String> recordingPaths) async =>
    (await loadRideHistoryIndexed(recordingPaths)).rides;

/// Whether every segment of a cached [ride] exists exactly when the entry
/// says it does. Resolution, the missing list and the integrity report all
/// depend on which segment files exist, so any change means a re-decode.
Future<bool> _segmentsExistAsRecorded(
  RideRecord ride,
  Future<RideFileStamp?> Function(String path) stat,
) async {
  final missing = ride.missingSegmentPaths.toSet();
  for (final path in ride.segmentPaths) {
    final exists = await stat(path) != null;
    if (exists == missing.contains(path)) {
      return false;
    }
  }
  return true;
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
