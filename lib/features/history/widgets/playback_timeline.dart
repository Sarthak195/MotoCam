// Pure timeline logic for multi-segment ride playback.
//
// Everything here is free of widgets and plugins so it can be unit-tested
// without a device. RidePlaybackScreen owns the video controllers and calls
// these functions to build the playlist, the seekbar ranges and the markers.

import 'dart:math' as math;

import '../../../core/ride_file/ride_telemetry_codec.dart' as ride_codec;
import '../../telemetry/models/telemetry_data.dart';
import '../models/ride_record.dart';

/// Shortest duration, in milliseconds, given to a timeline entry.
const int minPlaybackSegmentMs = 1000;

/// Shortest uncovered span, in milliseconds, reported by [uncoveredRanges].
const int minNoVideoGapMs = 2000;

/// Acceleration, in g, at or above which a sample becomes an incident marker.
const double incidentMarkerThresholdG = 3.2;

/// Minimum spacing, in milliseconds, between two incident markers.
const int incidentMarkerDebounceMs = 5000;

/// Issue-code prefixes (from [RideRecord.verifySegmentIntegrity]) that mean a
/// segment could not be confirmed unmodified since recording: its hash
/// differs, no hash was recorded for it, or it could not be read for hashing.
const List<String> failedSegmentIssuePrefixes = <String>[
  'segment-hash-mismatch:',
  'missing-segment-hash:',
  'unreadable-segment-file:',
];

/// A span of the ride timeline, in milliseconds from ride start.
class PlaybackRange {
  /// Creates a range from [startMs] (inclusive) to [endMs] (exclusive).
  const PlaybackRange({required this.startMs, required this.endMs});

  /// Start of the range in milliseconds from ride start.
  final int startMs;

  /// End of the range in milliseconds from ride start.
  final int endMs;

  /// Length of the range in milliseconds.
  int get lengthMs => endMs - startMs;

  @override
  bool operator ==(Object other) =>
      other is PlaybackRange &&
      other.startMs == startMs &&
      other.endMs == endMs;

  @override
  int get hashCode => Object.hash(startMs, endMs);

  @override
  String toString() => 'PlaybackRange($startMs-$endMs)';
}

/// Kind of event shown as a marker on the seekbar.
enum PlaybackMarkerType {
  /// A telemetry acceleration spike.
  incident,

  /// The start of a locked segment.
  locked,
}

/// An event marker on the seekbar.
class PlaybackMarker {
  /// Creates a marker at [elapsedMs] of the given [type].
  const PlaybackMarker({required this.elapsedMs, required this.type});

  /// Position of the marker in milliseconds from ride start.
  final int elapsedMs;

  /// What the marker stands for.
  final PlaybackMarkerType type;
}

/// What the seekbar and the legend mark on the ride timeline: footage that
/// is missing, failed the integrity check or does not exist, and the
/// incident and lock markers. All positions are in milliseconds from ride
/// start.
class PlaybackTimelineMarks {
  /// Creates the marks; every list defaults to empty.
  const PlaybackTimelineMarks({
    this.missingRanges = const <PlaybackRange>[],
    this.failedCheckRanges = const <PlaybackRange>[],
    this.noVideoRanges = const <PlaybackRange>[],
    this.incidentMarkerMs = const <int>[],
    this.lockMarkerMs = const <int>[],
  });

  /// Segments that are missing or could not be played.
  final List<PlaybackRange> missingRanges;

  /// Segments that could not be confirmed unmodified since recording.
  final List<PlaybackRange> failedCheckRanges;

  /// Ride time without any video.
  final List<PlaybackRange> noVideoRanges;

  /// Incident marker times.
  final List<int> incidentMarkerMs;

  /// Locked-segment marker times.
  final List<int> lockMarkerMs;

  /// Whether nothing at all is marked.
  bool get isEmpty =>
      missingRanges.isEmpty &&
      failedCheckRanges.isEmpty &&
      noVideoRanges.isEmpty &&
      incidentMarkerMs.isEmpty &&
      lockMarkerMs.isEmpty;
}

/// Where a global timeline position lands inside the playlist.
class SegmentSeekTarget {
  /// Creates a seek target.
  const SegmentSeekTarget({
    required this.segmentIndex,
    required this.localPosition,
  });

  /// Index of the playlist segment to play.
  final int segmentIndex;

  /// Position inside that segment.
  final Duration localPosition;
}

/// Returns the declared segment paths of a ride in order, trimmed and without
/// duplicates, followed by [videoPath] when it is not already listed: the
/// ride-file codec's segment-list rule (`normalizeSegmentPathList`).
List<String> orderedDeclaredSegmentPaths({
  required List<String> segmentPaths,
  required String videoPath,
}) => ride_codec.normalizeSegmentPathList(segmentPaths, videoPath: videoPath);

/// Builds a gap-free, non-overlapping, start-ordered timeline for
/// [declaredPaths].
///
/// Entries of [storedTimeline] are kept (first entry per path wins, the
/// codec's span rule `normalizeTimelineSpan` applies, every entry lasts at
/// least 1 ms, overlaps are pushed later). A stored entry shorter than
/// [minPlaybackSegmentMs] (for example one saved without an end) takes its
/// length from [probedDurationsByPath] when that has one. Declared paths
/// without a stored entry are appended after the last stored entry, lasting at
/// least [minPlaybackSegmentMs], using their duration from
/// [probedDurationsByPath] or, when unknown, the median known segment
/// duration.
List<RideSegmentTimelineEntry> buildEffectiveTimeline({
  required List<String> declaredPaths,
  required List<RideSegmentTimelineEntry> storedTimeline,
  required Map<String, Duration> probedDurationsByPath,
}) {
  final merged = <RideSegmentTimelineEntry>[];
  final seenPaths = <String>{};

  for (final entry in storedTimeline) {
    final path = entry.path.trim();
    if (path.isEmpty || !seenPaths.add(path)) {
      continue;
    }
    final span = ride_codec.normalizeTimelineSpan(entry.startMs, entry.endMs);
    final startMs = span.startMs;
    var endMs = math.max(span.endMs, startMs + 1);
    final probedMs = probedDurationsByPath[path]?.inMilliseconds ?? 0;
    if (endMs - startMs < minPlaybackSegmentMs && probedMs > 0) {
      endMs = startMs + probedMs;
    }
    merged.add(
      RideSegmentTimelineEntry(path: path, startMs: startMs, endMs: endMs),
    );
  }

  final fallbackDurationMs = _medianDurationMs(<int>[
    for (final entry in merged) entry.endMs - entry.startMs,
    for (final duration in probedDurationsByPath.values)
      duration.inMilliseconds,
  ]);

  var appendCursorMs = 0;
  for (final entry in merged) {
    appendCursorMs = math.max<int>(appendCursorMs, entry.endMs);
  }

  for (final path in declaredPaths) {
    if (seenPaths.contains(path)) {
      continue;
    }
    final durationMs =
        probedDurationsByPath[path]?.inMilliseconds ?? fallbackDurationMs;
    final endMs =
        appendCursorMs + math.max<int>(durationMs, minPlaybackSegmentMs);
    merged.add(
      RideSegmentTimelineEntry(
        path: path,
        startMs: appendCursorMs,
        endMs: endMs,
      ),
    );
    appendCursorMs = endMs;
  }

  merged.sort((a, b) => a.startMs.compareTo(b.startMs));
  final normalized = <RideSegmentTimelineEntry>[];
  var cursorMs = 0;
  for (final entry in merged) {
    final startMs = math.max(entry.startMs, cursorMs);
    final endMs = math.max(entry.endMs, startMs + 1);
    normalized.add(
      RideSegmentTimelineEntry(
        path: entry.path,
        startMs: startMs,
        endMs: endMs,
      ),
    );
    cursorMs = endMs;
  }
  return normalized;
}

int _medianDurationMs(List<int> durationsMs) {
  final positive = durationsMs.where((ms) => ms > 0).toList()..sort();
  if (positive.isEmpty) {
    return minPlaybackSegmentMs;
  }
  return positive[positive.length ~/ 2];
}

/// Sorts [ranges] and merges overlapping or touching ones; empty ranges are
/// dropped.
List<PlaybackRange> mergeRanges(Iterable<PlaybackRange> ranges) {
  final sorted = ranges.where((range) => range.endMs > range.startMs).toList()
    ..sort((a, b) => a.startMs.compareTo(b.startMs));
  if (sorted.isEmpty) {
    return const <PlaybackRange>[];
  }

  final merged = <PlaybackRange>[];
  var current = sorted.first;
  for (final next in sorted.skip(1)) {
    if (next.startMs <= current.endMs) {
      current = PlaybackRange(
        startMs: current.startMs,
        endMs: math.max(current.endMs, next.endMs),
      );
    } else {
      merged.add(current);
      current = next;
    }
  }
  merged.add(current);
  return List<PlaybackRange>.unmodifiable(merged);
}

/// Returns the merged timeline spans of the [timeline] entries whose path is
/// in [paths].
List<PlaybackRange> rangesForPaths({
  required List<RideSegmentTimelineEntry> timeline,
  required Set<String> paths,
}) {
  if (paths.isEmpty) {
    return const <PlaybackRange>[];
  }
  return mergeRanges(<PlaybackRange>[
    for (final entry in timeline)
      if (paths.contains(entry.path))
        PlaybackRange(startMs: entry.startMs, endMs: entry.endMs),
  ]);
}

/// Returns the spans of `[0, totalMs)` that no [timeline] entry covers and that
/// last at least [minGapMs].
///
/// These are stretches of the ride with no video at all, for example footage
/// that loop recording overwrote at the start of a long ride.
List<PlaybackRange> uncoveredRanges({
  required List<RideSegmentTimelineEntry> timeline,
  required int totalMs,
  int minGapMs = minNoVideoGapMs,
}) {
  if (totalMs <= 0) {
    return const <PlaybackRange>[];
  }
  final covered = mergeRanges(<PlaybackRange>[
    for (final entry in timeline)
      PlaybackRange(startMs: entry.startMs, endMs: entry.endMs),
  ]);

  final gaps = <PlaybackRange>[];
  var cursorMs = 0;
  for (final range in covered) {
    if (range.startMs - cursorMs >= minGapMs) {
      gaps.add(PlaybackRange(startMs: cursorMs, endMs: range.startMs));
    }
    cursorMs = math.max(cursorMs, range.endMs);
  }
  if (totalMs - cursorMs >= minGapMs) {
    gaps.add(PlaybackRange(startMs: cursorMs, endMs: totalMs));
  }
  return List<PlaybackRange>.unmodifiable(gaps);
}

/// Returns the index of the playlist segment that plays [position] and the
/// position inside it.
///
/// A position before a segment's offset (inside a gap) snaps forward to that
/// segment's start; a position past the end lands in the last segment.
SegmentSeekTarget locateSegment({
  required List<Duration> offsets,
  required List<Duration> durations,
  required Duration position,
}) {
  final count = math.min(offsets.length, durations.length);
  for (var index = 0; index < count; index++) {
    final start = offsets[index];
    final end = start + durations[index];
    if (position <= start) {
      return SegmentSeekTarget(
        segmentIndex: index,
        localPosition: Duration.zero,
      );
    }
    if (position < end || index == count - 1) {
      return SegmentSeekTarget(
        segmentIndex: index,
        localPosition: position - start,
      );
    }
  }
  return const SegmentSeekTarget(segmentIndex: 0, localPosition: Duration.zero);
}

/// Returns the sorted start offsets of the playlist segments whose path is in
/// [lockedPaths], clamped to `[0, totalMs]`.
List<int> lockMarkerOffsetsMs({
  required List<String> playlistPaths,
  required List<Duration> playlistOffsets,
  required Iterable<String> lockedPaths,
  required int totalMs,
}) {
  final locked = lockedPaths.toSet();
  if (totalMs <= 0 || locked.isEmpty) {
    return const <int>[];
  }
  final markers = <int>{};
  final count = math.min(playlistPaths.length, playlistOffsets.length);
  for (var index = 0; index < count; index++) {
    if (locked.contains(playlistPaths[index])) {
      markers.add(playlistOffsets[index].inMilliseconds.clamp(0, totalMs));
    }
  }
  return List<int>.unmodifiable(markers.toList()..sort());
}

/// Returns the elapsed times of acceleration spikes in [samples]: samples at
/// or above [incidentMarkerThresholdG], at least [incidentMarkerDebounceMs]
/// apart, clamped to `[0, totalMs]`.
List<int> incidentMarkerOffsetsMs({
  required List<TelemetryData> samples,
  required int totalMs,
}) {
  if (samples.isEmpty || totalMs <= 0) {
    return const <int>[];
  }
  var lastAcceptedMs = -incidentMarkerDebounceMs;
  final markers = <int>[];
  for (final sample in samples) {
    if (sample.accelerationG < incidentMarkerThresholdG) {
      continue;
    }
    if (sample.elapsedMs - lastAcceptedMs < incidentMarkerDebounceMs) {
      continue;
    }
    final markerMs = sample.elapsedMs.clamp(0, totalMs);
    markers.add(markerMs);
    lastAcceptedMs = markerMs;
  }
  return List<int>.unmodifiable(markers);
}

/// Marker offsets for incidents saved with the ride (the ride JSON's
/// `incidents` list): each [elapsedMs] clamped to `[0, totalMs]`, sorted,
/// with duplicates removed.
List<int> recordedIncidentOffsetsMs({
  required List<int> elapsedMs,
  required int totalMs,
}) {
  if (elapsedMs.isEmpty || totalMs <= 0) {
    return const <int>[];
  }
  final offsets = elapsedMs.map((ms) => ms.clamp(0, totalMs)).toSet().toList()
    ..sort();
  return List<int>.unmodifiable(offsets);
}

/// Returns the marker closest to [valueMs] when it lies within [toleranceMs],
/// otherwise `null`.
PlaybackMarker? nearestMarker({
  required List<PlaybackMarker> markers,
  required int valueMs,
  required double toleranceMs,
}) {
  PlaybackMarker? nearest;
  var nearestDistance = double.infinity;
  for (final marker in markers) {
    final distance = (marker.elapsedMs - valueMs).abs().toDouble();
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearest = marker;
    }
  }
  if (nearest == null || nearestDistance > toleranceMs) {
    return null;
  }
  return nearest;
}

/// Width, in milliseconds, of the window the speed graph shows around the
/// playhead: the ride length clamped to 10-60 s.
int speedGraphWindowMs(int totalMs) =>
    math.max(10000, math.min(totalMs, 60000));

/// Maps a tap at [dx] on a speed graph of [width] to a ride position: the
/// graph's centre is [currentPosition] and its width spans
/// [speedGraphWindowMs].
Duration speedGraphTapTarget({
  required double dx,
  required double width,
  required Duration currentPosition,
  required Duration totalDuration,
}) {
  return speedGraphDragTarget(
    startDx: width / 2,
    dx: dx,
    width: width,
    anchorPosition: currentPosition,
    totalDuration: totalDuration,
  );
}

/// Maps a drag on the speed graph to a ride position.
///
/// [anchorPosition] and [startDx] are captured when the drag starts, so the
/// result depends only on how far the finger has moved since then: moving
/// right always goes forward and moving left always goes back.
Duration speedGraphDragTarget({
  required double startDx,
  required double dx,
  required double width,
  required Duration anchorPosition,
  required Duration totalDuration,
}) {
  if (width <= 0 || totalDuration <= Duration.zero) {
    return anchorPosition;
  }
  final windowMs = speedGraphWindowMs(totalDuration.inMilliseconds);
  final deltaMs = ((dx - startDx) / width) * windowMs;
  final target = anchorPosition + Duration(milliseconds: deltaMs.round());
  if (target < Duration.zero) {
    return Duration.zero;
  }
  return target > totalDuration ? totalDuration : target;
}

/// Returns the index of the first sample whose elapsed time is at or after
/// [elapsedMs], or `samples.length` when there is none. [samples] must be
/// ordered by elapsed time, as recorded.
int firstSampleIndexAtOrAfter(List<TelemetryData> samples, int elapsedMs) {
  var low = 0;
  var high = samples.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    if (samples[mid].elapsedMs < elapsedMs) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low;
}

/// Returns [value] limited to the range from zero to [max].
Duration clampDuration(Duration value, Duration max) {
  if (value < Duration.zero) {
    return Duration.zero;
  }
  if (value > max) {
    return max;
  }
  return value;
}

/// Returns the ride-timeline position of [localPosition] inside a segment
/// that starts at [segmentOffset], clamped to `[0, total]`.
Duration globalPlaybackPosition({
  required Duration segmentOffset,
  required Duration localPosition,
  required Duration total,
}) => clampDuration(segmentOffset + localPosition, total);

/// Returns the incident and lock markers as one list sorted by time (the
/// order a seekbar tap searches them in).
List<PlaybackMarker> timelineMarkers({
  required List<int> incidentMarkerMs,
  required List<int> lockMarkerMs,
}) {
  return <PlaybackMarker>[
    for (final marker in incidentMarkerMs)
      PlaybackMarker(elapsedMs: marker, type: PlaybackMarkerType.incident),
    for (final marker in lockMarkerMs)
      PlaybackMarker(elapsedMs: marker, type: PlaybackMarkerType.locked),
  ]..sort((a, b) => a.elapsedMs.compareTo(b.elapsedMs));
}

/// Returns the message shown when none of a ride's segments can be played,
/// naming how many of the [declaredCount] declared segments are missing or
/// unreadable.
String noPlayableVideoMessage({
  required int declaredCount,
  required int missingCount,
  required int unreadableCount,
}) {
  if (declaredCount == 0) {
    return 'This ride has no video segments.';
  }
  final details = <String>[
    if (missingCount > 0) '$missingCount missing',
    if (unreadableCount > 0) '$unreadableCount unreadable',
  ];
  final suffix = details.isEmpty ? '' : ' (${details.join(', ')})';
  return 'No playable video for this ride$suffix.';
}

/// Returns the index of the sample whose elapsed time is closest to
/// [elapsedMs] (the earlier one on a tie), or `null` when [samples] is
/// empty. [samples] must be ordered by elapsed time, as recorded.
int? nearestSampleIndex(List<TelemetryData> samples, int elapsedMs) {
  if (samples.isEmpty) {
    return null;
  }
  final next = firstSampleIndexAtOrAfter(samples, elapsedMs);
  if (next == 0) {
    return 0;
  }
  if (next >= samples.length) {
    return samples.length - 1;
  }
  final before = elapsedMs - samples[next - 1].elapsedMs;
  final after = samples[next].elapsedMs - elapsedMs;
  return before <= after ? next - 1 : next;
}

/// Returns the index of the speed-graph page that holds the window around
/// [positionMs].
///
/// The graph's curve is drawn once per page, three windows wide (from
/// `(index - 1) * windowMs`), and slid across the strip as the position
/// moves, so the curve is redrawn only when the position enters another
/// page. The window centred on any position inside page `index` (positions
/// from `index * windowMs` up to, not including, `(index + 1) * windowMs`)
/// lies within that page.
int speedGraphPageIndex(int positionMs, int windowMs) =>
    windowMs <= 0 ? 0 : (positionMs / windowMs).floor();

/// Returns the segment paths that failed the integrity check according to
/// [issues]: a hash mismatch, no recorded hash, or a file that could not be
/// read for hashing (see [failedSegmentIssuePrefixes]).
Set<String> segmentPathsFailingIntegrity(List<String> issues) {
  final failed = <String>{};
  for (final issue in issues) {
    for (final prefix in failedSegmentIssuePrefixes) {
      if (issue.startsWith(prefix)) {
        final path = issue.substring(prefix.length).trim();
        if (path.isNotEmpty) {
          failed.add(path);
        }
      }
    }
  }
  return failed;
}

/// Describes integrity-check problems for the rider, or returns `null` when
/// there is nothing to report.
///
/// Segments that failed the check are counted once each, quarantined paths
/// are counted once (from [quarantinedCount], not from the issue list), and
/// missing segment files are not reported here because the seekbar already
/// marks them as missing footage.
String? describeIntegrityIssues({
  required List<String> issues,
  required int quarantinedCount,
}) {
  final failedSegments = segmentPathsFailingIntegrity(issues).length;
  var rideDataIssues = 0;
  for (final issue in issues) {
    final isSegmentFailure = failedSegmentIssuePrefixes.any(
      (prefix) => issue.startsWith(prefix),
    );
    if (isSegmentFailure ||
        issue.startsWith('quarantined-segment-paths') ||
        issue.startsWith('missing-segment-file:')) {
      continue;
    }
    rideDataIssues++;
  }

  final parts = <String>[];
  if (rideDataIssues > 0) {
    parts.add('the ride data may have changed since recording');
  }
  if (failedSegments > 0) {
    parts.add(
      '$failedSegments segment${failedSegments == 1 ? '' : 's'} could not be '
      'confirmed unmodified since recording (marked purple on the seekbar)',
    );
  }
  if (quarantinedCount > 0) {
    parts.add(
      '$quarantinedCount segment path${quarantinedCount == 1 ? '' : 's'} '
      'outside the recordings folder ${quarantinedCount == 1 ? 'was' : 'were'} '
      'skipped',
    );
  }
  if (parts.isEmpty) {
    return null;
  }
  return 'Integrity check: ${parts.join('; ')}.';
}
