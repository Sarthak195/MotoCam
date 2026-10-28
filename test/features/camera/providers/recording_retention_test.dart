import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/features/camera/providers/recording_retention.dart';

void main() {
  group('selectSegmentsToEvict', () {
    test('keeps everything while unlocked segments fit the loop', () {
      expect(
        selectSegmentsToEvict(
          sessionPaths: const ['a', 'b', 'c'],
          lockedPaths: const {},
          maxUnlockedSegments: 3,
        ),
        isEmpty,
      );
    });

    test('treats a segment as locked when a locked path has its file name', () {
      final sep = Platform.pathSeparator;
      final current = ['new${sep}a.mp4', 'new${sep}b.mp4', 'new${sep}c.mp4'];
      expect(
        selectSegmentsToEvict(
          sessionPaths: current,
          // Stale absolute path from before a container move.
          lockedPaths: {'old${sep}a.mp4'},
          maxUnlockedSegments: 1,
        ),
        ['new${sep}b.mp4'],
      );
    });

    test('evicts the oldest unlocked segments first', () {
      expect(
        selectSegmentsToEvict(
          sessionPaths: const ['a', 'b', 'c', 'd', 'e'],
          lockedPaths: const {},
          maxUnlockedSegments: 3,
        ),
        ['a', 'b'],
      );
    });

    test('locked segments do not count against the loop and are kept', () {
      // 3 locked + 3 unlocked with a loop of 3: nothing to delete.
      expect(
        selectSegmentsToEvict(
          sessionPaths: const ['l1', 'u1', 'l2', 'u2', 'l3', 'u3'],
          lockedPaths: const {'l1', 'l2', 'l3'},
          maxUnlockedSegments: 3,
        ),
        isEmpty,
      );

      // A fourth unlocked segment evicts only the oldest unlocked one.
      expect(
        selectSegmentsToEvict(
          sessionPaths: const ['l1', 'u1', 'l2', 'u2', 'l3', 'u3', 'u4'],
          lockedPaths: const {'l1', 'l2', 'l3'},
          maxUnlockedSegments: 3,
        ),
        ['u1'],
      );
    });

    test('never evicts the newest segment when locks exceed the loop', () {
      // More locked segments than the loop size (the old N+1 locked case).
      final paths = [for (var i = 0; i < 7; i++) 'locked_$i', 'newest'];
      final evicted = selectSegmentsToEvict(
        sessionPaths: paths,
        lockedPaths: {for (var i = 0; i < 7; i++) 'locked_$i'},
        maxUnlockedSegments: 6,
      );
      expect(evicted, isEmpty);
    });

    test('a loop size below 1 still keeps the newest unlocked segment', () {
      expect(
        selectSegmentsToEvict(
          sessionPaths: const ['a', 'b'],
          lockedPaths: const {},
          maxUnlockedSegments: 0,
        ),
        ['a'],
      );
    });
  });

  group('segmentsEvictedByNextRegistration', () {
    test('counts the oldest unlocked segment once the loop is full', () {
      expect(
        segmentsEvictedByNextRegistration(
          sessionPaths: const ['a', 'b', 'c'],
          lockedPaths: const {},
          nextSegmentLocked: false,
          maxUnlockedSegments: 3,
        ),
        ['a'],
      );
    });

    test('frees nothing while the loop has room', () {
      expect(
        segmentsEvictedByNextRegistration(
          sessionPaths: const ['a', 'b'],
          lockedPaths: const {},
          nextSegmentLocked: false,
          maxUnlockedSegments: 3,
        ),
        isEmpty,
      );
    });

    test('a locked next segment frees nothing extra', () {
      expect(
        segmentsEvictedByNextRegistration(
          sessionPaths: const ['a', 'b', 'c'],
          lockedPaths: const {'a'},
          nextSegmentLocked: true,
          maxUnlockedSegments: 2,
        ),
        isEmpty,
      );
    });
  });

  group('unsettledSegmentSequences', () {
    test('only the active segment when every earlier one is registered', () {
      expect(
        unsettledSegmentSequences(lastSettledSequence: 4, activeSequence: 5),
        {5},
      );
    });

    test('includes the stopped segment still being saved during a roll', () {
      expect(
        unsettledSegmentSequences(lastSettledSequence: 3, activeSequence: 5),
        {4, 5},
      );
    });

    test('is empty when nothing is pending', () {
      expect(
        unsettledSegmentSequences(lastSettledSequence: 5, activeSequence: 5),
        isEmpty,
      );
    });
  });

  group('findOrphanTelemetryFiles', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('motocam_retention_test');
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    String sep(String name) => '${root.path}${Platform.pathSeparator}$name';

    File writeSidecar(String name, Map<String, dynamic> json) {
      return File(sep(name))..writeAsStringSync(jsonEncode(json));
    }

    test('returns an empty list for a missing directory', () {
      expect(findOrphanTelemetryFiles(sep('missing')), isEmpty);
    });

    test('keeps rides with at least one existing segment', () {
      File(sep('seg_1.mp4')).writeAsStringSync('video');
      writeSidecar('ride_a.telemetry.json', {
        'segmentPaths': [sep('seg_1.mp4'), sep('gone.mp4')],
      });
      expect(findOrphanTelemetryFiles(root.path), isEmpty);
    });

    test('flags rides whose segments are all gone or that list none', () {
      final gone = writeSidecar('ride_b.telemetry.json', {
        'segmentPaths': [sep('gone.mp4')],
      });
      final empty = writeSidecar('ride_c.telemetry.json', {
        'segmentPaths': <String>[],
      });
      expect(findOrphanTelemetryFiles(root.path).toSet(), {
        gone.path,
        empty.path,
      });
    });

    test('falls back to videoPath like the reader (schema 1 files)', () {
      File(sep('s1_ride.mp4')).writeAsStringSync('video');
      writeSidecar('ride_s1.telemetry.json', {'videoPath': sep('s1_ride.mp4')});
      writeSidecar('ride_s1_empty.telemetry.json', {
        'segmentPaths': <String>[' ', ''],
        'videoPath': '/old/root/s1_ride.mp4',
      });
      final gone = writeSidecar('ride_s1_gone.telemetry.json', {
        'videoPath': sep('s1_gone.mp4'),
      });
      expect(findOrphanTelemetryFiles(root.path), [gone.path]);
    });

    test('keeps a legacy sidecar whose video is recovered by name', () {
      File(sep('legacy_ride.mp4')).writeAsStringSync('video');
      writeSidecar('legacy_ride.telemetry.json', <String, dynamic>{});
      final gone = writeSidecar('legacy_gone.telemetry.json', {
        'segmentPaths': <String>[],
      });
      expect(findOrphanTelemetryFiles(root.path), [gone.path]);
    });

    test('never flags locked rides, even without videos', () {
      writeSidecar('ride_d.telemetry.json', {
        'segmentPaths': [sep('gone.mp4')],
        'lockedSegmentPaths': [sep('gone.mp4')],
      });
      expect(findOrphanTelemetryFiles(root.path), isEmpty);
    });

    test('finds a moved segment by file name next to the sidecar', () {
      File(sep('seg_moved.mp4')).writeAsStringSync('video');
      writeSidecar('ride_e.telemetry.json', {
        'segmentPaths': ['/old/root/seg_moved.mp4'],
      });
      expect(findOrphanTelemetryFiles(root.path), isEmpty);
    });

    test('skips malformed sidecars and other files', () {
      File(sep('ride_f.telemetry.json')).writeAsStringSync('{not json');
      File(sep('ride_g.telemetry.json')).writeAsStringSync('[1, 2]');
      File(sep('notes.json')).writeAsStringSync('{}');
      expect(findOrphanTelemetryFiles(root.path), isEmpty);
    });

    test('does not scan subdirectories', () {
      Directory(sep('nested')).createSync();
      writeSidecar('nested${Platform.pathSeparator}ride_h.telemetry.json', {
        'segmentPaths': [sep('gone.mp4')],
      });
      expect(findOrphanTelemetryFiles(root.path), isEmpty);
    });
  });

  group('isActiveSegmentLocked', () {
    test('is on while the recording segment has a pending lock', () {
      expect(
        isActiveSegmentLocked(
          isRecording: true,
          activeSequence: 3,
          pendingLockSequences: {3},
        ),
        isTrue,
      );
    });

    test('is off without a pending lock', () {
      expect(
        isActiveSegmentLocked(
          isRecording: true,
          activeSequence: 3,
          pendingLockSequences: const <int>{},
        ),
        isFalse,
      );
    });

    test('ends when the segment rolls: the next sequence is not pending', () {
      // The lock covered segment 3 and segment 2, still being saved.
      const pending = {2, 3};
      expect(
        isActiveSegmentLocked(
          isRecording: true,
          activeSequence: 3,
          pendingLockSequences: pending,
        ),
        isTrue,
      );
      expect(
        isActiveSegmentLocked(
          isRecording: true,
          activeSequence: 4,
          pendingLockSequences: pending,
        ),
        isFalse,
      );
    });

    test('is off when the recording stopped', () {
      expect(
        isActiveSegmentLocked(
          isRecording: false,
          activeSequence: 3,
          pendingLockSequences: {3},
        ),
        isFalse,
      );
    });

    test('covers a lock pressed during a roll for the new segment', () {
      // Segment 3 is still being saved and segment 4 is being recorded.
      final pending = unsettledSegmentSequences(
        lastSettledSequence: 2,
        activeSequence: 4,
      );
      expect(
        isActiveSegmentLocked(
          isRecording: true,
          activeSequence: 4,
          pendingLockSequences: pending,
        ),
        isTrue,
      );
    });
  });
}
