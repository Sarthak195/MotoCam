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
}
