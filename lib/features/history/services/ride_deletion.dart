/// Deleting a ride's files and keeping the ride index and the signed-ride
/// registry consistent with what is left on disk.
///
/// Ride History's delete action and the storage budget both delete through
/// [deleteRideFiles], so a deleted ride never leaves a stale index entry or
/// a registered signed-ride id behind.
library;

import 'dart:io';

import '../../../core/services/ride_signing_service.dart';
import '../../../core/utils/path_utils.dart' as path_utils;
import '../models/ride_index.dart';
import '../models/ride_record.dart';

/// What [deleteRideFiles] did.
class RideDeletionResult {
  /// Creates a result.
  const RideDeletionResult({
    required this.deletedPaths,
    required this.failedPaths,
    required this.rideFileRemoved,
  });

  /// Files that existed and were deleted.
  final List<String> deletedPaths;

  /// Files that could not be deleted.
  final List<String> failedPaths;

  /// Whether the ride is gone as a ride: its telemetry JSON (or, for a
  /// video-only ride, its video) no longer exists.
  final bool rideFileRemoved;

  /// Number of files that could not be deleted.
  int get failed => failedPaths.length;
}

/// The directory that bounds what may be deleted for [ride]: the directory
/// of its telemetry JSON (the only trusted root of its segment paths), or
/// of its video for a video-only ride.
String rideDeletionRoot(RideRecord ride) {
  final anchor = ride.telemetryPath ?? ride.videoPath;
  return File(anchor).parent.path;
}

/// Files that make up [ride] on disk, in deletion order: its trusted
/// segment files and main video, then its ride JSON last (a stop half-way
/// then leaves an unlocked JSON whose videos are gone, which the orphan
/// prune removes). Quarantined paths and anything outside
/// [rideDeletionRoot] are never included.
List<String> filesOfRide(RideRecord ride) {
  final root = rideDeletionRoot(ride);
  final quarantined = <String>{
    for (final path in ride.quarantinedSegmentPaths)
      path_utils.normalizePath(path),
  };
  final seen = <String>{};
  final files = <String>[];
  final telemetryPath = ride.telemetryPath;
  for (final path in <String>[
    ...ride.segmentPaths,
    ride.videoPath,
    ?telemetryPath,
  ]) {
    if (path.trim().isEmpty) {
      continue;
    }
    final key = path_utils.normalizePath(path);
    if (quarantined.contains(key) ||
        !path_utils.isPathInsideDirectory(path, root) ||
        !seen.add(key)) {
      continue;
    }
    files.add(path);
  }
  // The JSON goes last whatever the segment list declares.
  if (telemetryPath != null) {
    final jsonKey = path_utils.normalizePath(telemetryPath);
    final index = files.indexWhere(
      (path) => path_utils.normalizePath(path) == jsonKey,
    );
    if (index >= 0 && index != files.length - 1) {
      files.add(files.removeAt(index));
    }
  }
  return files;
}

/// Deletes [ride]'s files ([filesOfRide]), then:
///
/// * when its telemetry JSON is gone, unregisters its `rideSessionId` from
///   [registry] with the JSON's own file name, so deleting a copy that
///   carries another ride's id leaves that ride registered;
/// * drops its entry from [indexStore] (the next history load decodes the
///   file again if it is still there) and the segment hashes no remaining
///   entry lists.
///
/// [indexStore] is the UI isolate's store (`RideIndexStore.shared()`), or
/// `null` when the index is unavailable. Never throws for a file that
/// cannot be deleted; it is reported in [RideDeletionResult.failedPaths].
Future<RideDeletionResult> deleteRideFiles(
  RideRecord ride, {
  required RideIndexStore? indexStore,
  SignedRideRegistry? registry,
}) async {
  final deleted = <String>[];
  final failed = <String>[];
  for (final path in filesOfRide(ride)) {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        deleted.add(path);
      }
    } catch (_) {
      failed.add(path);
    }
  }

  final telemetryPath = ride.telemetryPath;
  final anchor = telemetryPath ?? ride.videoPath;
  var removed = false;
  try {
    removed = !await File(anchor).exists();
  } catch (_) {
    removed = false;
  }

  final rideSessionId = ride.rideSessionId;
  if (telemetryPath != null && removed && rideSessionId != null) {
    // The ride is gone, so it no longer counts as written signed here.
    await (registry ?? SignedRideRegistry.instance).remove(
      rideSessionId,
      telemetryFileName: path_utils.fileNameFromPath(telemetryPath),
    );
  }

  if (telemetryPath != null && indexStore != null) {
    try {
      await indexStore.update((index) {
        index.rides.remove(rideIndexKey(telemetryPath));
        index.pruneSegmentHashes();
      });
    } catch (_) {
      // Only a cache: the next history load rebuilds it.
    }
  }

  return RideDeletionResult(
    deletedPaths: List<String>.unmodifiable(deleted),
    failedPaths: List<String>.unmodifiable(failed),
    rideFileRemoved: removed,
  );
}
