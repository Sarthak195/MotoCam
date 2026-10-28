// lib/features/camera/providers/recording_retention.dart
//
// Pure loop-retention and sidecar-maintenance rules used by [CameraProvider].
// Kept free of camera-plugin code so they can be unit-tested against plain
// lists and temporary directories.

import 'dart:convert';
import 'dart:io';

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

/// Lists the `*.telemetry.json` sidecars under [directoryPath] (recursively)
/// whose ride no longer has any video segment on disk.
///
/// A sidecar is an orphan when its `segmentPaths` is empty, or when none of
/// its segments exists either at the stored path or under the same file name
/// next to the sidecar. Sidecars that list any `lockedSegmentPaths`, and
/// sidecars that cannot be read or parsed, are never returned.
///
/// Uses synchronous I/O; run it off the UI isolate (for example with
/// `Isolate.run`).
List<String> findOrphanTelemetryFiles(String directoryPath) {
  final directory = Directory(directoryPath);
  if (!directory.existsSync()) {
    return const <String>[];
  }

  final orphans = <String>[];
  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
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

      final segmentPaths = _readPathList(json['segmentPaths']);
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

List<String> _readPathList(Object? value) {
  if (value is! List) {
    return const <String>[];
  }
  return value
      .map((entry) => entry.toString().trim())
      .where((path) => path.isNotEmpty)
      .toList();
}
