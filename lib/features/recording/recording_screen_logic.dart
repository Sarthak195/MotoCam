// lib/features/recording/recording_screen_logic.dart
//
// Pure helpers used by RecordingScreen, kept free of widgets and plugins so
// they can be unit-tested.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../core/utils/format_utils.dart';

/// Fill colour of the START RECORDING button (Material blue 700). White text
/// on it reaches 4.6:1 contrast.
const Color recordingStartButtonColor = Color(0xFF1976D2);

/// Fill colour of the STOP RECORDING button (Material red 700). White text
/// on it reaches 4.98:1 contrast.
const Color recordingStopButtonColor = Color(0xFFD32F2F);

/// Label colour used on [recordingStartButtonColor] and
/// [recordingStopButtonColor].
const Color recordingButtonLabelColor = Color(0xFFFFFFFF);

/// WCAG 2.x contrast ratio between two opaque colours (1.0 to 21.0).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Formats a recording duration as `HH:MM:SS`.
String formatRecordingElapsed(Duration duration) => formatElapsed(duration);

/// Notice shown after an incident lock that says what was protected.
///
/// [registeredSegments] is the number of segments of the session that were
/// already saved when the lock was made; at most [protectPastSegments] of
/// them are locked, plus the clip being recorded.
String incidentLockNotice({
  required int registeredSegments,
  int protectPastSegments = 2,
  bool automatic = false,
}) {
  final previous = math.min(
    math.max(registeredSegments, 0),
    math.max(protectPastSegments, 0),
  );
  final prefix = automatic ? 'Incident detected. Locked' : 'Locked';
  if (previous == 0) {
    return '$prefix: current clip';
  }
  return '$prefix: current clip + $previous previous';
}

/// Decides when a recording should attempt stall recovery after the app
/// returns to the foreground.
///
/// Only time spent hidden or paused (screen off, app in the background)
/// counts. Inactive periods (Picture-in-Picture, the notification shade,
/// system dialogs) do not, and the first hidden/paused transition is kept,
/// so the hidden and inactive states Flutter synthesizes on the way back to
/// resumed do not reset the timestamp.
class BackgroundStallTracker {
  /// Creates a tracker that reports background periods of at least
  /// [threshold].
  BackgroundStallTracker({this.threshold = const Duration(seconds: 8)});

  /// Minimum hidden/paused time that warrants a recovery attempt.
  final Duration threshold;

  DateTime? _backgroundedAt;

  /// When the current hidden/paused period started, or `null`.
  DateTime? get backgroundedAt => _backgroundedAt;

  /// Feeds a lifecycle change. Returns the time spent in the background
  /// when [state] is resumed, a recording is active and that time reached
  /// [threshold]; otherwise `null`.
  Duration? onLifecycleChanged(
    AppLifecycleState state, {
    required bool isRecording,
    required DateTime now,
  }) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (isRecording) {
          _backgroundedAt ??= now;
        }
        return null;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        return null;
      case AppLifecycleState.resumed:
        final since = _backgroundedAt;
        _backgroundedAt = null;
        if (since == null || !isRecording) {
          return null;
        }
        final duration = now.difference(since);
        return duration >= threshold ? duration : null;
    }
  }

  /// Forgets any pending background period.
  void reset() {
    _backgroundedAt = null;
  }
}

/// Decides when the active ride needs a new checkpoint: whenever the
/// session's segment list or its lock count changed since the last one.
///
/// Once the loop is full, a segment roll adds one segment and evicts another,
/// so the list keeps its length; its newest path still changes.
class RideCheckpointTracker {
  int _segmentCount = 0;
  String? _newestSegmentPath;
  int _lockedCount = 0;

  /// Returns `true`, and remembers the new state, when [segmentPaths] is not
  /// empty and it or [lockedCount] differs from the last accepted state.
  bool shouldCheckpoint(List<String> segmentPaths, int lockedCount) {
    if (segmentPaths.isEmpty ||
        (segmentPaths.length == _segmentCount &&
            segmentPaths.last == _newestSegmentPath &&
            lockedCount == _lockedCount)) {
      return false;
    }
    _segmentCount = segmentPaths.length;
    _newestSegmentPath = segmentPaths.last;
    _lockedCount = lockedCount;
    return true;
  }

  /// Forgets the last checkpointed state, for a new ride.
  void reset() {
    _segmentCount = 0;
    _newestSegmentPath = null;
    _lockedCount = 0;
  }
}
