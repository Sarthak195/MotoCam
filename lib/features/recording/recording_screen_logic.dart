// lib/features/recording/recording_screen_logic.dart
//
// Pure helpers used by RecordingScreen, kept free of widgets and plugins so
// they can be unit-tested.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../core/utils/format_utils.dart';
import '../camera/providers/camera_init_status.dart';

/// Fill colour of the START RECORDING button (Material blue 700). White text
/// on it reaches 4.6:1 contrast.
const Color recordingStartButtonColor = Color(0xFF1976D2);

/// Fill colour of the STOP RECORDING button (Material red 700). White text
/// on it reaches 4.98:1 contrast.
const Color recordingStopButtonColor = Color(0xFFD32F2F);

/// Label colour used on [recordingStartButtonColor] and
/// [recordingStopButtonColor].
const Color recordingButtonLabelColor = Color(0xFFFFFFFF);

/// WCAG 2.x contrast ratio between two opaque colours (1.0 to 21.0). Only
/// tests use it, to check the button label colours.
@visibleForTesting
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

/// What the preview area shows.
enum CameraPreviewMode {
  /// The live camera preview.
  preview,

  /// A spinner: an initialization is pending or running.
  loading,

  /// The camera-unavailable panel with the failure reason.
  failed,
}

/// Decides what the preview area shows.
///
/// The failure panel replaces the spinner as soon as an initialization has
/// failed or finished without a camera, so a failed init never looks like
/// loading. [setupBusy] covers the bootstrap, a history round trip, a
/// recording in progress and a camera initialization still running.
CameraPreviewMode cameraPreviewMode({
  required bool cameraReady,
  required CameraInitState initState,
  required bool initAttempted,
  required bool setupBusy,
}) {
  if (cameraReady) {
    return CameraPreviewMode.preview;
  }
  if (setupBusy || initState == CameraInitState.initializing) {
    return CameraPreviewMode.loading;
  }
  if (initState == CameraInitState.failed || initAttempted) {
    return CameraPreviewMode.failed;
  }
  return CameraPreviewMode.loading;
}

/// Text and actions of the camera-unavailable panel.
class CameraInitPanel {
  /// Creates a panel description.
  const CameraInitPanel({
    required this.title,
    required this.message,
    required this.showRetry,
    required this.showOpenSettings,
  });

  /// Headline.
  final String title;

  /// Explanation and what to do.
  final String message;

  /// Whether the Retry button is shown.
  final bool showRetry;

  /// Whether the Open Settings button is shown.
  final bool showOpenSettings;
}

/// The panel for [failure]; `null` (a failed or finished init with no
/// recorded reason) gives a generic one.
CameraInitPanel cameraInitPanelFor(CameraInitFailure? failure) {
  switch (failure?.reason) {
    case CameraInitFailureReason.cameraPermissionDenied:
      return const CameraInitPanel(
        title: 'Camera permission needed',
        message: 'MotoCam needs the camera to record. Allow it, then retry.',
        showRetry: true,
        showOpenSettings: true,
      );
    case CameraInitFailureReason.cameraPermissionPermanentlyDenied:
      return const CameraInitPanel(
        title: 'Camera permission needed',
        message:
            'The camera permission is blocked. Enable it in the app settings, '
            'then retry.',
        showRetry: true,
        showOpenSettings: true,
      );
    case CameraInitFailureReason.microphonePermissionDenied:
    case CameraInitFailureReason.microphonePermissionPermanentlyDenied:
      return const CameraInitPanel(
        title: 'Microphone denied: grant it or turn off audio',
        message:
            'Audio recording is on. Allow the microphone in the app settings, '
            'or turn audio off in the recording settings, then retry.',
        showRetry: true,
        showOpenSettings: true,
      );
    case CameraInitFailureReason.locationPermissionDenied:
      return const CameraInitPanel(
        title: 'Location permission needed',
        message:
            'Recording needs location for speed and route telemetry. Allow '
            'it, then retry.',
        showRetry: true,
        showOpenSettings: true,
      );
    case CameraInitFailureReason.noCamera:
      return const CameraInitPanel(
        title: 'No camera found',
        message: 'This device reported no camera. Retry in a moment.',
        showRetry: true,
        showOpenSettings: false,
      );
    case CameraInitFailureReason.cameraUnavailable:
      return const CameraInitPanel(
        title: 'Camera unavailable',
        message: 'Another app may be using the camera. Close it, then retry.',
        showRetry: true,
        showOpenSettings: false,
      );
    case CameraInitFailureReason.storageUnavailable:
      return const CameraInitPanel(
        title: 'Recording storage unavailable',
        message:
            'MotoCam cannot use its recordings folder. Free up storage or '
            'check the storage permission, then retry.',
        showRetry: true,
        showOpenSettings: false,
      );
    case CameraInitFailureReason.unknown:
      final detail = failure?.detail?.trim() ?? '';
      return CameraInitPanel(
        title: 'Camera error',
        message: detail.isEmpty
            ? 'The camera could not be started. Retry.'
            : 'The camera could not be started: $detail',
        showRetry: true,
        showOpenSettings: false,
      );
    case null:
      return const CameraInitPanel(
        title: 'Camera not available',
        message:
            'Allow camera access (and microphone while audio recording is '
            'on), or close other apps using the camera, then retry.',
        showRetry: true,
        showOpenSettings: true,
      );
  }
}

/// Whether Blackout ends when the app moves to [state].
///
/// Blackout is only a black overlay drawn by Flutter (the camera keeps its
/// Preview use case bound), so leaving it costs no video. It survives
/// `inactive` (the notification shade, the start of a power press, and
/// Picture-in-Picture, whose window draws its own REC view instead of the
/// overlay; Home or Recents while recording normally enters PiP). It ends at
/// `hidden` or `paused` (screen off, or another app in front when PiP is
/// refused or its window is dismissed), so the rider comes back to the live
/// preview and can see that the camera still records.
bool leavesBlackoutOnLifecycle(AppLifecycleState state) {
  return state == AppLifecycleState.hidden || state == AppLifecycleState.paused;
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

/// Minimum growth, in bytes per second spent in the background, that
/// counts as evidence that capture continued. Far below any video bitrate
/// the camera uses, so a file that kept recording always passes.
const int backgroundCaptureMinBytesPerSecond = 16 * 1024;

/// Extra growth the in-progress file must show on top of
/// [backgroundCaptureMinBytesPerSecond], for the encoder output still
/// written just after the app left the foreground when capture stopped
/// there.
const int backgroundCaptureStallAllowanceBytes = 256 * 1024;

/// Shortest observation of a file that appeared while the app was in the
/// background (a segment roll) that can count as evidence.
const Duration backgroundCaptureMinNewFileWindow = Duration(seconds: 2);

/// Shortest span, ending at the final probe, over which the in-progress
/// file must still be growing. Several seconds long because the MP4 writer
/// writes in bursts.
const Duration backgroundCaptureRecentWindow = Duration(seconds: 5);

/// Oldest sample, counted back from the final probe, that can start the
/// recent-growth span. Older samples are dropped, so a span that would
/// reach back to the start of a long background period never counts.
const Duration backgroundCaptureRecentLookback = Duration(seconds: 10);

/// Size of the observed file at one probe.
typedef RecordingFileSizePoint = ({DateTime at, int sizeBytes});

/// One probe of the newest in-progress recording file.
@immutable
class RecordingFileSample {
  /// Creates a sample of the file at [path].
  const RecordingFileSample({
    required this.path,
    required this.sizeBytes,
    required this.modified,
  });

  /// Absolute path of the file.
  final String path;

  /// Size in bytes when probed.
  final int sizeBytes;

  /// Last modification time when probed.
  final DateTime modified;
}

/// Returns the newest (by modification time) `REC*.mp4` file directly in
/// [directory], or `null` when there is none.
///
/// camera_android_camerax writes the clip being recorded to a `REC*.mp4`
/// temporary file in the app's cache directory, which is what
/// `getTemporaryDirectory()` returns on Android. Throws when the directory
/// cannot be listed.
Future<RecordingFileSample?> newestRecordingFileIn(Directory directory) async {
  RecordingFileSample? newest;
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    final name = entity.uri.pathSegments.last;
    if (!name.startsWith('REC') || !name.toLowerCase().endsWith('.mp4')) {
      continue;
    }
    final stat = await entity.stat();
    if (stat.type != FileSystemEntityType.file) {
      continue;
    }
    if (newest == null || stat.modified.isAfter(newest.modified)) {
      newest = RecordingFileSample(
        path: entity.path,
        sizeBytes: stat.size,
        modified: stat.modified,
      );
    }
  }
  return newest;
}

/// How one in-progress recording file grew while it was observed.
@immutable
class RecordingFileObservation {
  /// Creates an observation of [path] that started with [firstSizeBytes] at
  /// [firstSeenAt] and was last seen with [latestSizeBytes] at
  /// [latestSeenAt]. [recentPoints] are the probes of the last
  /// [backgroundCaptureRecentLookback], oldest first.
  const RecordingFileObservation({
    required this.path,
    required this.firstSizeBytes,
    required this.firstSeenAt,
    required this.latestSizeBytes,
    required this.latestSeenAt,
    this.recentPoints = const <RecordingFileSizePoint>[],
  });

  /// Starts an observation from a single sample taken at [at].
  factory RecordingFileObservation.first(
    RecordingFileSample sample,
    DateTime at,
  ) {
    return RecordingFileObservation(
      path: sample.path,
      firstSizeBytes: sample.sizeBytes,
      firstSeenAt: at,
      latestSizeBytes: sample.sizeBytes,
      latestSeenAt: at,
      recentPoints: List<RecordingFileSizePoint>.unmodifiable(
        <RecordingFileSizePoint>[(at: at, sizeBytes: sample.sizeBytes)],
      ),
    );
  }

  /// Absolute path of the file.
  final String path;

  /// Size when the file was first seen.
  final int firstSizeBytes;

  /// When the file was first seen.
  final DateTime firstSeenAt;

  /// Size at the latest probe.
  final int latestSizeBytes;

  /// When the latest probe was taken.
  final DateTime latestSeenAt;

  /// Probes taken at most [backgroundCaptureRecentLookback] before
  /// [latestSeenAt], oldest first, including the latest one.
  final List<RecordingFileSizePoint> recentPoints;

  /// This observation extended by [sample] taken at [at]; a sample of
  /// another file starts a new observation.
  RecordingFileObservation extendedWith(
    RecordingFileSample sample,
    DateTime at,
  ) {
    if (sample.path != path) {
      return RecordingFileObservation.first(sample, at);
    }
    final oldest = at.subtract(backgroundCaptureRecentLookback);
    return RecordingFileObservation(
      path: path,
      firstSizeBytes: firstSizeBytes,
      firstSeenAt: firstSeenAt,
      latestSizeBytes: sample.sizeBytes,
      latestSeenAt: at,
      recentPoints:
          List<RecordingFileSizePoint>.unmodifiable(<RecordingFileSizePoint>[
            ...recentPoints.where((point) => !point.at.isBefore(oldest)),
            (at: at, sizeBytes: sample.sizeBytes),
          ]),
    );
  }
}

/// Whether there is positive evidence that video capture continued while
/// the app was in the background.
///
/// [initial] is the newest in-progress recording file when the app left the
/// foreground and [latest] the newest one at the return, each with the
/// growth seen while it was observed. The answer is `true` only when:
/// - [latest] is the same file as [initial] and it grew by at least
///   [minBytesPerSecond] per second observed plus [stallAllowanceBytes], or
/// - [latest] is a newer file (a segment roll in the background) that was
///   observed for at least [minNewFileWindow] and grew by at least
///   [minBytesPerSecond] per second in that time,
///
/// and, in both cases, [latest] was still growing just before the return:
/// from its newest probe taken between [minRecentWindow] and
/// [maxRecentWindow] before the final probe, it grew by at least
/// [minBytesPerSecond] per second. This catches a capture that stopped
/// partway through the background period, whose total growth can still
/// pass. A stall shorter than that span before the return is not caught.
///
/// Anything else (no file, a probe that failed, too little growth, no
/// probe in the recent span) returns `false`, and the caller keeps the
/// default stall recovery. Probes older than
/// [backgroundCaptureRecentLookback] are not kept, so a [maxRecentWindow]
/// longer than that finds nothing older.
bool backgroundCaptureContinued({
  required RecordingFileObservation? initial,
  required RecordingFileObservation? latest,
  int minBytesPerSecond = backgroundCaptureMinBytesPerSecond,
  int stallAllowanceBytes = backgroundCaptureStallAllowanceBytes,
  Duration minNewFileWindow = backgroundCaptureMinNewFileWindow,
  Duration minRecentWindow = backgroundCaptureRecentWindow,
  Duration maxRecentWindow = backgroundCaptureRecentLookback,
}) {
  if (initial == null || latest == null) {
    return false;
  }
  int requiredBytes(Duration window) =>
      (minBytesPerSecond * window.inMilliseconds) ~/ 1000;

  bool grewRecently() {
    RecordingFileSizePoint? reference;
    for (final point in latest.recentPoints) {
      final age = latest.latestSeenAt.difference(point.at);
      if (age >= minRecentWindow && age <= maxRecentWindow) {
        reference = point;
      }
    }
    if (reference == null) {
      return false;
    }
    final window = latest.latestSeenAt.difference(reference.at);
    return latest.latestSizeBytes - reference.sizeBytes >=
        requiredBytes(window);
  }

  if (latest.path == initial.path) {
    final window = latest.latestSeenAt.difference(initial.firstSeenAt);
    if (window <= Duration.zero) {
      return false;
    }
    final growth = latest.latestSizeBytes - initial.firstSizeBytes;
    return growth >= requiredBytes(window) + stallAllowanceBytes &&
        grewRecently();
  }

  final window = latest.latestSeenAt.difference(latest.firstSeenAt);
  if (window < minNewFileWindow) {
    return false;
  }
  final growth = latest.latestSizeBytes - latest.firstSizeBytes;
  return growth >= requiredBytes(window) && grewRecently();
}

/// Watches the in-progress recording file while the app is in the
/// background, to tell on return whether capture continued (see
/// [backgroundCaptureContinued]).
///
/// [probe] returns the newest in-progress recording file; it is injected so
/// tests need no camera. Probes run one at a time, in call order. A probe
/// that throws or finds no file makes the result `false` (unknown).
class BackgroundCaptureMonitor {
  /// Creates a monitor that samples files with [probe].
  BackgroundCaptureMonitor({required this.probe});

  /// Returns the newest in-progress recording file, or `null`.
  final Future<RecordingFileSample?> Function() probe;

  RecordingFileObservation? _initial;
  RecordingFileObservation? _latest;
  bool _failed = false;
  bool _observing = false;
  int _generation = 0;
  Future<void> _queue = Future<void>.value();

  /// Whether a background period is being observed.
  bool get isObserving => _observing;

  /// Starts observing a background period that began at [now] and takes
  /// the first sample. Any earlier observation is dropped.
  Future<void> start(DateTime now) {
    reset();
    _observing = true;
    return _enqueueSample(now, isInitial: true);
  }

  /// Takes one more sample at [now] while observing; otherwise does
  /// nothing.
  Future<void> sample(DateTime now) {
    if (!_observing) {
      return Future<void>.value();
    }
    return _enqueueSample(now);
  }

  /// Takes the final sample at [now], ends the observation and returns
  /// whether capture continued. `false` when nothing was being observed.
  Future<bool> finish(DateTime now) async {
    if (!_observing) {
      return false;
    }
    final generation = _generation;
    await _enqueueSample(now);
    if (generation != _generation) {
      return false;
    }
    final continued =
        !_failed &&
        backgroundCaptureContinued(initial: _initial, latest: _latest);
    reset();
    return continued;
  }

  /// Ends any observation; samples still running are ignored.
  void reset() {
    _generation++;
    _observing = false;
    _initial = null;
    _latest = null;
    _failed = false;
  }

  Future<void> _enqueueSample(DateTime now, {bool isInitial = false}) {
    final generation = _generation;
    final next = _queue.then((_) => _takeSample(generation, now, isInitial));
    _queue = next;
    return next;
  }

  Future<void> _takeSample(int generation, DateTime now, bool isInitial) async {
    RecordingFileSample? sample;
    try {
      sample = await probe();
    } catch (_) {
      sample = null;
    }
    if (generation != _generation) {
      return;
    }
    if (sample == null) {
      _failed = true;
      return;
    }
    final latest = _latest;
    _latest = latest == null
        ? RecordingFileObservation.first(sample, now)
        : latest.extendedWith(sample, now);
    if (isInitial) {
      _initial = _latest;
    }
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
