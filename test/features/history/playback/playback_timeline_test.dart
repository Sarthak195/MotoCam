import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/features/history/models/ride_record.dart';
import 'package:motocam/features/history/widgets/playback_timeline.dart';
import 'package:motocam/features/telemetry/models/telemetry_data.dart';

TelemetryData _sample(int elapsedMs, {double g = 0, double speed = 0}) {
  return TelemetryData(
    latitude: 28.6,
    longitude: 77.2,
    speed: speed,
    bearing: 0,
    accelerationG: g,
    elapsedMs: elapsedMs,
    distanceKm: 0,
    timestamp: DateTime.utc(2026, 1, 1).add(Duration(milliseconds: elapsedMs)),
  );
}

RideSegmentTimelineEntry _entry(String path, int startMs, int endMs) =>
    RideSegmentTimelineEntry(path: path, startMs: startMs, endMs: endMs);

void main() {
  group('orderedDeclaredSegmentPaths', () {
    test('trims, de-duplicates and appends the video path once', () {
      expect(
        orderedDeclaredSegmentPaths(
          segmentPaths: <String>[' a.mp4', 'b.mp4', 'a.mp4', ''],
          videoPath: 'b.mp4',
        ),
        <String>['a.mp4', 'b.mp4'],
      );
      expect(
        orderedDeclaredSegmentPaths(
          segmentPaths: const <String>[],
          videoPath: 'v.mp4',
        ),
        <String>['v.mp4'],
      );
    });
  });

  group('buildEffectiveTimeline', () {
    test('synthesizes back-to-back entries from probed durations', () {
      final timeline = buildEffectiveTimeline(
        declaredPaths: <String>['a', 'b', 'c'],
        storedTimeline: const <RideSegmentTimelineEntry>[],
        probedDurationsByPath: const <String, Duration>{
          'a': Duration(seconds: 30),
          'b': Duration(seconds: 20),
        },
      );
      expect(
        timeline.map((e) => '${e.path}:${e.startMs}-${e.endMs}').toList(),
        // 'c' is unknown and takes the median known duration (30 s).
        <String>['a:0-30000', 'b:30000-50000', 'c:50000-80000'],
      );
    });

    test(
      'keeps stored entries, pushes overlaps later and appends unlisted',
      () {
        final timeline = buildEffectiveTimeline(
          declaredPaths: <String>['a', 'b', 'c'],
          storedTimeline: <RideSegmentTimelineEntry>[
            _entry('b', 25000, 50000),
            _entry('a', -500, 30000),
            _entry('a', 99000, 99999),
          ],
          probedDurationsByPath: const <String, Duration>{
            'c': Duration(seconds: 10),
          },
        );
        expect(
          timeline.map((e) => '${e.path}:${e.startMs}-${e.endMs}').toList(),
          <String>['a:0-30000', 'b:30000-50000', 'c:50000-60000'],
        );
      },
    );

    test('gives every entry at least the minimum duration', () {
      final timeline = buildEffectiveTimeline(
        declaredPaths: <String>['a'],
        storedTimeline: const <RideSegmentTimelineEntry>[],
        probedDurationsByPath: const <String, Duration>{},
      );
      expect(
        timeline.single.endMs - timeline.single.startMs,
        minPlaybackSegmentMs,
      );
    });

    test('takes a probed length for a stored entry saved without an end', () {
      final timeline = buildEffectiveTimeline(
        declaredPaths: <String>['a', 'b', 'c'],
        storedTimeline: <RideSegmentTimelineEntry>[
          _entry('a', 0, 30000),
          _entry('b', 30000, 30000),
          _entry('c', 60000, 90000),
        ],
        probedDurationsByPath: const <String, Duration>{
          'b': Duration(seconds: 30),
        },
      );
      expect(
        timeline.map((e) => '${e.path}:${e.startMs}-${e.endMs}').toList(),
        // 'b' keeps its place in the order instead of becoming 1 ms long.
        <String>['a:0-30000', 'b:30000-60000', 'c:60000-90000'],
      );
    });
  });

  group('ranges', () {
    test('mergeRanges merges overlapping and touching ranges', () {
      expect(
        mergeRanges(const <PlaybackRange>[
          PlaybackRange(startMs: 50, endMs: 60),
          PlaybackRange(startMs: 0, endMs: 10),
          PlaybackRange(startMs: 10, endMs: 20),
          PlaybackRange(startMs: 15, endMs: 18),
          PlaybackRange(startMs: 30, endMs: 30),
        ]),
        const <PlaybackRange>[
          PlaybackRange(startMs: 0, endMs: 20),
          PlaybackRange(startMs: 50, endMs: 60),
        ],
      );
    });

    test('rangesForPaths marks a missing middle segment', () {
      final timeline = <RideSegmentTimelineEntry>[
        _entry('a', 0, 10000),
        _entry('b', 10000, 20000),
        _entry('c', 20000, 30000),
      ];
      expect(
        rangesForPaths(timeline: timeline, paths: <String>{'b'}),
        const <PlaybackRange>[PlaybackRange(startMs: 10000, endMs: 20000)],
      );
      expect(rangesForPaths(timeline: timeline, paths: <String>{}), isEmpty);
    });

    test('uncoveredRanges reports footage overwritten by loop recording', () {
      // 20-minute ride, only the last 3 minutes of video kept.
      final timeline = <RideSegmentTimelineEntry>[
        _entry('s1', 1020000, 1110000),
        _entry('s2', 1110000, 1200000),
      ];
      expect(
        uncoveredRanges(timeline: timeline, totalMs: 1200000),
        const <PlaybackRange>[PlaybackRange(startMs: 0, endMs: 1020000)],
      );
    });

    test('uncoveredRanges ignores short gaps and reports a trailing gap', () {
      final timeline = <RideSegmentTimelineEntry>[
        _entry('s1', 500, 10000),
        _entry('s2', 11000, 20000),
      ];
      expect(
        uncoveredRanges(timeline: timeline, totalMs: 30000),
        const <PlaybackRange>[PlaybackRange(startMs: 20000, endMs: 30000)],
      );
    });
  });

  group('locateSegment', () {
    final offsets = <Duration>[
      const Duration(seconds: 0),
      const Duration(seconds: 40),
    ];
    final durations = <Duration>[
      const Duration(seconds: 30),
      const Duration(seconds: 30),
    ];

    test('maps a position inside a segment to its local position', () {
      final target = locateSegment(
        offsets: offsets,
        durations: durations,
        position: const Duration(seconds: 45),
      );
      expect(target.segmentIndex, 1);
      expect(target.localPosition, const Duration(seconds: 5));
    });

    test('snaps a position in a gap forward to the next segment start', () {
      final target = locateSegment(
        offsets: offsets,
        durations: durations,
        position: const Duration(seconds: 35),
      );
      expect(target.segmentIndex, 1);
      expect(target.localPosition, Duration.zero);
    });

    test('keeps a position past the end in the last segment', () {
      final target = locateSegment(
        offsets: offsets,
        durations: durations,
        position: const Duration(seconds: 90),
      );
      expect(target.segmentIndex, 1);
      expect(target.localPosition, const Duration(seconds: 50));
    });
  });

  group('markers', () {
    test('lock markers sit at the offsets of locked playlist segments', () {
      expect(
        lockMarkerOffsetsMs(
          playlistPaths: <String>['a', 'b', 'c'],
          playlistOffsets: const <Duration>[
            Duration.zero,
            Duration(seconds: 30),
            Duration(seconds: 60),
          ],
          lockedPaths: <String>['c', 'a', 'gone'],
          totalMs: 90000,
        ),
        <int>[0, 60000],
      );
    });

    test('incident markers apply the threshold and debounce', () {
      expect(
        incidentMarkerOffsetsMs(
          samples: <TelemetryData>[
            _sample(1000, g: 3.5),
            _sample(3000, g: 4.0),
            _sample(7000, g: 3.1),
            _sample(9000, g: 3.2),
          ],
          totalMs: 10000,
        ),
        <int>[1000, 9000],
      );
    });

    test('nearestMarker snaps only within the tolerance', () {
      const markers = <PlaybackMarker>[
        PlaybackMarker(elapsedMs: 1000, type: PlaybackMarkerType.incident),
        PlaybackMarker(elapsedMs: 5000, type: PlaybackMarkerType.locked),
      ];
      expect(
        nearestMarker(markers: markers, valueMs: 4800, toleranceMs: 300)?.type,
        PlaybackMarkerType.locked,
      );
      expect(
        nearestMarker(markers: markers, valueMs: 3000, toleranceMs: 300),
        isNull,
      );
    });
  });

  group('speed graph', () {
    test('drag target depends only on finger travel since drag start', () {
      const total = Duration(minutes: 10);
      Duration dragTo(double dx) => speedGraphDragTarget(
        startDx: 300,
        dx: dx,
        width: 400,
        anchorPosition: const Duration(minutes: 5),
        totalDuration: total,
      );

      // Right of centre, moving left still goes back (window is 60 s).
      expect(
        dragTo(260),
        const Duration(minutes: 5) - const Duration(seconds: 6),
      );
      expect(dragTo(300), const Duration(minutes: 5));
      expect(dragTo(340), const Duration(minutes: 5, seconds: 6));
    });

    test('tap target maps the tap position around the centre', () {
      expect(
        speedGraphTapTarget(
          dx: 300,
          width: 400,
          currentPosition: const Duration(minutes: 1),
          totalDuration: const Duration(minutes: 10),
        ),
        const Duration(minutes: 1, seconds: 15),
      );
    });

    test('window is clamped to 10-60 s', () {
      expect(speedGraphWindowMs(3000), 10000);
      expect(speedGraphWindowMs(30000), 30000);
      expect(speedGraphWindowMs(3600000), 60000);
    });

    test('firstSampleIndexAtOrAfter binary-searches ordered samples', () {
      final samples = <TelemetryData>[
        for (var ms = 0; ms <= 10000; ms += 1000) _sample(ms),
      ];
      expect(firstSampleIndexAtOrAfter(samples, -5), 0);
      expect(firstSampleIndexAtOrAfter(samples, 2500), 3);
      expect(firstSampleIndexAtOrAfter(samples, 3000), 3);
      expect(firstSampleIndexAtOrAfter(samples, 20000), samples.length);
    });
  });

  group('integrity issues', () {
    test('segmentPathsFailingIntegrity picks segment failures only', () {
      expect(
        segmentPathsFailingIntegrity(<String>[
          'segment-hash-mismatch:/r/a.mp4',
          'missing-segment-hash:/r/b.mp4',
          'unreadable-segment-file:/r/c.mp4',
          'missing-segment-file:/r/d.mp4',
          'payload-hash-mismatch',
        ]),
        <String>{'/r/a.mp4', '/r/b.mp4', '/r/c.mp4'},
      );
    });

    test('describeIntegrityIssues counts quarantine once', () {
      final notice = describeIntegrityIssues(
        issues: <String>['quarantined-segment-paths:2'],
        quarantinedCount: 2,
      );
      expect(notice, isNotNull);
      expect(notice, contains('2 segment paths'));
      expect(notice, isNot(contains('ride data')));
    });

    test('describeIntegrityIssues describes failed segments', () {
      final notice = describeIntegrityIssues(
        issues: <String>[
          'segment-hash-mismatch:/r/a.mp4',
          'payload-hash-mismatch',
        ],
        quarantinedCount: 0,
      );
      expect(notice, contains('ride data may have changed since recording'));
      expect(notice, contains('1 segment could not be confirmed unmodified'));
      expect(notice, isNot(contains('Security')));
    });

    test('describeIntegrityIssues ignores missing files and clean rides', () {
      expect(
        describeIntegrityIssues(
          issues: <String>['missing-segment-file:/r/a.mp4'],
          quarantinedCount: 0,
        ),
        isNull,
      );
      expect(
        describeIntegrityIssues(issues: const <String>[], quarantinedCount: 0),
        isNull,
      );
    });
  });

  group('recordedIncidentOffsetsMs', () {
    test('clamps, sorts and de-duplicates saved incident offsets', () {
      expect(
        recordedIncidentOffsetsMs(
          elapsedMs: [9000, -5, 3000, 3000, 20000],
          totalMs: 10000,
        ),
        [0, 3000, 9000, 10000],
      );
      expect(recordedIncidentOffsetsMs(elapsedMs: [], totalMs: 1000), isEmpty);
      expect(recordedIncidentOffsetsMs(elapsedMs: [5], totalMs: 0), isEmpty);
    });
  });

  group('clampDuration and globalPlaybackPosition', () {
    test('clampDuration limits to zero and the maximum', () {
      const max = Duration(seconds: 10);
      expect(clampDuration(const Duration(seconds: -3), max), Duration.zero);
      expect(
        clampDuration(const Duration(seconds: 4), max),
        const Duration(seconds: 4),
      );
      expect(clampDuration(const Duration(seconds: 12), max), max);
    });

    test('globalPlaybackPosition adds the segment offset and clamps', () {
      expect(
        globalPlaybackPosition(
          segmentOffset: const Duration(seconds: 60),
          localPosition: const Duration(seconds: 5),
          total: const Duration(seconds: 120),
        ),
        const Duration(seconds: 65),
      );
      expect(
        globalPlaybackPosition(
          segmentOffset: const Duration(seconds: 118),
          localPosition: const Duration(seconds: 5),
          total: const Duration(seconds: 120),
        ),
        const Duration(seconds: 120),
      );
    });
  });

  group('timelineMarkers', () {
    test('merges incident and lock markers sorted by time', () {
      final markers = timelineMarkers(
        incidentMarkerMs: [9000, 1000],
        lockMarkerMs: [5000],
      );
      expect(markers.map((m) => m.elapsedMs), [1000, 5000, 9000]);
      expect(markers[1].type, PlaybackMarkerType.locked);
      expect(markers[0].type, PlaybackMarkerType.incident);
    });

    test('is empty without markers', () {
      expect(
        timelineMarkers(incidentMarkerMs: const [], lockMarkerMs: const []),
        isEmpty,
      );
    });
  });

  group('noPlayableVideoMessage', () {
    test('names a ride with no declared segments', () {
      expect(
        noPlayableVideoMessage(
          declaredCount: 0,
          missingCount: 0,
          unreadableCount: 0,
        ),
        'This ride has no video segments.',
      );
    });

    test('lists only the non-zero counts', () {
      expect(
        noPlayableVideoMessage(
          declaredCount: 3,
          missingCount: 2,
          unreadableCount: 1,
        ),
        'No playable video for this ride (2 missing, 1 unreadable).',
      );
      expect(
        noPlayableVideoMessage(
          declaredCount: 2,
          missingCount: 0,
          unreadableCount: 2,
        ),
        'No playable video for this ride (2 unreadable).',
      );
      expect(
        noPlayableVideoMessage(
          declaredCount: 1,
          missingCount: 0,
          unreadableCount: 0,
        ),
        'No playable video for this ride.',
      );
    });
  });

  group('nearestSampleIndex', () {
    final samples = [_sample(0), _sample(1000), _sample(2000), _sample(5000)];

    test('is null without samples', () {
      expect(nearestSampleIndex(const [], 100), isNull);
    });

    test('picks the closest sample, the earlier one on a tie', () {
      expect(nearestSampleIndex(samples, 400), 0);
      expect(nearestSampleIndex(samples, 600), 1);
      expect(nearestSampleIndex(samples, 500), 0);
      expect(nearestSampleIndex(samples, 1000), 1);
      expect(nearestSampleIndex(samples, 3400), 2);
      expect(nearestSampleIndex(samples, 3600), 3);
    });

    test('clamps to the first and last sample', () {
      expect(nearestSampleIndex(samples, -50), 0);
      expect(nearestSampleIndex(samples, 99999), 3);
    });
  });

  group('speedGraphPageIndex', () {
    test('changes only when the position crosses a window boundary', () {
      expect(speedGraphPageIndex(0, 10000), 0);
      expect(speedGraphPageIndex(9999, 10000), 0);
      expect(speedGraphPageIndex(10000, 10000), 1);
      expect(speedGraphPageIndex(125000, 60000), 2);
    });

    test('keeps the window centred on the position inside its page', () {
      const windowMs = 10000;
      for (final positionMs in [0, 1, 9999, 10000, 34567, 59999]) {
        final index = speedGraphPageIndex(positionMs, windowMs);
        final pageStart = (index - 1) * windowMs;
        final pageEnd = pageStart + 3 * windowMs;
        expect(positionMs - windowMs / 2, greaterThanOrEqualTo(pageStart));
        expect(positionMs + windowMs / 2, lessThanOrEqualTo(pageEnd));
      }
    });

    test('is zero for a missing window', () {
      expect(speedGraphPageIndex(5000, 0), 0);
    });
  });

  group('PlaybackTimelineMarks', () {
    test('is empty by default and not once anything is marked', () {
      expect(const PlaybackTimelineMarks().isEmpty, isTrue);
      expect(const PlaybackTimelineMarks(lockMarkerMs: [1]).isEmpty, isFalse);
      expect(
        const PlaybackTimelineMarks(
          noVideoRanges: [PlaybackRange(startMs: 0, endMs: 5)],
        ).isEmpty,
        isFalse,
      );
    });
  });
}
