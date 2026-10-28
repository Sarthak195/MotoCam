// lib/features/camera/providers/recording_retention.dart
//
// Pure loop-retention and sidecar-maintenance rules used by [CameraProvider].
// Kept free of camera-plugin code so they can be unit-tested against plain
// lists and temporary directories.

import 'dart:convert';
import 'dart:io';

import '../../../core/ride_file/ride_telemetry_codec.dart' as ride_codec;
import '../../../core/utils/path_utils.dart' as path_utils;

/// Returns the session segments the rolling loop should delete, oldest first.
///
/// Only unlocked segments count against [maxUnlockedSegments] (clamped to at
/// least 1), and only unlocked segments are ever selected, so locked incident
/// footage never consumes the loop budget and is never deleted. Because at
/// least one unlocked segment is always kept, the newest registered segment
/// is never selected.
///
/// A segment counts as locked when its path is in [lockedPaths] or when a
/// locked path has the same file name: recordings live in one directory, and
/// stored absolute paths can go stale (for example after an iOS container
/// move) while the file itself is still there.
List<String> selectSegmentsToEvict({
  required List<String> sessionPaths,
  required Set<String> lockedPaths,
  required int maxUnlockedSegments,
}) {
  final limit = maxUnlockedSegments < 1 ? 1 : maxUnlockedSegments;
  final lockedNames = lockedPaths.map(path_utils.fileNameFromPath).toSet();
  final unlocked = sessionPaths
      .where(
        (path) =>
            !lockedPaths.contains(path) &&
            !lockedNames.contains(path_utils.fileNameFromPath(path)),
      )
      .toList();
  if (unlocked.length <= limit) {
    return const <String>[];
  }
  return unlocked.sublist(0, unlocked.length - limit);
}

/// Returns the session segments the loop will delete once the segment that
/// is being recorded now is registered (see [selectSegmentsToEvict]).
///
/// [nextSegmentLocked] says whether an incident already asked to lock that
/// segment. Used to count space the loop is about to free.
List<String> segmentsEvictedByNextRegistration({
  required List<String> sessionPaths,
  required Set<String> lockedPaths,
  required bool nextSegmentLocked,
  required int maxUnlockedSegments,
}) {
  const nextSegment = '<next segment>';
  return selectSegmentsToEvict(
    sessionPaths: [...sessionPaths, nextSegment],
    lockedPaths: nextSegmentLocked
        ? {...lockedPaths, nextSegment}
        : lockedPaths,
    maxUnlockedSegments: maxUnlockedSegments,
  ).where((path) => path != nextSegment).toList();
}

/// Returns the segment sequence numbers that are not yet registered: every
/// sequence after [lastSettledSequence] up to and including [activeSequence].
///
/// During a segment roll this covers both the stopped segment that is still
/// being persisted and the segment currently being recorded.
Set<int> unsettledSegmentSequences({
  required int lastSettledSequence,
  required int activeSequence,
}) {
  final result = <int>{};
  for (
    var sequence = lastSettledSequence + 1;
    sequence <= activeSequence;
    sequence++
  ) {
    result.add(sequence);
  }
  return result;
}

/// Whether the LOCKED badge is shown: a recording is active and the segment
/// being recorded ([activeSequence]) is among the [pendingLockSequences], so
/// it will be locked when it is registered.
///
/// The badge ends when that segment rolls (the next segment has a different
/// sequence) or the recording stops.
bool isActiveSegmentLocked({
  required bool isRecording,
  required int activeSequence,
  required Set<int> pendingLockSequences,
}) {
  return isRecording && pendingLockSequences.contains(activeSequence);
}

/// Lists the `*.telemetry.json` sidecars directly inside [directoryPath]
/// (subdirectories are not scanned) whose ride no longer has any video
/// segment on disk.
///
/// The segments are the ones the reader starts from: `segmentPaths` under
/// the codec's segment-list rule, or `[videoPath]` when that list is empty
/// (schema 1 files), or, when both are empty, a video named after a legacy
/// `<video base>.telemetry.json` file. A sidecar is an orphan when that
/// list is empty, or when none of its segments exists either at the stored
/// path or under the same file name next to the sidecar. Sidecars that list
/// any `lockedSegmentPaths`, and sidecars that cannot be read or parsed, are
/// never returned.
///
/// Uses synchronous I/O; run it off the UI isolate (for example with
/// `Isolate.run`).
List<String> findOrphanTelemetryFiles(String directoryPath) {
  final directory = Directory(directoryPath);
  if (!directory.existsSync()) {
    return const <String>[];
  }

  final orphans = <String>[];
  for (final entity in directory.listSync(followLinks: false)) {
    if (entity is! File ||
        !entity.path.toLowerCase().endsWith('.telemetry.json')) {
      continue;
    }

    try {
      final json = jsonDecode(entity.readAsStringSync());
      if (json is! Map<String, dynamic>) {
        continue;
      }

      final lockedPaths = _readPathList(json['lockedSegmentPaths']);
      if (lockedPaths.isNotEmpty) {
        continue;
      }

      final segmentPaths = _declaredSegmentPaths(entity.path, json);
      if (segmentPaths.isEmpty) {
        orphans.add(entity.path);
        continue;
      }

      final sidecarDirectory = entity.parent.path;
      final hasAnyExistingSegment = segmentPaths.any((segmentPath) {
        if (File(segmentPath).existsSync()) {
          return true;
        }
        final sibling =
            '$sidecarDirectory${Platform.pathSeparator}'
            '${path_utils.fileNameFromPath(segmentPath)}';
        return File(sibling).existsSync();
      });
      if (!hasAnyExistingSegment) {
        orphans.add(entity.path);
      }
    } catch (_) {
      // Skip malformed telemetry to avoid accidental data loss.
    }
  }
  return orphans;
}

List<String> _readPathList(Object? value) =>
    ride_codec.normalizeSegmentPathList(value is List ? value : const []);

/// The reader's starting segment list for a sidecar (see
/// `resolveRideSegments` in the ride-file codec), before path resolution.
List<String> _declaredSegmentPaths(
  String telemetryPath,
  Map<String, dynamic> json,
) {
  final segmentPaths = _readPathList(json['segmentPaths']);
  if (segmentPaths.isNotEmpty) {
    return segmentPaths;
  }
  final videoPath = json['videoPath']?.toString().trim() ?? '';
  if (videoPath.isNotEmpty) {
    return <String>[videoPath];
  }
  // Legacy `<video base>.telemetry.json`: the reader recovers that video.
  final suffix = ride_codec.rideTelemetryFileSuffix;
  if (!telemetryPath.toLowerCase().endsWith(suffix)) {
    return const <String>[];
  }
  final basePath = telemetryPath.substring(
    0,
    telemetryPath.length - suffix.length,
  );
  return <String>[
    for (final extension in ride_codec.rideVideoFileExtensions)
      '$basePath$extension',
  ];
}
