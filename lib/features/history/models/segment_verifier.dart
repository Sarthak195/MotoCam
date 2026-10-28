/// Checks a ride's video segments against the hashes in its integrity
/// envelope, one segment at a time, and remembers each result in the ride
/// index so an unchanged segment is never hashed twice.
library;

import 'dart:isolate';

import '../../../core/utils/integrity_utils.dart' as integrity_utils;
import 'ride_index.dart';
import 'ride_record.dart';

/// Computes the SHA-256 of the file at a path, or `null` when it cannot be
/// read. Tests inject a fake one.
typedef SegmentHasher = Future<String?> Function(String path);

/// The default [SegmentHasher]: hashes one file per `Isolate.run` call, so
/// the UI isolate stays free (on the current isolate if that fails).
Future<String?> hashSegmentInBackground(String path) async {
  try {
    return await Isolate.run(() => integrity_utils.hashFileSha256(path));
  } catch (_) {
    return integrity_utils.hashFileSha256(path);
  }
}

/// Stops a [SegmentVerifier.verify] run between segments once [cancel] is
/// called; the segment being hashed at that moment still finishes and its
/// result is still stored.
class SegmentCheckToken {
  bool _cancelled = false;

  /// Whether [cancel] was called.
  bool get isCancelled => _cancelled;

  /// Asks the run to stop before its next segment.
  void cancel() {
    _cancelled = true;
  }
}

/// A segment to check and the hash its ride's envelope records for it.
class SegmentCheckTarget {
  /// Creates a target.
  const SegmentCheckTarget({required this.path, required this.expectedHash});

  /// Resolved segment path.
  final String path;

  /// SHA-256 recorded in the envelope.
  final String expectedHash;
}

/// Outcome of checking one segment.
enum SegmentCheckOutcome {
  /// The file's hash equals the recorded one.
  verified,

  /// The file's hash differs from the recorded one.
  mismatch,

  /// The file exists but could not be read.
  unreadable,

  /// The file no longer exists (not an integrity issue: missing footage).
  missing,
}

/// The result of checking one segment.
class SegmentCheckResult {
  /// Creates a result.
  const SegmentCheckResult({
    required this.path,
    required this.outcome,
    required this.fromCache,
  });

  /// Resolved segment path.
  final String path;

  /// What the check found.
  final SegmentCheckOutcome outcome;

  /// Whether the result came from the index instead of hashing the file.
  final bool fromCache;

  /// The integrity issue code for a failed check (the codes the full
  /// integrity check uses), or `null` when the segment passed or is
  /// missing.
  String? get issue => switch (outcome) {
    SegmentCheckOutcome.mismatch => 'segment-hash-mismatch:$path',
    SegmentCheckOutcome.unreadable => 'unreadable-segment-file:$path',
    SegmentCheckOutcome.verified || SegmentCheckOutcome.missing => null,
  };
}

/// Orders the segments of a ride for checking: [first] (the segment about
/// to play) when it is one of them, then the others in [timelineOrder],
/// then any remaining segment of [expectedHashes] in its own order. Only
/// segments with a recorded hash whose file is not in [missing] are kept.
List<SegmentCheckTarget> orderSegmentsForCheck({
  required List<String> timelineOrder,
  required Map<String, String> expectedHashes,
  Set<String> missing = const <String>{},
  String? first,
}) {
  final ordered = <SegmentCheckTarget>[];
  final seen = <String>{};
  void add(String path) {
    final expected = expectedHashes[path];
    if (expected == null || missing.contains(path) || !seen.add(path)) {
      return;
    }
    ordered.add(SegmentCheckTarget(path: path, expectedHash: expected));
  }

  if (first != null) {
    add(first);
  }
  timelineOrder.forEach(add);
  expectedHashes.keys.forEach(add);
  return ordered;
}

/// Checks segments one at a time with [hasher], reusing and storing results
/// in the ride index [store] (when there is one).
///
/// A stored result is reused only when the segment file still has the
/// same normalised path, size, modification time and change time, and the
/// envelope still records the same hash; otherwise the file is hashed
/// again. Results are never carried across paths.
class SegmentVerifier {
  /// Creates a verifier. [store] may be `null` (no index available); then
  /// every segment is hashed.
  SegmentVerifier({
    required this.store,
    SegmentHasher? hasher,
    RideFileStatSource? stat,
  }) : hasher = hasher ?? hashSegmentInBackground,
       stat = stat ?? statRideFile;

  /// The index that holds the results.
  final RideIndexStore? store;

  /// Hashes one segment file.
  final SegmentHasher hasher;

  /// Stamps a segment file.
  final RideFileStatSource stat;

  /// Checks one segment: from a still-valid stored result unless
  /// [ignoreCache], otherwise by hashing it and storing the result.
  Future<SegmentCheckResult> check(
    SegmentCheckTarget target, {
    bool ignoreCache = false,
  }) async {
    final hashed = await _hash(
      target.path,
      target.expectedHash,
      ignoreCache: ignoreCache,
    );
    final SegmentCheckOutcome outcome;
    final sha256 = hashed.sha256;
    if (sha256 != null) {
      outcome = sha256 == target.expectedHash
          ? SegmentCheckOutcome.verified
          : SegmentCheckOutcome.mismatch;
    } else if (hashed.existed && await stat(target.path) != null) {
      outcome = SegmentCheckOutcome.unreadable;
    } else {
      outcome = SegmentCheckOutcome.missing;
    }
    return SegmentCheckResult(
      path: target.path,
      outcome: outcome,
      fromCache: hashed.fromCache,
    );
  }

  /// The SHA-256 of the segment at [path]: from a still-valid stored result
  /// unless [ignoreCache], otherwise computed with [hasher] and stored.
  /// `null` when the file is gone ([existed] `false`) or unreadable.
  Future<({String? sha256, bool fromCache, bool existed})> _hash(
    String path,
    String expectedHash, {
    bool ignoreCache = false,
  }) async {
    final stamp = await stat(path);
    if (stamp == null) {
      return (sha256: null, fromCache: false, existed: false);
    }
    final store = this.store;
    if (!ignoreCache && store != null) {
      final cached = (await store.read()).validSegmentHash(
        path,
        stamp,
        expectedHash,
      );
      if (cached != null) {
        return (sha256: cached.sha256, fromCache: true, existed: true);
      }
    }
    final actual = await hasher(path);
    if (actual != null && store != null) {
      final entry = SegmentHashEntry(
        stamp: stamp,
        expectedHash: expectedHash,
        sha256: actual,
      );
      await store.update(
        (index) => index.segmentHashes[rideIndexKey(path)] = entry,
      );
    }
    return (sha256: actual, fromCache: false, existed: true);
  }

  /// Checks [targets] in order, one segment at a time, calling [onResult]
  /// after each, and returns the results. Stops before the next segment
  /// once [token] is cancelled.
  Future<List<SegmentCheckResult>> verify(
    List<SegmentCheckTarget> targets, {
    SegmentCheckToken? token,
    bool ignoreCache = false,
    void Function(SegmentCheckResult result)? onResult,
  }) async {
    final results = <SegmentCheckResult>[];
    for (final target in targets) {
      if (token?.isCancelled ?? false) {
        break;
      }
      final result = await check(target, ignoreCache: ignoreCache);
      results.add(result);
      onResult?.call(result);
    }
    return results;
  }

  /// A hasher for [RideRecord.setLockState]: the file's hash from a
  /// still-valid stored result, or computed (off the UI isolate by default)
  /// and stored. [onChecked] runs after each segment.
  Future<String?> Function(String path, String expectedHash) lockHasher({
    void Function()? onChecked,
  }) {
    return (path, expectedHash) async {
      try {
        return (await _hash(path, expectedHash)).sha256;
      } finally {
        onChecked?.call();
      }
    };
  }
}

/// What the ride index knows about a ride's video segments: how many have
/// a recorded hash and exist ([total]), how many have a still-valid stored
/// result ([checked]) and how many of those failed ([failed]).
class RideVideoCheck {
  /// Creates a summary.
  const RideVideoCheck({
    required this.total,
    required this.checked,
    required this.failed,
  });

  /// Nothing to check (no recorded hash, or a ride whose data check did
  /// not pass).
  static const RideVideoCheck none = RideVideoCheck(
    total: 0,
    checked: 0,
    failed: 0,
  );

  /// Existing segments with a recorded hash.
  final int total;

  /// Segments with a still-valid stored result.
  final int checked;

  /// Checked segments whose hash differs from the recorded one.
  final int failed;

  /// Whether every segment was checked and none failed.
  bool get isVerified => total > 0 && checked == total && failed == 0;
}

/// Builds the [RideVideoCheck] of [ride] from the segment hashes in
/// [index], stamping each segment with [stat]; nothing is hashed. Only a
/// ride whose data check passed ([RideIntegrityStatus.verified]) gets a
/// non-empty result.
Future<RideVideoCheck> videoCheckFromIndex({
  required RideRecord ride,
  required RideIndex index,
  required Future<RideFileStamp?> Function(String path) stat,
}) async {
  if (ride.telemetryPath == null ||
      ride.integrity.status != RideIntegrityStatus.verified) {
    return RideVideoCheck.none;
  }
  var total = 0;
  var checked = 0;
  var failed = 0;
  for (final entry in ride.expectedSegmentHashes.entries) {
    if (ride.missingSegmentPaths.contains(entry.key)) {
      continue;
    }
    final stamp = await stat(entry.key);
    if (stamp == null) {
      continue;
    }
    total++;
    final cached = index.validSegmentHash(entry.key, stamp, entry.value);
    if (cached == null) {
      continue;
    }
    checked++;
    if (!cached.matches) {
      failed++;
    }
  }
  return RideVideoCheck(total: total, checked: checked, failed: failed);
}

/// The Ride History line for [check], or `null` when there is nothing to
/// say (no recorded hashes, or the ride data check did not pass).
String? describeVideoCheck(RideVideoCheck check) {
  if (check.total == 0) {
    return null;
  }
  if (check.failed > 0) {
    return 'Videos: ${check.failed} of ${check.total} segment(s) failed the '
        'check';
  }
  if (check.checked == check.total) {
    return 'Videos verified: unmodified since recording';
  }
  if (check.checked == 0) {
    return 'Videos not checked yet (open the ride to check)';
  }
  return 'Videos: ${check.checked} of ${check.total} segments checked, no '
      'failure so far (open the ride to finish)';
}
