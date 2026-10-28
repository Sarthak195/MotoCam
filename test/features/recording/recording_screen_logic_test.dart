import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/features/recording/recording_screen_logic.dart';
import 'package:motocam/features/recording/widgets/recording_settings_sheet.dart';
import 'package:motocam/features/recording/widgets/start_preflight_sheet.dart';

void main() {
  group('BackgroundStallTracker', () {
    final t0 = DateTime(2026, 1, 1, 12);

    test('real screen-off: synthesized hidden/inactive on return keep the '
        'first paused timestamp', () {
      final tracker = BackgroundStallTracker();
      // Going away: inactive -> hidden -> paused.
      tracker.onLifecycleChanged(
        AppLifecycleState.inactive,
        isRecording: true,
        now: t0,
      );
      tracker.onLifecycleChanged(
        AppLifecycleState.hidden,
        isRecording: true,
        now: t0.add(const Duration(milliseconds: 10)),
      );
      tracker.onLifecycleChanged(
        AppLifecycleState.paused,
        isRecording: true,
        now: t0.add(const Duration(milliseconds: 20)),
      );

      // Coming back 10 minutes later: hidden -> inactive -> resumed.
      final back = t0.add(const Duration(minutes: 10));
      expect(
        tracker.onLifecycleChanged(
          AppLifecycleState.hidden,
          isRecording: true,
          now: back,
        ),
        isNull,
      );
      expect(
        tracker.onLifecycleChanged(
          AppLifecycleState.inactive,
          isRecording: true,
          now: back,
        ),
        isNull,
      );
      final duration = tracker.onLifecycleChanged(
        AppLifecycleState.resumed,
        isRecording: true,
        now: back,
      );
      expect(duration, isNotNull);
      expect(duration! >= const Duration(minutes: 9), isTrue);
      expect(tracker.backgroundedAt, isNull);
    });

    test('inactive-only periods (PiP, notification shade) never trigger', () {
      final tracker = BackgroundStallTracker();
      tracker.onLifecycleChanged(
        AppLifecycleState.inactive,
        isRecording: true,
        now: t0,
      );
      final duration = tracker.onLifecycleChanged(
        AppLifecycleState.resumed,
        isRecording: true,
        now: t0.add(const Duration(minutes: 5)),
      );
      expect(duration, isNull);
    });

    test('short background periods stay below the threshold', () {
      final tracker = BackgroundStallTracker();
      tracker.onLifecycleChanged(
        AppLifecycleState.paused,
        isRecording: true,
        now: t0,
      );
      final duration = tracker.onLifecycleChanged(
        AppLifecycleState.resumed,
        isRecording: true,
        now: t0.add(const Duration(seconds: 7)),
      );
      expect(duration, isNull);
    });

    test('nothing is reported when not recording, and the timestamp is '
        'cleared so it cannot leak into the next recording', () {
      final tracker = BackgroundStallTracker();
      tracker.onLifecycleChanged(
        AppLifecycleState.paused,
        isRecording: true,
        now: t0,
      );
      // Recording was stopped while in the background.
      expect(
        tracker.onLifecycleChanged(
          AppLifecycleState.resumed,
          isRecording: false,
          now: t0.add(const Duration(minutes: 1)),
        ),
        isNull,
      );
      expect(tracker.backgroundedAt, isNull);

      // Not recording while backgrounded: no timestamp is taken.
      tracker.onLifecycleChanged(
        AppLifecycleState.paused,
        isRecording: false,
        now: t0,
      );
      expect(tracker.backgroundedAt, isNull);
    });
  });

  group('incidentLockNotice', () {
    test('first segment locks only the current clip', () {
      expect(incidentLockNotice(registeredSegments: 0), 'Locked: current clip');
    });

    test('previous segments are capped at protectPastSegments', () {
      expect(
        incidentLockNotice(registeredSegments: 1),
        'Locked: current clip + 1 previous',
      );
      expect(
        incidentLockNotice(registeredSegments: 7),
        'Locked: current clip + 2 previous',
      );
    });

    test('automatic locks say an incident was detected', () {
      expect(
        incidentLockNotice(registeredSegments: 3, automatic: true),
        'Incident detected. Locked: current clip + 2 previous',
      );
    });
  });

  test('formatRecordingElapsed pads hours, minutes and seconds', () {
    expect(formatRecordingElapsed(Duration.zero), '00:00:00');
    expect(
      formatRecordingElapsed(
        const Duration(hours: 1, minutes: 23, seconds: 45),
      ),
      '01:23:45',
    );
    expect(formatRecordingElapsed(const Duration(hours: 12)), '12:00:00');
  });

  test('START/STOP button labels reach WCAG AA contrast (4.5:1)', () {
    expect(
      contrastRatio(recordingButtonLabelColor, recordingStartButtonColor),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      contrastRatio(recordingButtonLabelColor, recordingStopButtonColor),
      greaterThanOrEqualTo(4.5),
    );
  });

  group('resolveInitialFps', () {
    test('keeps the saved FPS when it is offered', () {
      expect(resolveInitialFps(60, const [24, 30, 60]), 60);
    });

    test('falls back to 30 when the saved FPS was dropped', () {
      expect(resolveInitialFps(60, const [24, 30]), 30);
    });

    test('falls back to the last option when 30 is not offered', () {
      expect(resolveInitialFps(60, const [24]), 24);
    });

    test('an empty list keeps the saved FPS', () {
      expect(resolveInitialFps(60, const []), 60);
    });
  });

  group('RideCheckpointTracker', () {
    test('no segment yet: no checkpoint', () {
      expect(RideCheckpointTracker().shouldCheckpoint(const [], 0), isFalse);
    });

    test('a new segment or lock triggers exactly one checkpoint', () {
      final tracker = RideCheckpointTracker();
      expect(tracker.shouldCheckpoint(const ['s1'], 0), isTrue);
      expect(tracker.shouldCheckpoint(const ['s1'], 0), isFalse);
      expect(tracker.shouldCheckpoint(const ['s1', 's2'], 0), isTrue);
      expect(tracker.shouldCheckpoint(const ['s1', 's2'], 1), isTrue);
      expect(tracker.shouldCheckpoint(const ['s1', 's2'], 1), isFalse);
    });

    test('a roll at the loop limit (same length, new newest segment) still '
        'triggers a checkpoint', () {
      final tracker = RideCheckpointTracker();
      expect(tracker.shouldCheckpoint(const ['s1', 's2', 's3'], 0), isTrue);
      // s4 registered and s1 evicted: the length stays 3.
      expect(tracker.shouldCheckpoint(const ['s2', 's3', 's4'], 0), isTrue);
      expect(tracker.shouldCheckpoint(const ['s2', 's3', 's4'], 0), isFalse);
    });

    test('an eviction after the registration it follows is picked up', () {
      final tracker = RideCheckpointTracker();
      expect(
        tracker.shouldCheckpoint(const ['s1', 's2', 's3', 's4'], 0),
        isTrue,
      );
      expect(tracker.shouldCheckpoint(const ['s2', 's3', 's4'], 0), isTrue);
    });

    test('reset starts over for a new ride', () {
      final tracker = RideCheckpointTracker();
      expect(tracker.shouldCheckpoint(const ['s1'], 0), isTrue);
      tracker.reset();
      expect(tracker.shouldCheckpoint(const ['s1'], 0), isTrue);
    });
  });

  group('startPreflightNeedsSheet', () {
    StartPreflightCheck check(
      StartPreflightStatus status, {
      bool isBlocking = false,
      bool opensSheet = true,
    }) {
      return StartPreflightCheck(
        title: 'check',
        detail: 'detail',
        status: status,
        isBlocking: isBlocking,
        opensSheet: opensSheet,
      );
    }

    test('all checks OK: no sheet', () {
      expect(
        startPreflightNeedsSheet([
          check(StartPreflightStatus.ok, isBlocking: true),
          check(StartPreflightStatus.ok),
        ]),
        isFalse,
      );
    });

    test('a warning opens the sheet', () {
      expect(
        startPreflightNeedsSheet([
          check(StartPreflightStatus.ok, isBlocking: true),
          check(StartPreflightStatus.warning),
        ]),
        isTrue,
      );
    });

    test('a warning that does not open the sheet on its own (the battery '
        'exemption after its one-time offer) does not open it', () {
      expect(
        startPreflightNeedsSheet([
          check(StartPreflightStatus.ok, isBlocking: true),
          check(StartPreflightStatus.warning, opensSheet: false),
        ]),
        isFalse,
      );
    });

    test('another warning still opens the sheet next to a quiet one', () {
      expect(
        startPreflightNeedsSheet([
          check(StartPreflightStatus.warning, opensSheet: false),
          check(StartPreflightStatus.warning),
        ]),
        isTrue,
      );
    });

    test('a failed blocking check always opens the sheet', () {
      expect(
        startPreflightNeedsSheet([
          check(
            StartPreflightStatus.failed,
            isBlocking: true,
            opensSheet: false,
          ),
        ]),
        isTrue,
      );
    });
  });

  group('backgroundCaptureContinued', () {
    final t0 = DateTime(2026, 1, 1, 12);
    const rate = backgroundCaptureMinBytesPerSecond;
    const allowance = backgroundCaptureStallAllowanceBytes;

    RecordingFileObservation obs(
      String path,
      int firstSize,
      int firstSecond,
      int latestSize,
      int latestSecond,
    ) {
      return RecordingFileObservation(
        path: path,
        firstSizeBytes: firstSize,
        firstSeenAt: t0.add(Duration(seconds: firstSecond)),
        latestSizeBytes: latestSize,
        latestSeenAt: t0.add(Duration(seconds: latestSecond)),
      );
    }

    test('same file that kept growing counts as alive', () {
      final initial = obs('/c/REC1.mp4', 1000, 0, 1000, 0);
      // 60 s at about 1 MB/s.
      final latest = obs('/c/REC1.mp4', 1000, 0, 60 * 1000 * 1000, 60);
      expect(
        backgroundCaptureContinued(initial: initial, latest: latest),
        isTrue,
      );
    });

    test('same file that stalled is not alive', () {
      final initial = obs('/c/REC1.mp4', 5000000, 0, 5000000, 0);
      // Only an encoder flush landed after the app left.
      final latest = obs('/c/REC1.mp4', 5000000, 0, 5000000 + 200000, 60);
      expect(
        backgroundCaptureContinued(initial: initial, latest: latest),
        isFalse,
      );
    });

    test('the floor scales with the time in the background', () {
      final initial = obs('/c/REC1.mp4', 0, 0, 0, 0);
      final justEnough = obs('/c/REC1.mp4', 0, 0, rate * 30 + allowance, 30);
      final tooLittle = obs('/c/REC1.mp4', 0, 0, rate * 30 + allowance - 1, 30);
      expect(
        backgroundCaptureContinued(initial: initial, latest: justEnough),
        isTrue,
      );
      expect(
        backgroundCaptureContinued(initial: initial, latest: tooLittle),
        isFalse,
      );
    });

    test('a roll in the background: a newer file that grows is alive', () {
      final initial = obs('/c/REC1.mp4', 1000, 0, 30000000, 40);
      final latest = obs('/c/REC2.mp4', 500000, 41, 20000000, 60);
      expect(
        backgroundCaptureContinued(initial: initial, latest: latest),
        isTrue,
      );
    });

    test('a roll in the background: a newer file that stays empty is not '
        'alive', () {
      final initial = obs('/c/REC1.mp4', 1000, 0, 1000, 40);
      final latest = obs('/c/REC2.mp4', 0, 41, 0, 60);
      expect(
        backgroundCaptureContinued(initial: initial, latest: latest),
        isFalse,
      );
    });

    test('a newer file seen too briefly is not evidence', () {
      final initial = obs('/c/REC1.mp4', 1000, 0, 30000000, 59);
      final latest = obs('/c/REC2.mp4', 0, 59, 900000, 60);
      expect(
        backgroundCaptureContinued(initial: initial, latest: latest),
        isFalse,
      );
    });

    test('a missing observation is unknown', () {
      final some = obs('/c/REC1.mp4', 0, 0, 90000000, 60);
      expect(backgroundCaptureContinued(initial: null, latest: some), isFalse);
      expect(backgroundCaptureContinued(initial: some, latest: null), isFalse);
    });
  });

  group('BackgroundCaptureMonitor', () {
    final t0 = DateTime(2026, 1, 1, 12);
    final modified = DateTime(2026, 1, 1, 12);

    RecordingFileSample sample(String path, int size) =>
        RecordingFileSample(path: path, sizeBytes: size, modified: modified);

    /// A probe that returns (or throws) the queued results in order, then
    /// repeats the last one.
    Future<RecordingFileSample?> Function() probeOf(List<Object?> results) {
      var index = 0;
      return () async {
        final result =
            results[index < results.length ? index : results.length - 1];
        index++;
        if (result is Exception) {
          throw result;
        }
        return result as RecordingFileSample?;
      };
    }

    test('alive: the same file grew through the background period', () async {
      final monitor = BackgroundCaptureMonitor(
        probe: probeOf([
          sample('/c/REC1.mp4', 1000),
          sample('/c/REC1.mp4', 30000000),
          sample('/c/REC1.mp4', 60000000),
        ]),
      );
      await monitor.start(t0);
      expect(monitor.isObserving, isTrue);
      await monitor.sample(t0.add(const Duration(seconds: 30)));
      final continued = await monitor.finish(
        t0.add(const Duration(seconds: 60)),
      );
      expect(continued, isTrue);
      expect(monitor.isObserving, isFalse);
    });

    test('stalled: the file stopped growing', () async {
      final monitor = BackgroundCaptureMonitor(
        probe: probeOf([
          sample('/c/REC1.mp4', 5000000),
          sample('/c/REC1.mp4', 5100000),
          sample('/c/REC1.mp4', 5100000),
        ]),
      );
      await monitor.start(t0);
      await monitor.sample(t0.add(const Duration(seconds: 30)));
      expect(
        await monitor.finish(t0.add(const Duration(seconds: 60))),
        isFalse,
      );
    });

    test('roll during the background: the new file is judged on its own '
        'growth', () async {
      final alive = BackgroundCaptureMonitor(
        probe: probeOf([
          sample('/c/REC1.mp4', 1000),
          sample('/c/REC2.mp4', 100000),
          sample('/c/REC2.mp4', 25000000),
        ]),
      );
      await alive.start(t0);
      await alive.sample(t0.add(const Duration(seconds: 35)));
      expect(await alive.finish(t0.add(const Duration(seconds: 60))), isTrue);

      final stalled = BackgroundCaptureMonitor(
        probe: probeOf([
          sample('/c/REC1.mp4', 1000),
          sample('/c/REC2.mp4', 0),
          sample('/c/REC2.mp4', 0),
        ]),
      );
      await stalled.start(t0);
      await stalled.sample(t0.add(const Duration(seconds: 35)));
      expect(
        await stalled.finish(t0.add(const Duration(seconds: 60))),
        isFalse,
      );
    });

    test('a roll first seen at the return is not evidence', () async {
      final monitor = BackgroundCaptureMonitor(
        probe: probeOf([
          sample('/c/REC1.mp4', 1000),
          sample('/c/REC2.mp4', 900000),
        ]),
      );
      await monitor.start(t0);
      expect(
        await monitor.finish(t0.add(const Duration(seconds: 60))),
        isFalse,
      );
    });

    test('probe failure makes the result unknown', () async {
      final throwsAtEnd = BackgroundCaptureMonitor(
        probe: probeOf([
          sample('/c/REC1.mp4', 1000),
          Exception('cache dir unreadable'),
        ]),
      );
      await throwsAtEnd.start(t0);
      expect(
        await throwsAtEnd.finish(t0.add(const Duration(seconds: 60))),
        isFalse,
      );

      final failsMidway = BackgroundCaptureMonitor(
        probe: probeOf([
          sample('/c/REC1.mp4', 1000),
          Exception('transient'),
          sample('/c/REC1.mp4', 90000000),
        ]),
      );
      await failsMidway.start(t0);
      await failsMidway.sample(t0.add(const Duration(seconds: 30)));
      expect(
        await failsMidway.finish(t0.add(const Duration(seconds: 60))),
        isFalse,
      );
    });

    test('no file is unknown', () async {
      final monitor = BackgroundCaptureMonitor(probe: probeOf([null]));
      await monitor.start(t0);
      expect(
        await monitor.finish(t0.add(const Duration(seconds: 60))),
        isFalse,
      );
    });

    test('finish without start, and after reset, is unknown', () async {
      final monitor = BackgroundCaptureMonitor(
        probe: probeOf([
          sample('/c/REC1.mp4', 0),
          sample('/c/REC1.mp4', 90000000),
        ]),
      );
      expect(await monitor.finish(t0), isFalse);

      await monitor.start(t0);
      monitor.reset();
      expect(monitor.isObserving, isFalse);
      expect(
        await monitor.finish(t0.add(const Duration(seconds: 60))),
        isFalse,
      );
    });

    test('a slow first probe still completes before the final one', () async {
      final gate = Completer<void>();
      var calls = 0;
      final monitor = BackgroundCaptureMonitor(
        probe: () async {
          calls++;
          if (calls == 1) {
            await gate.future;
            return sample('/c/REC1.mp4', 0);
          }
          return sample('/c/REC1.mp4', 90000000);
        },
      );
      unawaited(monitor.start(t0));
      final result = monitor.finish(t0.add(const Duration(seconds: 60)));
      gate.complete();
      expect(await result, isTrue);
    });
  });

  group('newestRecordingFileIn', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('motocam_rec_probe');
    });

    tearDown(() {
      dir.deleteSync(recursive: true);
    });

    test('returns the newest REC*.mp4 and ignores other files', () async {
      final older = File('${dir.path}/REC111.mp4')..writeAsBytesSync([1, 2]);
      older.setLastModifiedSync(DateTime(2026, 1, 1, 10));
      final newer = File('${dir.path}/REC222.mp4')
        ..writeAsBytesSync([1, 2, 3, 4]);
      newer.setLastModifiedSync(DateTime(2026, 1, 1, 11));
      File('${dir.path}/other.mp4')
        ..writeAsBytesSync([1])
        ..setLastModifiedSync(DateTime(2026, 1, 1, 12));
      File('${dir.path}/REC333.tmp')
        ..writeAsBytesSync([1])
        ..setLastModifiedSync(DateTime(2026, 1, 1, 12));
      Directory('${dir.path}/REC444.mp4').createSync();

      final result = await newestRecordingFileIn(dir);

      expect(result, isNotNull);
      expect(File(result!.path).uri, newer.uri);
      expect(result.sizeBytes, 4);
    });

    test('returns null when there is no recording file', () async {
      File('${dir.path}/notes.txt').writeAsStringSync('x');
      expect(await newestRecordingFileIn(dir), isNull);
    });

    test('throws when the directory is missing', () async {
      final missing = Directory('${dir.path}/missing');
      await expectLater(newestRecordingFileIn(missing), throwsA(anything));
    });
  });
}
