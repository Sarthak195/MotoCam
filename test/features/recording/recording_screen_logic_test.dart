import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/features/camera/providers/camera_init_status.dart';
import 'package:motocam/features/camera/providers/recording_retention.dart';
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

  group('autoIncidentProtectPastSegments', () {
    Map<String, dynamic> segment(int startMs, int endMs) => {
      'path': 'segment_$startMs.mp4',
      'startMs': startMs,
      'endMs': endMs,
    };

    // The sequences an automatic lock keeps, with the same arithmetic as
    // CameraProvider.markIncident: the last n registered segments plus every
    // sequence not registered yet.
    Set<int> lockedSequences({
      required List<Map<String, dynamic>> timeline,
      required int activeSequence,
      required int joltElapsedMs,
    }) {
      final registered = [for (var i = 1; i <= timeline.length; i++) i];
      final past = autoIncidentProtectPastSegments(
        timeline: timeline,
        joltElapsedMs: joltElapsedMs,
      ).clamp(0, 10);
      final start = (registered.length - past).clamp(0, registered.length);
      return {
        ...registered.sublist(start),
        ...unsettledSegmentSequences(
          lastSettledSequence: registered.length,
          activeSequence: activeSequence,
        ),
      };
    }

    test('a jolt just before a roll keeps the segments around it', () {
      // 180 s segments. The jolt at 539.5 s is in segment 3; the confirmation
      // comes after segment 3 was saved, while segment 4 records.
      final locked = lockedSequences(
        timeline: [
          segment(0, 180000),
          segment(180000, 360000),
          segment(360000, 540000),
        ],
        activeSequence: 4,
        joltElapsedMs: 539500,
      );
      expect(locked, containsAll(<int>[2, 3, 4]));
    });

    test('a confirmation while the jolt segment is still saving', () {
      final locked = lockedSequences(
        timeline: [segment(0, 180000), segment(180000, 360000)],
        activeSequence: 4,
        joltElapsedMs: 359800,
      );
      expect(locked, containsAll(<int>[1, 2, 3, 4]));
    });

    test('short segments that rolled twice before confirmation', () {
      // 5 s segments: jolt at 9.9 s (segment 2), confirmed at 20.5 s.
      final locked = lockedSequences(
        timeline: [
          segment(0, 5000),
          segment(5000, 10000),
          segment(10000, 15000),
          segment(15000, 20000),
        ],
        activeSequence: 5,
        joltElapsedMs: 9900,
      );
      expect(locked, containsAll(<int>[1, 2, 3, 4, 5]));
    });

    test('without a jolt time it keeps two', () {
      expect(
        autoIncidentProtectPastSegments(
          timeline: [segment(0, 5000)],
          joltElapsedMs: null,
        ),
        2,
      );
    });
  });

  group('shouldAutoLockIncident', () {
    final recordingStartedAt = DateTime(2026, 11, 13, 9);

    test('locks a new incident confirmed during the recording', () {
      expect(
        shouldAutoLockIncident(
          isRecording: true,
          detectedAt: recordingStartedAt.add(const Duration(seconds: 30)),
          lastHandledAt: null,
          recordingStartedAt: recordingStartedAt,
        ),
        isTrue,
      );
    });

    test('ignores an incident confirmed before the recording started', () {
      // Confirmed between rides (sensors keep running) and still reported
      // while the next recording starts, before the telemetry session
      // clears it.
      expect(
        shouldAutoLockIncident(
          isRecording: true,
          detectedAt: recordingStartedAt.subtract(
            const Duration(milliseconds: 1),
          ),
          lastHandledAt: null,
          recordingStartedAt: recordingStartedAt,
        ),
        isFalse,
      );
    });

    test('acts once per incident and only while recording', () {
      final detectedAt = recordingStartedAt.add(const Duration(seconds: 5));
      expect(
        shouldAutoLockIncident(
          isRecording: true,
          detectedAt: detectedAt,
          lastHandledAt: detectedAt,
          recordingStartedAt: recordingStartedAt,
        ),
        isFalse,
      );
      expect(
        shouldAutoLockIncident(
          isRecording: false,
          detectedAt: detectedAt,
          lastHandledAt: null,
          recordingStartedAt: recordingStartedAt,
        ),
        isFalse,
      );
      expect(
        shouldAutoLockIncident(
          isRecording: true,
          detectedAt: detectedAt,
          lastHandledAt: null,
          recordingStartedAt: null,
        ),
        isFalse,
      );
    });
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
      int latestSecond, {
      Map<int, int> recent = const <int, int>{},
    }) {
      return RecordingFileObservation(
        path: path,
        firstSizeBytes: firstSize,
        firstSeenAt: t0.add(Duration(seconds: firstSecond)),
        latestSizeBytes: latestSize,
        latestSeenAt: t0.add(Duration(seconds: latestSecond)),
        recentPoints: [
          for (final entry in recent.entries)
            (at: t0.add(Duration(seconds: entry.key)), sizeBytes: entry.value),
          (at: t0.add(Duration(seconds: latestSecond)), sizeBytes: latestSize),
        ],
      );
    }

    test('same file that kept growing counts as alive', () {
      final initial = obs('/c/REC1.mp4', 1000, 0, 1000, 0);
      // 60 s at about 1 MB/s.
      final latest = obs(
        '/c/REC1.mp4',
        1000,
        0,
        60 * 1000 * 1000,
        60,
        recent: {54: 54 * 1000 * 1000, 55: 55 * 1000 * 1000},
      );
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
      const enough = rate * 30 + allowance;
      final justEnough = obs(
        '/c/REC1.mp4',
        0,
        0,
        enough,
        30,
        recent: {25: enough - rate * 5},
      );
      final tooLittle = obs(
        '/c/REC1.mp4',
        0,
        0,
        enough - 1,
        30,
        recent: {25: enough - 1 - rate * 5},
      );
      expect(
        backgroundCaptureContinued(initial: initial, latest: justEnough),
        isTrue,
      );
      expect(
        backgroundCaptureContinued(initial: initial, latest: tooLittle),
        isFalse,
      );
    });

    test('a file that grew early and then stayed flat is not alive', () {
      final initial = obs('/c/REC1.mp4', 0, 0, 0, 0);
      // About 200 MB in the first 3 minutes, then nothing for a minute.
      const size = 200 * 1000 * 1000;
      final latest = obs(
        '/c/REC1.mp4',
        0,
        0,
        size,
        240,
        recent: {for (var s = 230; s < 240; s++) s: size},
      );
      expect(
        backgroundCaptureContinued(initial: initial, latest: latest),
        isFalse,
      );
    });

    test('growth only right after the leave is not alive', () {
      // The writer flushed more than the allowance when capture stopped.
      final initial = obs('/c/REC1.mp4', 5000000, 0, 5000000, 0);
      const size = 5000000 + 2 * 1000 * 1000;
      final latest = obs(
        '/c/REC1.mp4',
        5000000,
        0,
        size,
        20,
        recent: {for (var s = 10; s < 20; s++) s: size},
      );
      expect(
        backgroundCaptureContinued(initial: initial, latest: latest),
        isFalse,
      );
    });

    test('the recent span must be long enough and within the lookback', () {
      final initial = obs('/c/REC1.mp4', 0, 0, 0, 0);
      // Only probes too close to the return.
      final tooRecent = obs(
        '/c/REC1.mp4',
        0,
        0,
        60 * 1000 * 1000,
        60,
        recent: {57: 57 * 1000 * 1000, 59: 59 * 1000 * 1000},
      );
      // Only a probe from before the lookback (no ticks for half a minute).
      final tooOld = obs(
        '/c/REC1.mp4',
        0,
        0,
        60 * 1000 * 1000,
        60,
        recent: {30: 30 * 1000 * 1000},
      );
      expect(
        backgroundCaptureContinued(initial: initial, latest: tooRecent),
        isFalse,
      );
      expect(
        backgroundCaptureContinued(initial: initial, latest: tooOld),
        isFalse,
      );
    });

    test('a roll in the background: a newer file that grows is alive', () {
      final initial = obs('/c/REC1.mp4', 1000, 0, 30000000, 40);
      final latest = obs(
        '/c/REC2.mp4',
        500000,
        41,
        20000000,
        60,
        recent: {55: 15000000},
      );
      expect(
        backgroundCaptureContinued(initial: initial, latest: latest),
        isTrue,
      );
    });

    test('a roll in the background: a newer file that stays empty is not '
        'alive', () {
      final initial = obs('/c/REC1.mp4', 1000, 0, 1000, 40);
      final latest = obs('/c/REC2.mp4', 0, 41, 0, 60, recent: {55: 0});
      expect(
        backgroundCaptureContinued(initial: initial, latest: latest),
        isFalse,
      );
    });

    test('a roll in the background: a newer file that grew and then stopped '
        'is not alive', () {
      final initial = obs('/c/REC1.mp4', 1000, 0, 30000000, 40);
      final latest = obs(
        '/c/REC2.mp4',
        500000,
        41,
        20000000,
        60,
        recent: {for (var s = 50; s < 60; s++) s: 20000000},
      );
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

  group('RecordingFileObservation', () {
    final t0 = DateTime(2026, 1, 1, 12);
    final modified = DateTime(2026, 1, 1, 12);

    RecordingFileSample sample(String path, int size) =>
        RecordingFileSample(path: path, sizeBytes: size, modified: modified);

    test('keeps only the probes of the recent lookback', () {
      var observation = RecordingFileObservation.first(
        sample('/c/REC1.mp4', 0),
        t0,
      );
      for (var s = 1; s <= 30; s++) {
        observation = observation.extendedWith(
          sample('/c/REC1.mp4', s * 1000),
          t0.add(Duration(seconds: s)),
        );
      }
      expect(observation.firstSizeBytes, 0);
      expect(
        observation.recentPoints.first.at,
        observation.latestSeenAt.subtract(backgroundCaptureRecentLookback),
      );
      expect(observation.recentPoints.last.sizeBytes, 30000);
      expect(
        observation.recentPoints,
        hasLength(backgroundCaptureRecentLookback.inSeconds + 1),
      );
    });

    test('a sample of another file starts over', () {
      final observation =
          RecordingFileObservation.first(
            sample('/c/REC1.mp4', 5),
            t0,
          ).extendedWith(
            sample('/c/REC2.mp4', 7),
            t0.add(const Duration(seconds: 1)),
          );
      expect(observation.path, '/c/REC2.mp4');
      expect(observation.firstSizeBytes, 7);
      expect(observation.recentPoints, hasLength(1));
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

    /// Runs one background period of [seconds] s with a probe each second,
    /// as the 1 s timer does, the file being [fileAt] at each second.
    Future<bool> runTicks(
      int seconds,
      RecordingFileSample Function(int second) fileAt,
    ) async {
      var second = 0;
      final monitor = BackgroundCaptureMonitor(
        probe: () async => fileAt(second),
      );
      await monitor.start(t0);
      expect(monitor.isObserving, isTrue);
      for (second = 1; second < seconds; second++) {
        await monitor.sample(t0.add(Duration(seconds: second)));
      }
      final continued = await monitor.finish(
        t0.add(Duration(seconds: seconds)),
      );
      expect(monitor.isObserving, isFalse);
      return continued;
    }

    test('alive: the same file grew through the background period', () async {
      final continued = await runTicks(
        60,
        (s) => sample('/c/REC1.mp4', 1000 + s * 1000000),
      );
      expect(continued, isTrue);
    });

    test('stalled late: the file grew early, then stayed flat', () async {
      final continued = await runTicks(
        240,
        (s) => sample('/c/REC1.mp4', math.min(s, 180) * 1000000),
      );
      expect(continued, isFalse);
    });

    test('roll during the background: a newer file that grows through the '
        'return is alive', () async {
      final continued = await runTicks(
        60,
        (s) => s < 35
            ? sample('/c/REC1.mp4', s * 1000000)
            : sample('/c/REC2.mp4', (s - 35) * 1000000),
      );
      expect(continued, isTrue);
    });

    test('no ticks while away: the result is unknown', () async {
      final monitor = BackgroundCaptureMonitor(
        probe: probeOf([
          sample('/c/REC1.mp4', 1000),
          sample('/c/REC1.mp4', 60000000),
        ]),
      );
      await monitor.start(t0);
      expect(
        await monitor.finish(t0.add(const Duration(seconds: 60))),
        isFalse,
      );
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

    test('roll during the background: a newer file that stays empty is not '
        'alive', () async {
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
      // A short period: the first probe also starts the recent span.
      final result = monitor.finish(t0.add(const Duration(seconds: 8)));
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

  group('cameraPreviewMode', () {
    CameraPreviewMode mode({
      bool ready = false,
      CameraInitState state = CameraInitState.idle,
      bool attempted = false,
      bool busy = false,
    }) {
      return cameraPreviewMode(
        cameraReady: ready,
        initState: state,
        initAttempted: attempted,
        setupBusy: busy,
      );
    }

    test('shows the preview when the camera is ready', () {
      expect(
        mode(ready: true, state: CameraInitState.ready),
        CameraPreviewMode.preview,
      );
    });

    test('shows a spinner while initializing or busy', () {
      expect(
        mode(state: CameraInitState.initializing, attempted: true),
        CameraPreviewMode.loading,
      );
      expect(
        mode(state: CameraInitState.failed, attempted: true, busy: true),
        CameraPreviewMode.loading,
      );
    });

    test('shows a spinner before the first attempt', () {
      expect(mode(), CameraPreviewMode.loading);
    });

    test('a failed init is never a spinner once nothing is running', () {
      expect(mode(state: CameraInitState.failed), CameraPreviewMode.failed);
      expect(
        mode(state: CameraInitState.failed, attempted: true),
        CameraPreviewMode.failed,
      );
    });

    test('an attempted init that left the camera idle shows the panel', () {
      expect(mode(attempted: true), CameraPreviewMode.failed);
    });
  });

  group('cameraInitPanelFor', () {
    CameraInitPanel panel(CameraInitFailureReason reason, {String? detail}) {
      return cameraInitPanelFor(CameraInitFailure(reason, detail: detail));
    }

    test('camera permission offers Open Settings', () {
      for (final reason in [
        CameraInitFailureReason.cameraPermissionDenied,
        CameraInitFailureReason.cameraPermissionPermanentlyDenied,
      ]) {
        final result = panel(reason);
        expect(result.title, 'Camera permission needed');
        expect(result.showOpenSettings, isTrue);
      }
    });

    test('microphone denial offers both actions', () {
      for (final reason in [
        CameraInitFailureReason.microphonePermissionDenied,
        CameraInitFailureReason.microphonePermissionPermanentlyDenied,
      ]) {
        final result = panel(reason);
        expect(result.title, 'Microphone denied: grant it or turn off audio');
        expect(result.showRetry, isTrue);
        expect(result.showOpenSettings, isTrue);
      }
    });

    test('camera unavailable only offers Retry', () {
      final result = panel(CameraInitFailureReason.cameraUnavailable);
      expect(result.title, 'Camera unavailable');
      expect(result.showRetry, isTrue);
      expect(result.showOpenSettings, isFalse);
    });

    test('no camera and storage failures have their own messages', () {
      expect(panel(CameraInitFailureReason.noCamera).title, 'No camera found');
      final storage = panel(CameraInitFailureReason.storageUnavailable);
      expect(storage.title, 'Recording storage unavailable');
      expect(storage.showRetry, isTrue);
      expect(storage.showOpenSettings, isFalse);
    });

    test('location permission offers both actions', () {
      final result = panel(CameraInitFailureReason.locationPermissionDenied);
      expect(result.title, 'Location permission needed');
      expect(result.showRetry, isTrue);
      expect(result.showOpenSettings, isTrue);
    });

    test('an unknown error shows its text', () {
      final result = panel(
        CameraInitFailureReason.unknown,
        detail: 'boom happened',
      );
      expect(result.title, 'Camera error');
      expect(result.message, contains('boom happened'));
      expect(result.showRetry, isTrue);
    });

    test('an unknown error without text still explains', () {
      expect(panel(CameraInitFailureReason.unknown).message, isNotEmpty);
    });

    test('no recorded reason gives the generic panel with both actions', () {
      final result = cameraInitPanelFor(null);
      expect(result.title, 'Camera not available');
      expect(result.showRetry, isTrue);
      expect(result.showOpenSettings, isTrue);
    });
  });
}
