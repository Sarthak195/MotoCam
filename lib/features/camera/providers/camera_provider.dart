// lib/features/camera/providers/camera_provider.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import '../../../core/ride_file/ride_telemetry_codec.dart' as ride_codec;
import '../../../core/services/app_permission_service.dart';
import '../../../core/services/gallery_copies.dart';
import '../../../core/utils/integrity_utils.dart' as integrity_utils;
import '../../../core/utils/path_utils.dart' as path_utils;
import 'camera_init_status.dart';
import 'gallery_export.dart';
import 'recording_retention.dart';
import 'recordings_migration.dart';
import 'segment_roll_binding.dart';
import 'storage_budget.dart';
import '../../history/models/ride_index.dart';
import '../../history/models/ride_record.dart';
import '../../history/services/gallery_links.dart';
import '../../history/services/legacy_ride_import.dart';
import '../../history/services/ride_deletion.dart';
import '../../../core/services/legacy_recordings_access.dart';
import 'dart:io';
import 'dart:async';
import 'dart:isolate';

/// Lifecycle state of the segmented recording session.
enum RecordingState {
  /// No session has run yet, the last start was refused (low storage or the
  /// camera did not start), or [CameraProvider.releaseCameraIfIdle] released
  /// the camera.
  idle,

  /// A session is running (also while it is in a recording fault, see
  /// [CameraProvider.lastRecordingError]).
  recording,

  /// [CameraProvider.stopRecording] ended the session.
  stopped,
}

/// One recorded segment's position on the ride timeline.
///
/// [startMs] and [endMs] are milliseconds since the ride's recording start
/// ([CameraProvider.recordingStartedAt]): [startMs] is when the segment's
/// recording started and [endMs] is when it stopped.
class SegmentTimelineEntry {
  /// Creates a timeline entry for the segment stored at [path].
  const SegmentTimelineEntry({
    required this.path,
    required this.startMs,
    required this.endMs,
  });

  /// Absolute path of the persisted segment file.
  final String path;

  /// Segment start, in milliseconds since the ride's recording start.
  final int startMs;

  /// Segment end, in milliseconds since the ride's recording start.
  final int endMs;

  /// Serialises the entry as stored in the ride's telemetry sidecar.
  Map<String, dynamic> toJson() => {
    'path': path,
    'startMs': startMs,
    'endMs': endMs,
  };
}

/// Manages the device camera lifecycle, segmented video recording, rolling
/// retention, gallery export, and resolution/FPS fallback negotiation.
///
/// This provider is intended to be instantiated once via
/// `ChangeNotifierProvider` at the root of the widget tree. It exposes the
/// active [CameraController], recording state, and session segment metadata
/// to the UI layer.
///
/// Rolling retention applies only to the current session's unlocked
/// segments: locked segments and earlier rides' videos are never deleted
/// automatically. After a stop, telemetry sidecars of unlocked rides whose
/// videos are all gone are deleted.
class CameraProvider extends ChangeNotifier {
  /// Creates the provider; [enableDebugLogging] turns on verbose
  /// `[MotoCam]` logs (warnings and errors are always logged).
  CameraProvider({this.enableDebugLogging = false});

  /// Native media channel (Android) used for gallery export and free-space
  /// queries.
  static const platform = MethodChannel('com.example.motocam/media');
  static const String _galleryRelativePath =
      ride_codec.publicExportRelativePath;
  static const String _recordingsDirectoryName = 'MotoCam Recordings';

  /// Directory next to the recordings root (never inside a scanned root)
  /// that holds the migration journal and staging copies.
  static const String _migrationDirectoryName = 'ride_migration';

  /// Directory next to the recordings root that holds the legacy-folder
  /// import's journal and staging copies.
  static const String _importDirectoryName = 'ride_import';
  static const Duration _rollWaitTimeout = Duration(seconds: 60);

  CameraController? _controller;
  RecordingState _state = RecordingState.idle;
  String? _currentVideoPath;
  bool _isInitialized = false;
  CameraInitState _initState = CameraInitState.idle;
  CameraInitFailure? _initFailure;
  String? _recordingsDirectory;

  /// Whether verbose `[MotoCam]` logs (timings, state) are printed.
  bool enableDebugLogging;

  /// Whether locked segments are copied to the shared gallery
  /// (`Movies/MotoCam/Recordings`, Android only) when a ride stops.
  ///
  /// Defaults to `false`: exported copies are public to every gallery app
  /// and survive an uninstall, so export is opt-in. The queue and the
  /// copies' content URIs are kept in the [GalleryLinkStore], so a queue
  /// left by a killed process is retried at the next launch and Ride
  /// History can offer to remove the copies.
  bool autoExportLockedClipsToGallery = false;

  /// Storage budget for all recordings in bytes; 0 (the default) is off.
  ///
  /// Set from the `recordings_storage_budget_gb` setting at every START.
  /// While recording, shortly after START and after each segment roll, the
  /// oldest unlocked rides are deleted (whole rides, through the shared ride
  /// deletion routine) until the recordings root fits; see
  /// [selectRidesForStorageBudget] for what is never deleted.
  int storageBudgetBytes = 0;

  /// Returns the `rideSessionId` of the ride being recorded (the telemetry
  /// provider's), so the storage budget never deletes it. Set by the
  /// recording screen. While it returns `null` during a recording, the
  /// budget is not enforced.
  String? Function()? currentRideSessionIdSource;

  ResolutionPreset _resolutionPreset = ResolutionPreset.medium;
  int _recordingFps = 30;
  int _videoBitrateBps = 8 * 1000 * 1000;
  bool _audioEnabled = true;
  String _preferredCameraName = '';
  String _activeCameraName = '';
  final List<CameraDescription> _availableCameras = <CameraDescription>[];
  Duration _segmentDuration = const Duration(minutes: 5);
  int _maxRollingSegments = 24;
  final Map<String, List<int>> _supportedFpsCache = {};
  final Map<String, Set<ResolutionPreset>> _unsupportedResolutionCache = {};
  final List<String> _sessionSegmentPaths = <String>[];
  final List<SegmentTimelineEntry> _sessionSegmentTimeline =
      <SegmentTimelineEntry>[];
  final Set<String> _lockedSegmentPaths = <String>{};
  Timer? _segmentTimer;
  Timer? _deferredMaintenanceTimer;
  Future<void>? _initInFlight;
  Future<void>? _rollInFlight;
  bool _isStartingRecording = false;
  bool _isStoppingRecording = false;
  Future<GalleryExporter?>? _galleryExporterFuture;
  bool _hasResumedGalleryExports = false;
  bool _isDeferredMaintenanceRunning = false;
  bool _hasPrunedTelemetryTempFiles = false;
  final RecordingsMigrationController _recordingsMigration =
      RecordingsMigrationController();
  final LegacyRideImportController _legacyRideImport =
      LegacyRideImportController();
  Timer? _storageBudgetTimer;
  bool _isStorageBudgetRunning = false;
  int _sessionBudgetDeletedRides = 0;
  int _sessionBudgetDeletedBytes = 0;
  int _sessionBudgetFailedFiles = 0;
  bool _sessionBudgetUnattainable = false;
  bool _sessionBudgetNoticeShown = false;
  String? _lastStorageBudgetMessage;
  String? _lastGalleryExportMessage;
  String? _lastRecordingError;
  int _consecutiveRollStopFailures = 0;
  bool _isDisposed = false;

  /// Sequence number of the segment currently being recorded (1-based per
  /// session; 0 before the first segment starts).
  int _activeSegmentSequence = 0;

  /// Highest segment sequence whose registration has finished.
  int _lastSettledSegmentSequence = 0;

  /// Segment sequences an incident asked to lock once they are registered.
  final Set<int> _pendingLockSequences = <int>{};

  /// Ride-timeline start of the segment currently being recorded.
  int _currentSegmentStartMs = 0;

  static const List<int> _fpsCandidates = [24, 30, 60];
  static const List<int> _safeResolutionOptions = [480, 720, 1080, 2160];
  static const List<ResolutionPreset> _resolutionFallbackOrder = [
    ResolutionPreset.ultraHigh,
    ResolutionPreset.veryHigh,
    ResolutionPreset.high,
    ResolutionPreset.medium,
    ResolutionPreset.low,
  ];

  // Recording timer
  DateTime? _recordingStartTime;
  Duration _elapsedTime = Duration.zero;
  Timer? _timerStream;
  final _timerController = StreamController<Duration>.broadcast();

  // Getters

  /// The active camera controller, or `null` while uninitialized.
  CameraController? get controller => _controller;

  /// Whether a camera controller is initialized and ready.
  bool get isInitialized => _isInitialized;

  /// Whether a camera initialization is in progress.
  bool get isInitializing => _initInFlight != null;

  /// Phase of the camera initialization: [CameraInitState.ready] exactly
  /// while [isInitialized] is true, [CameraInitState.failed] after a failed
  /// attempt (see [initFailure]), [CameraInitState.initializing] while one
  /// runs and [CameraInitState.idle] otherwise.
  CameraInitState get initState => _initState;

  /// Why the last initialization failed; non-null exactly while [initState]
  /// is [CameraInitState.failed].
  CameraInitFailure? get initFailure => _initFailure;

  /// Whether a recording session is active.
  bool get isRecording => _state == RecordingState.recording;

  /// Whether [startRecording] is in progress.
  bool get isStartingRecording => _isStartingRecording;

  /// Whether [stopRecording] is in progress (camera stop and final segment
  /// registration).
  bool get isStoppingRecording => _isStoppingRecording;

  /// Rider-facing description of the last recording failure, or `null`.
  ///
  /// Set when [startRecording] refuses to start because storage is almost
  /// full, and when recording could not continue after a segment roll or a
  /// pipeline recovery (restart failure, a segment stop that failed twice or
  /// left the camera not recording, or low storage). In the second case
  /// nothing is recorded from then on, although [isRecording] stays `true`
  /// until [stopRecording] is called, so the session's segments, locks and
  /// timeline can still be saved. Cleared by the next [startRecording].
  String? get lastRecordingError => _lastRecordingError;

  /// Rider-facing result of the last gallery export of locked clips (see
  /// [autoExportLockedClipsToGallery]), e.g. how many clips were copied or
  /// that storage permission was denied; `null` until an export ran.
  /// Listeners are notified when it changes.
  String? get lastGalleryExportMessage => _lastGalleryExportMessage;

  /// Directory that holds this app's segments and telemetry sidecars.
  String? get recordingsDirectory => _recordingsDirectory;

  /// The storage budget's notice for the current or last recording
  /// session, for example 'Storage budget: deleted 2 oldest unlocked rides
  /// (3.1 GB).'; at most one per session, `null` until the budget deleted
  /// something or found it cannot be met. A new String is built for each
  /// notice, so identity tells a new one from one already shown. Listeners
  /// are notified when it is set.
  String? get lastStorageBudgetMessage => _lastStorageBudgetMessage;

  /// Whether the storage budget is scanning or deleting rides now; Ride
  /// History holds its delete and unlock actions meanwhile.
  bool get isStorageBudgetRunning => _isStorageBudgetRunning;

  /// The move of rides from the legacy roots into [recordingsDirectory]
  /// (Android only): progress, summary and idle signal for the UI.
  RecordingsMigrationController get recordingsMigration => _recordingsMigration;

  /// Whether no recordings migration run is in progress, so no ride file
  /// is being moved. Anything else that moves, imports or deletes rides in
  /// bulk must wait for this (see [whenRecordingsMigrationIdle]).
  bool get isRecordingsMigrationIdle => _recordingsMigration.isIdle;

  /// Completes when no recordings migration run is in progress.
  Future<void> whenRecordingsMigrationIdle() => _recordingsMigration.whenIdle();

  /// The import of rides from the v0.1.11/v0.1.12 public folder (Android
  /// only): progress and idle signal for the UI. Start one with
  /// [importLegacyRides].
  LegacyRideImportController get legacyRideImport => _legacyRideImport;

  /// Why [importLegacyRides] would refuse to start now, as a rider-facing
  /// sentence, or `null` when it may start: it never runs on iOS, while a
  /// recording starts, runs or stops, while rides are moved into private
  /// storage, while the storage budget deletes rides, or while another
  /// import runs.
  String? get legacyImportBlockedReason {
    if (!Platform.isAndroid) {
      return 'Importing rides from an older version is available on Android '
          'only.';
    }
    if (isRecording || _isStartingRecording || _isStoppingRecording) {
      return 'Stop recording before importing rides.';
    }
    if (!_recordingsMigration.isIdle) {
      return 'Rides are being moved to private storage. Try again when the '
          'move finishes.';
    }
    if (_isStorageBudgetRunning) {
      return 'Old rides are being deleted for the storage budget. Try again '
          'in a moment.';
    }
    if (_legacyRideImport.isRunning) {
      return 'An import is already running.';
    }
    return null;
  }

  /// Imports the rides of the picked folder [source] into
  /// [recordingsDirectory] (see [LegacyRideImporter]) and returns the
  /// summary, or `null` when [legacyImportBlockedReason] refuses it or the
  /// recordings directory is unavailable.
  ///
  /// The import pauses (at its next poll, abandoning the copy in flight)
  /// when a recording starts; START never waits for it. While it runs, the
  /// migration and the storage budget do not.
  Future<LegacyImportSummary?> importLegacyRides(
    LegacyRideDocumentSource source,
  ) async {
    if (legacyImportBlockedReason != null) {
      return null;
    }
    if (_recordingsDirectory == null && !await _setupRecordingsDirectory()) {
      return null;
    }
    final root = _recordingsDirectory;
    if (root == null || legacyImportBlockedReason != null) {
      return null;
    }
    final importer = LegacyRideImporter(
      source: source,
      recordingsRoot: root,
      workDirectory:
          '${Directory(root).parent.path}${Platform.pathSeparator}'
          '$_importDirectoryName',
      freeBytes: _availableStorageBytesAt,
      reserveBytes: _estimatedSegmentBytes + _storageMarginBytes,
      shouldPause: () =>
          _isDisposed ||
          isRecording ||
          _isStartingRecording ||
          _isStoppingRecording,
    );
    try {
      return await _legacyRideImport.run(importer);
    } finally {
      _maybeStartRecordingsMigration();
    }
  }

  /// Elapsed time of the active session, updated about once per second.
  /// After [stopRecording] it keeps the finished session's value until the
  /// next [startRecording] or [releaseCameraIfIdle].
  Duration get elapsedTime => _elapsedTime;

  /// Emits [elapsedTime] about once per second while recording.
  Stream<Duration> get timerStream => _timerController.stream;

  /// Wall-clock time at which the active session's first segment started
  /// recording; the zero point of [lastSessionSegmentTimeline]. `null` when
  /// no session is recording.
  DateTime? get recordingStartedAt => _recordingStartTime;

  /// Resolution preset the active controller was initialized with.
  ResolutionPreset get resolutionPreset => _resolutionPreset;

  /// Target recording frame rate.
  int get recordingFps => _recordingFps;

  /// Requested video bitrate in Mbps (rounded).
  int get videoBitrateMbps => (_videoBitrateBps / 1000000).round();

  /// Whether the camera plugin applies the requested bitrate.
  ///
  /// `false` on Android: camera_android_camerax (0.7.1 and the locked 0.7.2)
  /// never passes the bitrate to the CameraX Recorder, which uses its default
  /// for the quality.
  bool get supportsVideoBitrateControl => !Platform.isAndroid;

  /// The bitrate actually applied in Mbps, or `null` when the platform
  /// ignores the requested bitrate (see [supportsVideoBitrateControl]).
  int? get appliedVideoBitrateMbps =>
      supportsVideoBitrateControl ? videoBitrateMbps : null;

  /// Whether audio is recorded with the video.
  bool get audioEnabled => _audioEnabled;

  /// Name of the camera currently in use.
  String get activeCameraName => _activeCameraName;

  /// Segment length in seconds.
  int get segmentDurationSeconds => _segmentDuration.inSeconds;

  /// Number of unlocked segments the rolling loop keeps per session.
  int get maxRollingSegments => _maxRollingSegments;

  /// Segment paths of the current or last session, in recording order.
  List<String> get lastSessionSegmentPaths =>
      List.unmodifiable(_sessionSegmentPaths);

  /// Timeline entries (see [SegmentTimelineEntry.toJson]) of the current or
  /// last session, in recording order.
  List<Map<String, dynamic>> get lastSessionSegmentTimeline =>
      List.unmodifiable(_sessionSegmentTimeline.map((entry) => entry.toJson()));

  /// Locked segment paths of the current or last session, sorted.
  List<String> get lockedSegmentPaths =>
      List.unmodifiable(_lockedSegmentPaths.toList()..sort());

  /// Number of locked segments in the current or last session.
  int get lockedSegmentCount => _lockedSegmentPaths.length;

  /// Whether the segment being recorded is locked: an incident lock is
  /// pending for it, so it is registered as locked when it rolls or the
  /// recording stops. `false` once the recording moves to the next segment
  /// or stops (see [isActiveSegmentLocked] in recording_retention.dart).
  bool get isRecordingSegmentLocked => isActiveSegmentLocked(
    isRecording: isRecording,
    activeSequence: _activeSegmentSequence,
    pendingLockSequences: _pendingLockSequences,
  );

  /// Presets that failed to initialize or record on the active camera.
  Set<ResolutionPreset> get knownUnsupportedResolutionPresets {
    if (_activeCameraName.isEmpty) {
      return const <ResolutionPreset>{};
    }
    final key = _resolutionSupportCacheKey(_activeCameraName);
    return Set.unmodifiable(
      _unsupportedResolutionCache[key] ?? const <ResolutionPreset>{},
    );
  }

  // Verbose (timing, state) logging; only with [enableDebugLogging].
  void _log(String message) {
    if (enableDebugLogging) {
      debugPrint('[MotoCam] $message');
    }
  }

  // Warnings and errors: logged in every build mode. Uses
  // debugPrintSynchronously, which the release-mode debugPrint no-op in
  // main.dart does not silence.
  void _logError(String message) {
    if (enableDebugLogging) {
      debugPrint('[MotoCam] $message');
    } else {
      debugPrintSynchronously('[MotoCam] $message');
    }
  }

  /// Maps a resolution in lines (480, 720, 1080, 2160) to a camera preset.
  ///
  /// 480 maps to [ResolutionPreset.medium] (~480p); [ResolutionPreset.low]
  /// is ~240p on Android and 352x288 on iOS.
  static ResolutionPreset presetForResolution(int resolution) {
    if (resolution <= 480) {
      return ResolutionPreset.medium;
    }
    if (resolution <= 720) {
      return ResolutionPreset.high;
    }
    if (resolution <= 1080) {
      return ResolutionPreset.veryHigh;
    }
    return ResolutionPreset.ultraHigh;
  }

  /// Maps a camera preset back to the resolution in lines shown in the UI.
  static int resolutionForPreset(ResolutionPreset preset) {
    switch (preset) {
      case ResolutionPreset.low:
      case ResolutionPreset.medium:
        return 480;
      case ResolutionPreset.high:
        return 720;
      case ResolutionPreset.veryHigh:
        return 1080;
      case ResolutionPreset.ultraHigh:
      case ResolutionPreset.max:
        return 2160;
    }
  }

  /// Returns the preset for [requestedResolution], or the nearest lower (then
  /// higher) preset when it is known to be unsupported on the active camera.
  ResolutionPreset resolvePresetForRequestedResolution(
    int requestedResolution,
  ) {
    final requestedPreset = presetForResolution(requestedResolution);
    final unsupported = knownUnsupportedResolutionPresets;
    if (!unsupported.contains(requestedPreset)) {
      return requestedPreset;
    }

    final lowerOrEqual =
        _safeResolutionOptions
            .where((resolution) => resolution <= requestedResolution)
            .toList()
          ..sort((a, b) => b.compareTo(a));
    for (final candidateResolution in lowerOrEqual) {
      final preset = presetForResolution(candidateResolution);
      if (!unsupported.contains(preset)) {
        return preset;
      }
    }

    final allCandidates = List<int>.from(_safeResolutionOptions)
      ..sort((a, b) => a.compareTo(b));
    for (final candidateResolution in allCandidates) {
      final preset = presetForResolution(candidateResolution);
      if (!unsupported.contains(preset)) {
        return preset;
      }
    }

    return requestedPreset;
  }

  /// Human-readable label such as `Back (0)` for [camera].
  String cameraLabel(CameraDescription camera) {
    final lens = switch (camera.lensDirection) {
      CameraLensDirection.front => 'Front',
      CameraLensDirection.back => 'Back',
      CameraLensDirection.external => 'External',
    };
    final name = camera.name.trim();
    if (name.isEmpty) {
      return lens;
    }
    return '$lens ($name)';
  }

  /// Returns the device cameras, querying the plugin on first use or when
  /// [refresh] is set.
  Future<List<CameraDescription>> getAvailableCameras({
    bool refresh = false,
  }) async {
    if (_availableCameras.isNotEmpty && !refresh) {
      return List.unmodifiable(_availableCameras);
    }

    try {
      final cameras = await availableCameras();
      _availableCameras
        ..clear()
        ..addAll(cameras);
    } catch (e) {
      _logError('Failed to query cameras: $e');
    }

    return List.unmodifiable(_availableCameras);
  }

  CameraDescription _resolveCamera(List<CameraDescription> cameras) {
    if (_preferredCameraName.isNotEmpty) {
      for (final camera in cameras) {
        if (camera.name == _preferredCameraName) {
          return camera;
        }
      }
    }

    for (final camera in cameras) {
      if (camera.lensDirection == CameraLensDirection.back) {
        return camera;
      }
    }

    return cameras.first;
  }

  /// Initializes (or re-initializes) the camera with the given settings,
  /// falling back to lower presets and frame rates the device supports.
  ///
  /// Calls are serialized: a call made while another initialization is in
  /// progress waits for it to finish and then runs with its own settings.
  /// Does nothing while a recording is starting, active or stopping, since
  /// re-initializing would dispose the recording controller.
  /// Requests camera (and, with audio, microphone) permission but not
  /// notifications. On failure [isInitialized] stays `false`.
  Future<void> initializeCamera({
    ResolutionPreset? resolutionPreset,
    int? recordingFps,
    int? videoBitrateBps,
    bool? audioEnabled,
    String? preferredCameraName,
    int? segmentDurationSeconds,
    int? maxRollingSegments,
  }) async {
    while (_initInFlight != null) {
      await _initInFlight;
    }
    if (isRecording || _isStartingRecording || _isStoppingRecording) {
      _log('Camera init skipped: a recording session is active');
      return;
    }

    final completer = Completer<void>();
    _initInFlight = completer.future;
    try {
      await _initializeCameraNow(
        resolutionPreset: resolutionPreset,
        recordingFps: recordingFps,
        videoBitrateBps: videoBitrateBps,
        audioEnabled: audioEnabled,
        preferredCameraName: preferredCameraName,
        segmentDurationSeconds: segmentDurationSeconds,
        maxRollingSegments: maxRollingSegments,
      );
    } finally {
      _initInFlight = null;
      completer.complete();
    }
  }

  Future<void> _initializeCameraNow({
    ResolutionPreset? resolutionPreset,
    int? recordingFps,
    int? videoBitrateBps,
    bool? audioEnabled,
    String? preferredCameraName,
    int? segmentDurationSeconds,
    int? maxRollingSegments,
  }) async {
    final wasFailed = _initState == CameraInitState.failed;
    _initState = CameraInitState.initializing;
    _initFailure = null;
    if (wasFailed) {
      // Clears the failure panel while the retry runs.
      notifyListeners();
    }
    try {
      final previousController = _controller;
      final hadPreviousController = previousController != null;

      if (resolutionPreset != null) {
        _resolutionPreset = resolutionPreset;
      }
      if (recordingFps != null) {
        _recordingFps = recordingFps;
      }
      if (videoBitrateBps != null) {
        _videoBitrateBps = videoBitrateBps;
      }
      if (audioEnabled != null) {
        _audioEnabled = audioEnabled;
      }
      if (preferredCameraName != null) {
        _preferredCameraName = preferredCameraName.trim();
      }
      if (segmentDurationSeconds != null) {
        _segmentDuration = Duration(
          seconds: segmentDurationSeconds.clamp(5, 600),
        );
      }
      if (maxRollingSegments != null) {
        _maxRollingSegments = maxRollingSegments.clamp(1, 120);
      }

      // Reset preview state before reinitializing to avoid rendering a
      // disposed controller texture during resolution/camera switches.
      if (hadPreviousController) {
        _controller = null;
        _isInitialized = false;
        notifyListeners();
        try {
          await previousController.dispose();
        } catch (_) {
          // Best-effort cleanup of the previous controller.
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      } else {
        _isInitialized = false;
      }

      // Camera and microphone are required here (a no-op prompt when
      // already granted). Notifications are left to the permission audit so
      // the rider is not prompted twice.
      final cameraStatus = await Permission.camera.request();
      final microphoneStatus = _audioEnabled
          ? await Permission.microphone.request()
          : PermissionStatus.granted;

      if (!AppPermissionService.isPermissionGranted(cameraStatus) ||
          !AppPermissionService.isPermissionGranted(microphoneStatus)) {
        _log('Camera or microphone permission denied');
        _failInit(
          cameraInitFailureForPermissions(
                camera: cameraStatus,
                microphone: microphoneStatus,
                audioEnabled: _audioEnabled,
              ) ??
              const CameraInitFailure(CameraInitFailureReason.unknown),
        );
        return;
      }

      // Set up recordings directory
      if (!await _setupRecordingsDirectory()) {
        _log('Recordings directory is unavailable; camera init aborted.');
        _failInit(
          const CameraInitFailure(CameraInitFailureReason.storageUnavailable),
        );
        return;
      }

      final cameras = await getAvailableCameras(refresh: true);
      if (cameras.isEmpty) {
        _log('No cameras detected on this device');
        _failInit(const CameraInitFailure(CameraInitFailureReason.noCamera));
        return;
      }
      final selectedCamera = _resolveCamera(cameras);
      _activeCameraName = selectedCamera.name;
      if (_preferredCameraName.isEmpty) {
        _preferredCameraName = selectedCamera.name;
      }

      final requestedPreset = _resolutionPreset;
      final requestedFps = _recordingFps;
      _controllerPermissionFailure = null;
      CameraController? initializedController;
      ResolutionPreset? initializedPreset;
      var initializedFps = requestedFps;

      for (final candidatePreset in _resolutionFallbackCandidates(
        requestedPreset,
      )) {
        var presetInitialized = false;
        final supportedFps = _supportedFpsOptionsForPreset(candidatePreset);
        final candidateFps = nearestSupportedFps(
          requested: initializedFps,
          options: supportedFps,
        );

        final firstAttempt = await _tryInitializeController(
          camera: selectedCamera,
          preset: candidatePreset,
          fps: candidateFps,
        );
        if (firstAttempt != null) {
          initializedController = firstAttempt;
          initializedPreset = candidatePreset;
          initializedFps = candidateFps;
          _markResolutionSupported(selectedCamera.name, candidatePreset);
          presetInitialized = true;
          break;
        }

        _markFpsUnsupportedForPreset(candidatePreset, candidateFps);
        final fallbackFps = _fallbackFpsForPreset(candidatePreset);
        if (fallbackFps != candidateFps) {
          final fallbackAttempt = await _tryInitializeController(
            camera: selectedCamera,
            preset: candidatePreset,
            fps: fallbackFps,
          );
          if (fallbackAttempt != null) {
            initializedController = fallbackAttempt;
            initializedPreset = candidatePreset;
            initializedFps = fallbackFps;
            _markResolutionSupported(selectedCamera.name, candidatePreset);
            presetInitialized = true;
            break;
          }
        }

        if (!presetInitialized) {
          _markResolutionUnsupported(selectedCamera.name, candidatePreset);
        }
      }

      if (initializedController == null || initializedPreset == null) {
        _logError('Unable to initialize camera for any preset on this device.');
        // Every preset failing means the camera is busy or unavailable, not
        // that each preset is unsupported; forget this attempt's marks so
        // the next init retries the rider's request.
        _clearCapabilityCachesForCamera(selectedCamera.name);
        // A permission revoked since the status check is named as such; any
        // other plugin error stays "unavailable".
        _failInit(
          _controllerPermissionFailure ??
              const CameraInitFailure(
                CameraInitFailureReason.cameraUnavailable,
              ),
        );
        return;
      }

      _controller = initializedController;
      _resolutionPreset = initializedPreset;
      _recordingFps = initializedFps;

      _isInitialized = true;
      _initState = CameraInitState.ready;
      _initFailure = null;
      _log('Camera initialized successfully');
      if (_resolutionPreset != requestedPreset) {
        _log(
          'Requested preset $requestedPreset is not supported; downgraded to $_resolutionPreset.',
        );
      }
      if (_recordingFps != requestedFps) {
        _log('Requested FPS $requestedFps adjusted to $_recordingFps.');
      }
      _log('Resolution preset: $_resolutionPreset');
      _log('Target FPS: $_recordingFps');
      _log('Video bitrate bps: $_videoBitrateBps');
      _log('Audio enabled: $_audioEnabled');
      _log('Selected camera: ${cameraLabel(selectedCamera)}');
      _log('Recordings directory: $_recordingsDirectory');
      notifyListeners();
    } catch (e) {
      _logError('Error initializing camera: $e');
      _failInit(
        CameraInitFailure(CameraInitFailureReason.unknown, detail: '$e'),
      );
    }
  }

  // Records a failed initialization: not initialized, the reason kept for the
  // UI, listeners told.
  void _failInit(CameraInitFailure failure) {
    _isInitialized = false;
    _initState = CameraInitState.failed;
    _initFailure = failure;
    notifyListeners();
  }

  /// Records that setup stopped before the camera could be initialized (for
  /// example the permission audit found a required permission missing), so
  /// [initState] is [CameraInitState.failed] with [failure] instead of
  /// staying idle. Does nothing while the camera is initialized or
  /// initializing, or a recording is starting, active or stopping.
  void reportInitBlocked(CameraInitFailure failure) {
    if (_isInitialized ||
        isInitializing ||
        isRecording ||
        _isStartingRecording ||
        _isStoppingRecording) {
      return;
    }
    _initState = CameraInitState.failed;
    _initFailure = failure;
    notifyListeners();
  }

  /// Applies new recording settings by re-initializing the camera.
  ///
  /// Returns `false` without changing anything while a recording is
  /// starting, active or stopping; otherwise returns [isInitialized] after
  /// the re-initialization (or `true` when nothing changed).
  Future<bool> applyRecordingSettings({
    required ResolutionPreset resolutionPreset,
    required int recordingFps,
    required int videoBitrateBps,
    required bool audioEnabled,
    required String preferredCameraName,
    required int segmentDurationSeconds,
    required int maxRollingSegments,
  }) async {
    if (isRecording || _isStartingRecording || _isStoppingRecording) {
      _log('Cannot apply recording settings while recording is active');
      return false;
    }

    final hasChanged =
        _resolutionPreset != resolutionPreset ||
        _recordingFps != recordingFps ||
        _videoBitrateBps != videoBitrateBps ||
        _audioEnabled != audioEnabled ||
        _preferredCameraName != preferredCameraName.trim() ||
        _segmentDuration.inSeconds != segmentDurationSeconds ||
        _maxRollingSegments != maxRollingSegments;

    if (!hasChanged) {
      return true;
    }

    await initializeCamera(
      resolutionPreset: resolutionPreset,
      recordingFps: recordingFps,
      videoBitrateBps: videoBitrateBps,
      audioEnabled: audioEnabled,
      preferredCameraName: preferredCameraName,
      segmentDurationSeconds: segmentDurationSeconds,
      maxRollingSegments: maxRollingSegments,
    );
    return _isInitialized;
  }

  /// FPS options not yet known to fail at [preset] (all candidates when the
  /// preset has not been tried).
  Future<List<int>> getSupportedFpsOptionsForPreset({
    required ResolutionPreset preset,
  }) async {
    final key = _fpsCacheKeyForPreset(preset);
    if (_supportedFpsCache.containsKey(key)) {
      return List.unmodifiable(_supportedFpsCache[key]!);
    }

    return List.unmodifiable(_fpsCandidates);
  }

  List<ResolutionPreset> _resolutionFallbackCandidates(
    ResolutionPreset requested,
  ) {
    final startIndex = _resolutionFallbackOrder.indexOf(requested);
    if (startIndex < 0) {
      return const <ResolutionPreset>[
        ResolutionPreset.high,
        ResolutionPreset.medium,
        ResolutionPreset.low,
      ];
    }
    return _resolutionFallbackOrder.sublist(startIndex);
  }

  List<int> _supportedFpsOptionsForPreset(ResolutionPreset preset) {
    return _supportedFpsCache[_fpsCacheKeyForPreset(preset)] ?? _fpsCandidates;
  }

  String _resolutionSupportCacheKey(String cameraName) =>
      '${cameraName}_${_audioEnabled ? 1 : 0}';

  void _markResolutionUnsupported(String cameraName, ResolutionPreset preset) {
    final key = _resolutionSupportCacheKey(cameraName);
    final unsupported = Set<ResolutionPreset>.from(
      _unsupportedResolutionCache[key] ?? <ResolutionPreset>{},
    );
    unsupported.add(preset);
    _unsupportedResolutionCache[key] = unsupported;
  }

  void _markResolutionSupported(String cameraName, ResolutionPreset preset) {
    final key = _resolutionSupportCacheKey(cameraName);
    final unsupported = Set<ResolutionPreset>.from(
      _unsupportedResolutionCache[key] ?? <ResolutionPreset>{},
    );
    if (unsupported.remove(preset)) {
      _unsupportedResolutionCache[key] = unsupported;
    }
  }

  void _markFpsUnsupportedForPreset(ResolutionPreset preset, int fps) {
    final key = _fpsCacheKeyForPreset(preset);
    final current = List<int>.from(_supportedFpsCache[key] ?? _fpsCandidates);
    current.remove(fps);
    if (current.isEmpty) {
      current.add(30);
    }
    _supportedFpsCache[key] = current;
  }

  int _fallbackFpsForPreset(ResolutionPreset preset) {
    final options = _supportedFpsOptionsForPreset(preset);
    if (options.contains(30)) {
      return 30;
    }
    return options.last;
  }

  /// Picks the frame rate to try from [options]: [requested] when offered,
  /// else 30, else the highest rate below [requested], else the lowest
  /// offered rate.
  @visibleForTesting
  static int nearestSupportedFps({
    required int requested,
    required List<int> options,
  }) {
    if (options.isEmpty || options.contains(requested)) {
      return requested;
    }
    if (options.contains(30)) {
      return 30;
    }
    final sorted = List<int>.from(options)..sort();
    final lower = sorted.where((fps) => fps < requested);
    return lower.isNotEmpty ? lower.last : sorted.first;
  }

  // FPS support is cached per camera, preset and audio setting.
  String _fpsCacheKeyForPreset(ResolutionPreset preset) =>
      '${_activeCameraName}_${preset.name}_${_audioEnabled ? 1 : 0}';

  void _clearCapabilityCachesForCamera(String cameraName) {
    _unsupportedResolutionCache.remove(_resolutionSupportCacheKey(cameraName));
    final prefix = '${cameraName}_';
    _supportedFpsCache.removeWhere((key, _) => key.startsWith(prefix));
  }

  // The permission failure a CameraException named during the current
  // initialization, if any (see cameraInitFailureForCameraExceptionCode).
  CameraInitFailure? _controllerPermissionFailure;

  Future<CameraController?> _tryInitializeController({
    required CameraDescription camera,
    required ResolutionPreset preset,
    required int fps,
  }) async {
    final controller = CameraController(
      camera,
      preset,
      enableAudio: _audioEnabled,
      fps: fps,
      videoBitrate: _videoBitrateBps,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await controller.initialize();
      try {
        await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      } catch (lockError) {
        _log('Capture orientation lock skipped on this device: $lockError');
      }
      return controller;
    } catch (e) {
      _log('Camera init failed for preset $preset at ${fps}fps: $e');
      if (e is CameraException) {
        _controllerPermissionFailure ??=
            cameraInitFailureForCameraExceptionCode(e.code);
      }
      try {
        await controller.dispose();
      } catch (_) {
        // Best-effort dispose after failed initialize.
      }
      return null;
    }
  }

  // Resolves the recordings root once per process and keeps it: a later
  // failure never switches rides to another root. Returns false when the
  // root is unavailable.
  Future<bool> _setupRecordingsDirectory() async {
    try {
      var directoryPath = _recordingsDirectory;
      if (directoryPath == null || directoryPath.isEmpty) {
        final baseDirectory = await _resolveRecordingsBaseDirectory();
        if (baseDirectory == null) {
          _logError('Recordings storage is unavailable.');
          return false;
        }
        directoryPath =
            '${baseDirectory.path}${Platform.pathSeparator}$_recordingsDirectoryName';
      }

      final recordingsDir = Directory(directoryPath);
      if (!await recordingsDir.exists()) {
        await recordingsDir.create(recursive: true);
        _log('Created recordings directory: ${recordingsDir.path}');
      }
      if (Platform.isAndroid) {
        await _ensureNoMediaMarker(recordingsDir);
      }

      _recordingsDirectory = recordingsDir.path;
      _log('Recordings directory set to: $_recordingsDirectory');
      if (!_hasPrunedTelemetryTempFiles) {
        _hasPrunedTelemetryTempFiles = true;
        // Temp files left by a process killed mid-write; errors are ignored.
        // Only the recordings root: never the legacy roots or staging.
        unawaited(integrity_utils.pruneStaleTelemetryTempFiles(recordingsDir));
      }
      _maybeStartRecordingsMigration();
      _maybeResumeGalleryExports();
      return true;
    } catch (e) {
      _logError('Error setting up recordings directory: $e');
      return false;
    }
  }

  // Android: the app's private files directory (filesDir), on the same
  // mount as the camera plugin's cache directory, so a finished segment is
  // renamed into place.
  Future<Directory?> _resolveRecordingsBaseDirectory() async {
    if (Platform.isIOS) {
      return getApplicationDocumentsDirectory();
    }
    return getApplicationSupportDirectory();
  }

  // Keeps private loop footage out of the media index on Android versions
  // whose scanner does not skip Android/data.
  Future<void> _ensureNoMediaMarker(Directory recordingsDir) async {
    try {
      final marker = File(
        '${recordingsDir.path}${Platform.pathSeparator}.nomedia',
      );
      if (!await marker.exists()) {
        await marker.create();
      }
    } catch (e) {
      _log('Could not create .nomedia marker: $e');
    }
  }

  // Android roots earlier builds recorded to: app-specific external storage
  // (the root until this build) and the documents and cache directories
  // (old fallbacks). Scanned so rides stored there stay visible until the
  // migration has moved them; never written to and never pruned. An
  // unavailable root (for example an unmounted card) is skipped.
  Future<List<String>> _legacyRecordingsDirectories() async {
    if (!Platform.isAndroid) {
      return const <String>[];
    }
    final roots = <String>[];
    for (final resolve in <Future<Directory?> Function()>[
      getExternalStorageDirectory,
      getApplicationDocumentsDirectory,
      getApplicationCacheDirectory,
    ]) {
      try {
        final base = await resolve();
        if (base == null) {
          continue;
        }
        final root =
            '${base.path}${Platform.pathSeparator}$_recordingsDirectoryName';
        final current = _recordingsDirectory;
        if (current == null ||
            _normalizePath(root) != _normalizePath(current)) {
          roots.add(root);
        }
      } catch (_) {
        // Root unavailable on this device.
      }
    }
    return roots;
  }

  // Ride History actions holding the migration off (see
  // holdRecordingsMigration).
  int _recordingsMigrationHolds = 0;

  /// Keeps the move of rides into private storage from starting or
  /// resuming (a run in progress pauses at its next check) until the
  /// returned callback is called. Ride History holds it while a ride is
  /// open, being unlocked or being deleted, so no file of that ride moves
  /// underneath it. Calling the callback again has no further effect.
  VoidCallback holdRecordingsMigration() {
    _recordingsMigrationHolds++;
    var released = false;
    return () {
      if (released) {
        return;
      }
      released = true;
      _recordingsMigrationHolds--;
      _maybeStartRecordingsMigration();
    };
  }

  // The migration may run only while nothing records or prunes: never while
  // a recording is starting, active or stopping, never while the deferred
  // orphan prune is queued or running, and never while Ride History holds
  // it.
  bool get _canRunRecordingsMigration =>
      !_isDisposed &&
      _recordingsMigrationHolds == 0 &&
      !isRecording &&
      !_isStartingRecording &&
      !_isStoppingRecording &&
      !_isDeferredMaintenanceRunning &&
      !_isStorageBudgetRunning &&
      _legacyRideImport.isIdle &&
      !(_deferredMaintenanceTimer?.isActive ?? false);

  // Starts (or resumes) the move of rides out of the legacy roots when it
  // may run. START never waits for it: the run checks
  // _canRunRecordingsMigration between files and copy chunks and pauses.
  void _maybeStartRecordingsMigration() {
    final root = _recordingsDirectory;
    if (!Platform.isAndroid ||
        root == null ||
        !_canRunRecordingsMigration ||
        !_recordingsMigration.isIdle ||
        _recordingsMigration.isFinished) {
      return;
    }
    unawaited(() async {
      final legacyRoots = await _legacyRecordingsDirectories();
      if (!_canRunRecordingsMigration || !_recordingsMigration.isIdle) {
        return;
      }
      final RecordingsMigrator migrator;
      try {
        migrator = RecordingsMigrator(
          recordingsRoot: root,
          legacyRoots: legacyRoots,
          workDirectory:
              '${Directory(root).parent.path}${Platform.pathSeparator}'
              '$_migrationDirectoryName',
          freeBytes: _availableStorageBytesAt,
          reserveBytes: _estimatedSegmentBytes + _storageMarginBytes,
          shouldPause: () => !_canRunRecordingsMigration,
        );
      } catch (e) {
        _logError('Recordings migration not started: $e');
        return;
      }
      _recordingsMigration.start(
        migrator,
        onError: (error) => _logError('Recordings migration failed: $error'),
      );
    }());
  }

  // Path utilities delegate to shared module.
  String _normalizePath(String path) => path_utils.normalizePath(path);
  bool _isPathInsideDirectory(String filePath, String directoryPath) =>
      path_utils.isPathInsideDirectory(filePath, directoryPath);

  Future<String> _buildUniqueSegmentPath(
    String directoryPath,
    String fileName,
  ) async {
    final resolvedName = fileName.trim().isEmpty
        ? 'segment_${DateTime.now().millisecondsSinceEpoch}.mp4'
        : fileName;
    final dotIndex = resolvedName.lastIndexOf('.');
    final baseName = dotIndex <= 0
        ? resolvedName
        : resolvedName.substring(0, dotIndex);
    final extension = dotIndex <= 0 ? '' : resolvedName.substring(dotIndex);

    var suffix = 0;
    while (true) {
      final candidateName = suffix == 0
          ? resolvedName
          : '${baseName}_$suffix$extension';
      final candidatePath =
          '$directoryPath${Platform.pathSeparator}$candidateName';
      if (!await File(candidatePath).exists()) {
        return candidatePath;
      }
      suffix++;
    }
  }

  Future<String> _persistSegmentToRecordingsDirectory(String sourcePath) async {
    final recordingsDirectoryPath = _recordingsDirectory;
    if (recordingsDirectoryPath == null || sourcePath.isEmpty) {
      return sourcePath;
    }

    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      _log('Segment missing before persistence step: $sourcePath');
      return sourcePath;
    }

    if (_isPathInsideDirectory(sourcePath, recordingsDirectoryPath)) {
      return sourcePath;
    }

    final recordingsDir = Directory(recordingsDirectoryPath);
    if (!await recordingsDir.exists()) {
      await recordingsDir.create(recursive: true);
    }

    final targetPath = await _buildUniqueSegmentPath(
      recordingsDirectoryPath,
      path_utils.fileNameFromPath(sourcePath),
    );

    // On Android the plugin's cache dir and the recordings root (filesDir)
    // are on the same mount, so the rename succeeds; the copy fallback is
    // kept for other layouts.
    try {
      final movedFile = await sourceFile.rename(targetPath);
      final movedPath = movedFile.path;
      if (await _isSegmentFileReady(movedPath)) {
        _log('Moved segment into persistent directory: $movedPath');
        return movedPath;
      }

      // An empty file: put it back where the plugin left it (or drop it),
      // so it never sits unregistered in the recordings root.
      _log('Moved segment failed readiness check, moving it back: $movedPath');
      try {
        await movedFile.rename(sourcePath);
      } catch (_) {
        try {
          await movedFile.delete();
        } catch (_) {
          // Best effort.
        }
      }
      return sourcePath;
    } catch (renameError) {
      _log('Rename failed, falling back to copy/delete: $renameError');
      try {
        final copiedFile = await sourceFile.copy(targetPath);
        final copiedPath = copiedFile.path;
        if (await _isSegmentFileReady(copiedPath)) {
          await sourceFile.delete();
          _log('Copied segment into persistent directory: $copiedPath');
          return copiedPath;
        }
        _log(
          'Copied segment failed readiness check, keeping source path: $copiedPath',
        );
        await copiedFile.delete();
        return sourcePath;
      } catch (copyError) {
        _logError(
          'Failed to persist segment into recordings directory: $copyError',
        );
        // Remove a partial copy (for example after running out of space) so
        // it does not show up in Ride History as a broken video.
        try {
          final partialCopy = File(targetPath);
          if (await partialCopy.exists()) {
            await partialCopy.delete();
          }
        } catch (_) {
          // Best effort.
        }
        return sourcePath;
      }
    }
  }

  Future<bool> _isSegmentFileReady(String path) async {
    if (path.trim().isEmpty) {
      return false;
    }

    final file = File(path);
    if (!await file.exists()) {
      return false;
    }

    try {
      final length = await file.length();
      return length > 0;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _resolveReadyFinalVideoPath({
    required String? cacheVideoPath,
  }) async {
    final candidates = <String>[];

    void addCandidate(String? rawPath) {
      if (rawPath == null) {
        return;
      }
      final path = rawPath.trim();
      if (path.isEmpty || candidates.contains(path)) {
        return;
      }
      candidates.add(path);
    }

    addCandidate(_currentVideoPath);
    addCandidate(cacheVideoPath);
    for (final path in _sessionSegmentPaths.reversed) {
      addCandidate(path);
    }

    if (candidates.isEmpty) {
      return null;
    }

    for (var attempt = 0; attempt < 2; attempt++) {
      for (final candidate in candidates) {
        if (await _isSegmentFileReady(candidate)) {
          return candidate;
        }
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }

    return candidates.first;
  }

  /// Free bytes on the volume holding the recordings directory, or `null`
  /// when the directory is not set up yet or the platform does not report
  /// it (the native `getAvailableStorageBytes` method is missing, as on iOS,
  /// or fails).
  Future<int?> availableStorageBytes() async {
    final directoryPath = _recordingsDirectory;
    if (directoryPath == null || directoryPath.isEmpty) {
      return null;
    }
    return _availableStorageBytesAt(directoryPath);
  }

  Future<int?> _availableStorageBytesAt(String directoryPath) async {
    try {
      return await platform.invokeMethod<int>('getAvailableStorageBytes', {
        'path': directoryPath,
      });
    } catch (_) {
      return null;
    }
  }

  // Estimated size of one segment: its duration at the higher of the
  // requested bitrate and 20 Mbps (Android ignores the requested bitrate).
  int get _estimatedSegmentBytes {
    const assumedMinimumBitrateBps = 20 * 1000 * 1000;
    final bitrateBps = _videoBitrateBps > assumedMinimumBitrateBps
        ? _videoBitrateBps
        : assumedMinimumBitrateBps;
    return _segmentDuration.inSeconds * bitrateBps ~/ 8;
  }

  // Margin for the sidecar and estimate error.
  static const int _storageMarginBytes = 100 * 1024 * 1024;

  // False only when the platform reports less free space than one more
  // segment needs; unknown free space never blocks recording.
  //
  // [reclaimableBytes] is space the loop frees when the segment being
  // recorded is registered. It only offsets the margin: the next segment is
  // written in full before the loop deletes anything (and where the rename
  // into the recordings directory fails, the copy needs that space too), so
  // a full segment of free space is needed on its own.
  Future<bool> _hasRoomForNextSegment({int reclaimableBytes = 0}) async {
    final freeBytes = await availableStorageBytes();
    if (freeBytes == null) {
      return true;
    }
    final segmentBytes = _estimatedSegmentBytes;
    final requiredBytes = segmentBytes + _storageMarginBytes;
    final hasRoom =
        freeBytes >= segmentBytes &&
        freeBytes + reclaimableBytes >= requiredBytes;
    if (!hasRoom) {
      _logError(
        'Low storage: $freeBytes bytes free '
        '($reclaimableBytes reclaimable), $requiredBytes needed for the '
        'next segment',
      );
    }
    return hasRoom;
  }

  // Bytes of the unlocked session segments the loop deletes once the segment
  // being recorded is registered.
  Future<int> _bytesReclaimedByNextRegistration() async {
    final evicted = segmentsEvictedByNextRegistration(
      sessionPaths: _sessionSegmentPaths,
      lockedPaths: _lockedSegmentPaths,
      nextSegmentLocked: _pendingLockSequences.contains(_activeSegmentSequence),
      maxUnlockedSegments: _maxRollingSegments,
    );
    var bytes = 0;
    for (final path in evicted) {
      try {
        bytes += await File(path).length();
      } catch (_) {
        // A missing file frees nothing.
      }
    }
    return bytes;
  }

  static const String _lowStorageMessage =
      'Storage is almost full. Free up space on the phone to keep recording.';

  int _elapsedRideMs() {
    final startedAt = _recordingStartTime;
    if (startedAt == null) {
      return _currentSegmentStartMs;
    }
    return DateTime.now().difference(startedAt).inMilliseconds;
  }

  /// Starts a new segmented recording session.
  ///
  /// Returns `false` without side effects while a session is recording,
  /// starting or stopping, or when the camera is not initialized. Otherwise
  /// clears the previous session's segments, locks and timeline and returns
  /// whether recording started.
  Future<bool> startRecording() async {
    if (isRecording || _isStartingRecording || _isStoppingRecording) {
      _log('Start ignored: a recording session is active or in transition');
      return false;
    }
    if (!_isInitialized ||
        _controller == null ||
        _recordingsDirectory == null) {
      _log('Camera not initialized or recordings directory not set');
      _log(
        'isInitialized: $_isInitialized, controller: $_controller, recordingsDir: $_recordingsDirectory',
      );
      return false;
    }

    _isStartingRecording = true;
    notifyListeners();
    try {
      _sessionSegmentPaths.clear();
      _sessionSegmentTimeline.clear();
      _lockedSegmentPaths.clear();
      _pendingLockSequences.clear();
      _activeSegmentSequence = 0;
      _lastSettledSegmentSequence = 0;
      _currentSegmentStartMs = 0;
      _currentVideoPath = null;
      _lastRecordingError = null;
      _consecutiveRollStopFailures = 0;
      _recordingStartTime = null;
      _elapsedTime = Duration.zero;
      _sessionBudgetDeletedRides = 0;
      _sessionBudgetDeletedBytes = 0;
      _sessionBudgetFailedFiles = 0;
      _sessionBudgetUnattainable = false;
      _sessionBudgetNoticeShown = false;
      _lastStorageBudgetMessage = null;

      _log('Starting recording...');
      _log(
        'Recording segments will be captured every ${_segmentDuration.inSeconds}s',
      );

      if (!await _hasRoomForNextSegment()) {
        _lastRecordingError = _lowStorageMessage;
        _state = RecordingState.idle;
        return false;
      }

      final started = await _startVideoRecordingWithFallback();
      if (!started) {
        _state = RecordingState.idle;
        _recordingStartTime = null;
        _elapsedTime = Duration.zero;
        return false;
      }

      // The ride timeline starts when the first segment starts recording.
      _recordingStartTime = DateTime.now();
      _activeSegmentSequence = 1;
      _currentSegmentStartMs = 0;
      _state = RecordingState.recording;
      _armSegmentTimer();
      // Never delays START: the budget runs a few seconds later, once the
      // telemetry session (and its id) exists.
      _scheduleStorageBudget(const Duration(seconds: 5));

      // Emit elapsed time once per second to reduce rebuild pressure.
      _timerStream?.cancel();
      _timerStream = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_recordingStartTime != null && _state == RecordingState.recording) {
          _elapsedTime = DateTime.now().difference(_recordingStartTime!);
          _timerController.add(_elapsedTime);
        }
      });

      _log('Recording started successfully');
      return true;
    } catch (e) {
      _logError('Error starting recording: $e');
      _log('Stack trace: ${StackTrace.current}');
      return false;
    } finally {
      _isStartingRecording = false;
      notifyListeners();
      // A START that failed frees the migration it paused (a no-op while
      // recording).
      _maybeStartRecordingsMigration();
    }
  }

  Future<bool> _startVideoRecordingWithFallback() async {
    final currentController = _controller;
    if (currentController == null) {
      return false;
    }

    try {
      await currentController.startVideoRecording();
      return true;
    } on CameraException catch (e) {
      _log(
        'startVideoRecording failed at $_resolutionPreset/${_recordingFps}fps: $e',
      );
      if (currentController.value.isRecordingVideo ||
          e.code == 'A video recording is already started.') {
        // Not a preset problem: never tear down a controller that records.
        return false;
      }
    } catch (e) {
      _log(
        'startVideoRecording failed at $_resolutionPreset/${_recordingFps}fps: $e',
      );
    }

    final candidates = _resolutionFallbackCandidates(
      _resolutionPreset,
    ).skip(1).toList();
    if (candidates.isEmpty) {
      return false;
    }

    final activeCamera = await _resolveActiveCameraDescription();
    if (activeCamera == null) {
      _log('Unable to resolve active camera for recording fallback.');
      return false;
    }

    // CameraX keeps one global camera state, so release the failed
    // controller before initializing any candidate.
    await _detachAndDisposeController();

    for (final candidatePreset in candidates) {
      final supportedFps = _supportedFpsOptionsForPreset(candidatePreset);
      var candidateFps = _recordingFps;
      if (!supportedFps.contains(candidateFps)) {
        candidateFps = _fallbackFpsForPreset(candidatePreset);
      }

      final candidateController = await _tryInitializeController(
        camera: activeCamera,
        preset: candidatePreset,
        fps: candidateFps,
      );
      if (candidateController == null) {
        _markResolutionUnsupported(activeCamera.name, candidatePreset);
        continue;
      }

      _controller = candidateController;
      _isInitialized = true;
      _initState = CameraInitState.ready;
      _initFailure = null;
      _resolutionPreset = candidatePreset;
      _recordingFps = candidateFps;
      _markResolutionSupported(activeCamera.name, candidatePreset);
      notifyListeners();

      try {
        await candidateController.startVideoRecording();
        _log(
          'Recording fallback succeeded at $_resolutionPreset/${_recordingFps}fps.',
        );
        return true;
      } catch (e) {
        _log(
          'Recording fallback failed at $candidatePreset/${candidateFps}fps: $e',
        );
        _markResolutionUnsupported(activeCamera.name, candidatePreset);
        await _detachAndDisposeController();
      }
    }

    return false;
  }

  Future<void> _detachAndDisposeController() async {
    final previousController = _controller;
    _controller = null;
    _isInitialized = false;
    _initState = CameraInitState.idle;
    notifyListeners();
    if (previousController == null) {
      return;
    }
    try {
      await previousController.dispose();
    } catch (e) {
      _log('Error disposing camera controller: $e');
    }
  }

  Future<CameraDescription?> _resolveActiveCameraDescription() async {
    for (final camera in _availableCameras) {
      if (camera.name == _activeCameraName) {
        return camera;
      }
    }

    final refreshed = await getAvailableCameras(refresh: true);
    for (final camera in refreshed) {
      if (camera.name == _activeCameraName) {
        return camera;
      }
    }

    if (refreshed.isEmpty) {
      return null;
    }
    return _resolveCamera(refreshed);
  }

  void _armSegmentTimer() {
    _segmentTimer?.cancel();
    _segmentTimer = Timer(_segmentDuration, () async {
      await _rollSegmentIfNeeded();
    });
  }

  bool get _canCycleSegment =>
      isRecording &&
      _controller != null &&
      _rollInFlight == null &&
      !_isStoppingRecording &&
      _lastRecordingError == null;

  Future<void> _rollSegmentIfNeeded() async {
    // The timer can fire while a pipeline recovery is cycling the segment.
    // Wait for it; a restart there arms a new timer, which does the roll.
    final inFlight = _rollInFlight;
    if (inFlight != null) {
      await inFlight;
      if (_segmentTimer?.isActive ?? false) {
        return;
      }
    }
    if (!_canCycleSegment) {
      return;
    }

    final completer = Completer<void>();
    _rollInFlight = completer.future;
    try {
      _log(
        'Rolling recording segment after ${_segmentDuration.inSeconds} seconds',
      );
      await _cycleSegment(keepVideoStreamBound: true);
      _consecutiveRollStopFailures = 0;
    } catch (e) {
      _logError('Error while rolling segment: $e');
      _handleSegmentStopFailure();
    } finally {
      _rollInFlight = null;
      completer.complete();
    }
  }

  // A segment stop failed. Retry at the next boundary once; fail the session
  // when the controller is no longer recording or the stop fails twice in a
  // row.
  void _handleSegmentStopFailure() {
    _consecutiveRollStopFailures++;
    if (_isStoppingRecording || !isRecording || _lastRecordingError != null) {
      return;
    }
    final stillRecording = _controller?.value.isRecordingVideo ?? false;
    if (!stillRecording || _consecutiveRollStopFailures >= 2) {
      _enterRecordingFault(
        'Recording stopped unexpectedly: the camera failed to end a '
        'segment.',
      );
    } else {
      _armSegmentTimer();
    }
  }

  // Stops the current segment, restarts recording immediately, then
  // registers the stopped file while the next segment records. Returns
  // whether recording was restarted. Throws when the stop itself fails.
  //
  // keepVideoStreamBound: only the timed roll passes true. It keeps CameraX's
  // video stream bound across this one stop so the next file starts without
  // a camera session rebuild. Stall recovery keeps the full rebuild on purpose.
  Future<bool> _cycleSegment({bool keepVideoStreamBound = false}) async {
    final controller = _controller!;

    // Checked before the stop so the platform call does not widen the gap
    // between segments.
    final hasRoom = await _hasRoomForNextSegment(
      reclaimableBytes: await _bytesReclaimedByNextRegistration(),
    );

    final cycleStartedAt = DateTime.now();
    final stoppedSequence = _activeSegmentSequence;
    final stoppedStartMs = _currentSegmentStartMs;

    // Set right before the stop (no await in between), and only when this
    // roll will restart recording at once.
    if (keepVideoStreamBound && hasRoom && !_isStoppingRecording) {
      keepVideoStreamBoundForNextStop();
    }
    final file = await controller.stopVideoRecording();
    final stoppedEndMs = _elapsedRideMs();
    final stopElapsedMs = DateTime.now()
        .difference(cycleStartedAt)
        .inMilliseconds;

    var restarted = false;
    var restartElapsedMs = 0;
    var faultMessage =
        'Recording stopped unexpectedly: the camera could not restart '
        'after a segment ended (storage full or camera unavailable).';
    if (!_isStoppingRecording && !hasRoom) {
      faultMessage = _lowStorageMessage;
    } else if (!_isStoppingRecording) {
      final restartStartedAt = DateTime.now();
      restarted = await _restartRecordingAfterSegmentStop(controller);
      restartElapsedMs = DateTime.now()
          .difference(restartStartedAt)
          .inMilliseconds;
      _log(
        'Segment restart ${restarted ? 'completed' : 'failed'} in '
        '${restartElapsedMs}ms',
      );
    }

    final registerStartedAt = DateTime.now();
    await _registerCompletedSegment(
      file.path,
      sequence: stoppedSequence,
      startMs: stoppedStartMs,
      endMs: stoppedEndMs,
    );
    final registerElapsedMs = DateTime.now()
        .difference(registerStartedAt)
        .inMilliseconds;
    final totalElapsedMs = DateTime.now()
        .difference(cycleStartedAt)
        .inMilliseconds;
    _log(
      'Segment roll timings: stop=${stopElapsedMs}ms, '
      'restart=${restartElapsedMs}ms, register=${registerElapsedMs}ms, '
      'total=${totalElapsedMs}ms',
    );

    if (!restarted && !_isStoppingRecording && isRecording) {
      _enterRecordingFault(faultMessage);
    }
    if (restarted) {
      // Off the roll's critical path.
      _scheduleStorageBudget(const Duration(seconds: 3));
    }
    return restarted;
  }

  Future<bool> _restartRecordingAfterSegmentStop(
    CameraController controller,
  ) async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        await controller.startVideoRecording();
        _activeSegmentSequence++;
        _currentSegmentStartMs = _elapsedRideMs();
        _armSegmentTimer();
        // The LOCKED badge ends when its segment rolls.
        notifyListeners();
        return true;
      } catch (e) {
        _logError('Segment restart attempt $attempt failed: $e');
        if (_isStoppingRecording) {
          return false;
        }
        if (attempt == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          if (_isStoppingRecording) {
            return false;
          }
        }
      }
    }
    return false;
  }

  void _enterRecordingFault(String message) {
    _lastRecordingError = message;
    _segmentTimer?.cancel();
    _segmentTimer = null;
    _logError(message);
    notifyListeners();
  }

  /// Restarts the recording pipeline (stop, restart, then register the
  /// stopped segment) to recover from a suspected video stall.
  ///
  /// Returns `false` when not recording, while a roll or stop is in progress,
  /// after a recording failure, or when the recovery fails.
  Future<bool> recoverRecordingPipeline({
    String reason = 'suspected-video-stall',
  }) async {
    if (!_canCycleSegment) {
      return false;
    }

    final completer = Completer<void>();
    _rollInFlight = completer.future;
    try {
      _log('Attempting recording pipeline recovery: $reason');
      final restarted = await _cycleSegment();
      _consecutiveRollStopFailures = 0;
      if (!restarted) {
        _log('Recording pipeline recovery failed: restart failed');
        return false;
      }
      _log('Recording pipeline recovery succeeded');
      notifyListeners();
      return true;
    } catch (e) {
      // The stop failed: same handling as a failed roll, so the segment
      // timer is re-armed or the session enters a fault.
      _logError('Recording pipeline recovery failed: $e');
      _handleSegmentStopFailure();
      return false;
    } finally {
      _rollInFlight = null;
      completer.complete();
    }
  }

  // Persists a stopped segment into the recordings directory and adds it to
  // the session with its timeline entry, applies pending incident locks and
  // trims the session's unlocked segments to the loop size. Never throws, so
  // a storage error here is not mistaken for a failed segment stop.
  Future<void> _registerCompletedSegment(
    String videoPath, {
    required int sequence,
    required int startMs,
    required int endMs,
  }) async {
    try {
      final persistedVideoPath = await _persistSegmentToRecordingsDirectory(
        videoPath,
      );
      if (!await _isSegmentFileReady(persistedVideoPath)) {
        _logError(
          'Skipping segment registration due to unreadable file: '
          '$persistedVideoPath',
        );
        _pendingLockSequences.remove(sequence);
        return;
      }

      _currentVideoPath = persistedVideoPath;
      _sessionSegmentPaths.add(persistedVideoPath);
      _sessionSegmentTimeline.add(
        SegmentTimelineEntry(
          path: persistedVideoPath,
          startMs: startMs,
          endMs: endMs >= startMs ? endMs : startMs,
        ),
      );

      if (_pendingLockSequences.remove(sequence)) {
        _lockedSegmentPaths.add(persistedVideoPath);
        _log('Incident lock applied to new segment: $persistedVideoPath');
      }

      final evicted = selectSegmentsToEvict(
        sessionPaths: _sessionSegmentPaths,
        lockedPaths: _lockedSegmentPaths,
        maxUnlockedSegments: _maxRollingSegments,
      );
      for (final oldestPath in evicted) {
        _sessionSegmentPaths.remove(oldestPath);
        _sessionSegmentTimeline.removeWhere(
          (entry) => entry.path == oldestPath,
        );
        try {
          final oldestFile = File(oldestPath);
          if (await oldestFile.exists()) {
            await oldestFile.delete();
            _log('Deleted oldest segment due to rolling limit: $oldestPath');
          }
        } catch (e) {
          _log('Failed deleting old rolling segment: $e');
        }
      }
    } catch (e) {
      _logError('Failed to register segment $videoPath: $e');
    } finally {
      if (sequence > _lastSettledSegmentSequence) {
        _lastSettledSegmentSequence = sequence;
      }
    }
  }

  // Runs the storage budget after [delay], unless a run is queued already.
  void _scheduleStorageBudget(Duration delay) {
    if (storageBudgetBytes <= 0 || (_storageBudgetTimer?.isActive ?? false)) {
      return;
    }
    _storageBudgetTimer = Timer(delay, () {
      unawaited(_enforceStorageBudget());
    });
  }

  // The budget may delete only while a ride records (so its session is
  // known) and no other bulk file work (the migration, an import) runs.
  bool get _canEnforceStorageBudget =>
      !_isDisposed &&
      isRecording &&
      !_isStoppingRecording &&
      _recordingsMigration.isIdle &&
      _legacyRideImport.isIdle;

  // Static so the isolate closure cannot capture the provider.
  static Future<StorageBudgetInventory> _scanStorageBudgetInBackground(
    String root,
    String? indexFilePath,
  ) {
    return Isolate.run(
      () => scanStorageBudgetInventory(root, indexFilePath: indexFilePath),
    );
  }

  // Deletes the oldest unlocked rides while the recordings root exceeds
  // storageBudgetBytes (see selectRidesForStorageBudget) and sets
  // lastStorageBudgetMessage once per session.
  Future<void> _enforceStorageBudget() async {
    final root = _recordingsDirectory;
    final budget = storageBudgetBytes;
    if (budget <= 0 ||
        root == null ||
        _isStorageBudgetRunning ||
        !_canEnforceStorageBudget) {
      return;
    }
    if (_rollInFlight != null) {
      // Retried once the segment is registered.
      _scheduleStorageBudget(const Duration(seconds: 3));
      return;
    }
    final sessionId = currentRideSessionIdSource?.call();
    if (sessionId == null) {
      // The telemetry session has not started; the next roll retries.
      return;
    }
    final startedAt = _recordingStartTime;
    // A stop and a new START during the run would mix two sessions'
    // protections; the run then ends and the new session schedules its own.
    bool sessionChanged() =>
        currentRideSessionIdSource?.call() != sessionId ||
        _recordingStartTime != startedAt;
    _isStorageBudgetRunning = true;
    try {
      final store = await RideIndexStore.shared();
      final inventory = await _scanStorageBudgetInBackground(
        root,
        store?.file.path,
      );
      if (!_canEnforceStorageBudget) {
        return;
      }
      if (sessionChanged()) {
        _scheduleStorageBudget(const Duration(seconds: 3));
        return;
      }
      // Neither the migration nor the import runs while a ride records, so
      // their journals cannot change during this run.
      final parent = Directory(root).parent.path;
      final sep = Platform.pathSeparator;
      final protectedPaths = <String>{
        ...inventory.protectedPaths,
        ..._recordingsMigration.inFlightPaths,
        ..._legacyRideImport.inFlightPaths,
        ...await RecordingsMigrator.protectedDestinationPaths(
          workDirectory: '$parent$sep$_migrationDirectoryName',
          recordingsRoot: root,
        ),
        ...await LegacyRideImporter.protectedDestinationPaths(
          workDirectory: '$parent$sep$_importDirectoryName',
          recordingsRoot: root,
        ),
      };
      if (!_canEnforceStorageBudget || sessionChanged()) {
        return;
      }
      final selection = selectRidesForStorageBudget(
        budgetBytes: budget,
        fileSizes: inventory.fileSizes,
        rides: inventory.rides,
        recordingsRoot: root,
        currentRideSessionId: sessionId,
        currentSessionPaths: _liveSessionPaths(),
        currentSessionStartedAt: startedAt,
        protectedPaths: protectedPaths,
      );
      if (!selection.isOverBudget) {
        return;
      }
      if (!selection.attainable) {
        _logError(
          'Storage budget: ${selection.totalBytes} bytes recorded, budget '
          '$budget; rides it may not delete use ${selection.protectedBytes} '
          'bytes, so nothing was deleted',
        );
        _sessionBudgetUnattainable = true;
        _publishStorageBudgetNotice(budget);
        return;
      }

      var deletedRides = 0;
      var deletedBytes = 0;
      final sizes = <String, int>{
        for (final entry in inventory.fileSizes.entries)
          _normalizePath(entry.key): entry.value,
      };
      for (final ride in selection.ridesToDelete) {
        if (!_canEnforceStorageBudget || sessionChanged()) {
          break;
        }
        // A segment registered since the scan is never deleted.
        final live = _liveSessionPaths().map(_normalizePath).toSet();
        if (ride.files.map(_normalizePath).any(live.contains)) {
          continue;
        }
        final record = inventory.records[ride.id];
        if (record == null) {
          continue;
        }
        // Gallery copies are never touched; only the ride's links and
        // queued exports are dropped.
        final result = await deleteRideFiles(
          record,
          indexStore: store,
          galleryLinks: await GalleryLinkStore.shared(),
        );
        _sessionBudgetFailedFiles += result.failed;
        if (result.deletedPaths.isNotEmpty) {
          deletedRides++;
          for (final path in result.deletedPaths) {
            deletedBytes += sizes[_normalizePath(path)] ?? 0;
          }
        }
      }
      _sessionBudgetDeletedRides += deletedRides;
      _sessionBudgetDeletedBytes += deletedBytes;
      _logError(
        'Storage budget: deleted $deletedRides ride(s), $deletedBytes bytes '
        '(${selection.totalBytes} bytes recorded, budget $budget)',
      );
      _publishStorageBudgetNotice(budget);
    } catch (e) {
      _logError('Storage budget run failed: $e');
    } finally {
      _isStorageBudgetRunning = false;
      if (!_isDisposed) {
        notifyListeners();
      }
      // The migration may have been waiting for this run (after a stop).
      _maybeStartRecordingsMigration();
    }
  }

  // Every path of the session being recorded: its registered segments and
  // the segment registered last.
  List<String> _liveSessionPaths() => <String>[
    ..._sessionSegmentPaths,
    ?_currentVideoPath,
  ];

  void _publishStorageBudgetNotice(int budget) {
    if (_sessionBudgetNoticeShown) {
      return;
    }
    final notice = storageBudgetNotice(
      deletedRides: _sessionBudgetDeletedRides,
      deletedBytes: _sessionBudgetDeletedBytes,
      unattainable: _sessionBudgetUnattainable,
      budgetBytes: budget,
      failedFiles: _sessionBudgetFailedFiles,
    );
    if (notice == null) {
      return;
    }
    _sessionBudgetNoticeShown = true;
    _lastStorageBudgetMessage = notice;
  }

  // Runs the orphan-sidecar prune shortly after a stop, off the stop path,
  // then lets the recordings migration resume. The two never overlap: a
  // queued or running prune pauses the migration, and the prune first waits
  // for a run that is still abandoning its copy.
  void _queueDeferredMaintenance() {
    _deferredMaintenanceTimer?.cancel();
    _deferredMaintenanceTimer = Timer(const Duration(seconds: 2), () async {
      if (_isDeferredMaintenanceRunning) {
        return;
      }
      _isDeferredMaintenanceRunning = true;
      try {
        await _recordingsMigration.whenIdle();
        await _pruneOrphanTelemetryFiles();
      } finally {
        _isDeferredMaintenanceRunning = false;
      }
      _maybeStartRecordingsMigration();
    });
  }

  // Static so the isolate closure cannot capture the provider.
  static Future<List<String>> _findOrphanTelemetryFilesInBackground(
    String directoryPath,
  ) {
    return Isolate.run(() => findOrphanTelemetryFiles(directoryPath));
  }

  // Deletes unlocked telemetry sidecars whose videos are all gone, from the
  // top level of the recordings root only (never a legacy root, where a
  // ride being migrated can look orphaned, and never staging). Parsing runs
  // on a background isolate.
  Future<void> _pruneOrphanTelemetryFiles() async {
    final recordingsDirectoryPath = _recordingsDirectory;
    if (recordingsDirectoryPath == null || recordingsDirectoryPath.isEmpty) {
      return;
    }

    List<String> orphans;
    try {
      orphans = await _findOrphanTelemetryFilesInBackground(
        recordingsDirectoryPath,
      );
    } catch (e) {
      _log('Orphan telemetry scan failed: $e');
      return;
    }

    for (final path in orphans) {
      try {
        await File(path).delete();
        _log('Deleted telemetry with no remaining segment files: $path');
      } catch (e) {
        _log('Failed deleting orphan telemetry $path: $e');
      }
    }
  }

  /// Locks the last [protectPastSegments] registered segments (clamped to
  /// 0-10) and, when [protectCurrentSegment] is set while recording, every
  /// segment not yet registered: the one being recorded and, during a roll,
  /// the one still being saved. Repeated calls within one segment lock
  /// nothing extra. Locked segments are exempt from loop deletion.
  void markIncident({
    int protectPastSegments = 2,
    bool protectCurrentSegment = true,
    String reason = 'manual',
  }) {
    final int clampedPast = protectPastSegments.clamp(0, 10);
    final int lockStart = (_sessionSegmentPaths.length - clampedPast).clamp(
      0,
      _sessionSegmentPaths.length,
    );

    for (var index = lockStart; index < _sessionSegmentPaths.length; index++) {
      _lockedSegmentPaths.add(_sessionSegmentPaths[index]);
    }

    final lockUnsettled = protectCurrentSegment && isRecording;
    if (lockUnsettled) {
      _pendingLockSequences.addAll(
        unsettledSegmentSequences(
          lastSettledSequence: _lastSettledSegmentSequence,
          activeSequence: _activeSegmentSequence,
        ),
      );
    }

    _log(
      'Incident marked ($reason): locked $clampedPast previous segments, pending current lock: $lockUnsettled',
    );
    notifyListeners();
  }

  List<String> _segmentsSelectedForPublicExport() {
    if (_lockedSegmentPaths.isEmpty) {
      return const <String>[];
    }

    final exportCandidates = <String>[];
    for (final path in _sessionSegmentPaths) {
      if (_lockedSegmentPaths.contains(path)) {
        exportCandidates.add(path);
      }
    }
    return exportCandidates;
  }

  /// The gallery export queue on the app's [GalleryLinkStore], or `null`
  /// when the store is unavailable (then nothing is exported).
  Future<GalleryExporter?> _galleryExporter() {
    return _galleryExporterFuture ??= () async {
      final store = await GalleryLinkStore.shared();
      if (store == null) {
        _logError('Gallery link store unavailable; gallery export is off.');
        return null;
      }
      return GalleryExporter(
        store: store,
        exportVideo: _exportVideoToGallery,
        locate: _locateGalleryExportSource,
        requestStoragePermission: _requestLegacyStoragePermission,
        // A copy whose ride was deleted or unlocked during the copy.
        deleteCopies: GalleryCopies.delete,
        relativePath: _galleryRelativePath,
      );
    }();
  }

  Future<String?> _exportVideoToGallery({
    required String sourcePath,
    required String displayName,
    required DateTime queuedAt,
  }) {
    return platform.invokeMethod<String>('exportVideoToGallery', {
      'sourcePath': sourcePath,
      'displayName': displayName,
      'relativePath': _galleryRelativePath,
      // A copy that a killed process already finished is linked, not made
      // again (API 29+, and only one added since the segment was queued).
      'reuseExisting': true,
      'queuedAtMs': queuedAt.millisecondsSinceEpoch,
    });
  }

  // The recordings directory first, then the legacy roots: a ride moved by
  // the migration or the import is found by file name.
  Future<String?> _locateGalleryExportSource(PendingGalleryExport entry) async {
    if (_recordingsDirectory == null) {
      await _setupRecordingsDirectory();
    }
    final current = _recordingsDirectory;
    return locateGalleryExportSource(
      entry: entry,
      roots: <String>[?current, ...await _legacyRecordingsDirectories()],
    );
  }

  // Android 9 and lower: exportVideoToGallery needs WRITE_EXTERNAL_STORAGE
  // (Permission.storage). Asked only by the drain after a stop with gallery
  // export on and by Save to gallery, never by the launch retry.
  Future<bool> _requestLegacyStoragePermission() async {
    try {
      return AppPermissionService.isPermissionGranted(
        await Permission.storage.request(),
      );
    } catch (e) {
      // For example no foreground activity to show the prompt.
      _logError('Storage permission request failed: $e');
      return false;
    }
  }

  // The gallery export pauses while a recording starts or runs; the rest
  // stays queued and the next stop drains it
  // (_resumeGalleryExportsAfterStop).
  bool _shouldPauseGalleryExport() =>
      _isDisposed || isRecording || _isStartingRecording;

  /// Queues [segmentPaths] (the stopped session's locked segments) for
  /// export, persisted at once in the gallery link store, and drains the
  /// queue about 2 s later. Returns whether anything was handed over (then
  /// that drain also copies what was queued before).
  bool _enqueueDeferredGalleryExport(Iterable<String> segmentPaths) {
    if (!Platform.isAndroid) {
      return false;
    }
    // Still the stopped ride's id: telemetry clears it only when the ride
    // is saved, after stopRecording returns.
    final rideSessionId = currentRideSessionIdSource?.call();
    final items = <GalleryExportItem>[
      for (final path in segmentPaths)
        if (path.trim().isNotEmpty)
          GalleryExportItem(
            rideSessionId: rideSessionId,
            sourcePath: path.trim(),
          ),
    ];
    if (items.isEmpty) {
      return false;
    }
    unawaited(() async {
      final exporter = await _galleryExporter();
      if (exporter == null) {
        return;
      }
      try {
        await exporter.enqueue(items);
      } catch (e) {
        _logError('Queueing gallery export failed: $e');
        return;
      }
      _scheduleGalleryExportDrain(askPermission: true, noun: 'locked clip');
    }());
    return true;
  }

  /// After a stop that queued nothing: drains, about 2 s later, what is
  /// still queued (a Save to gallery or a drain that the recording paused,
  /// or a queue the launch retry left), without asking for a permission.
  void _resumeGalleryExportsAfterStop() {
    if (!Platform.isAndroid || _isDisposed) {
      return;
    }
    unawaited(() async {
      final exporter = await _galleryExporter();
      if (exporter == null || (await exporter.store.read()).pending.isEmpty) {
        return;
      }
      _scheduleGalleryExportDrain(askPermission: false, noun: 'clip');
    }());
  }

  /// Retries, once per process, a gallery export queue that an earlier
  /// process left behind, when nothing is recording. Never asks for a
  /// permission. While a recording runs, the next stop drains it.
  void _maybeResumeGalleryExports() {
    if (!Platform.isAndroid || _hasResumedGalleryExports || _isDisposed) {
      return;
    }
    _hasResumedGalleryExports = true;
    unawaited(() async {
      final exporter = await _galleryExporter();
      if (exporter == null) {
        return;
      }
      final pending = (await exporter.store.read()).pending;
      if (pending.isEmpty ||
          _shouldPauseGalleryExport() ||
          _isStoppingRecording) {
        return;
      }
      _log('Retrying ${pending.length} queued gallery export(s).');
      _scheduleGalleryExportDrain(askPermission: false, noun: 'clip');
    }());
  }

  void _scheduleGalleryExportDrain({
    required bool askPermission,
    required String noun,
  }) {
    Future<void>.delayed(const Duration(seconds: 2), () async {
      if (_isDisposed) {
        return;
      }
      await _drainGalleryExportQueue(askPermission: askPermission, noun: noun);
    });
  }

  Future<void> _drainGalleryExportQueue({
    required bool askPermission,
    required String noun,
  }) async {
    final exporter = await _galleryExporter();
    if (exporter == null) {
      return;
    }
    // No ride file moves into private storage while it is copied.
    final releaseMigration = holdRecordingsMigration();
    GalleryExportRun run;
    try {
      run = await exporter.drain(
        askPermission: askPermission,
        shouldPause: _shouldPauseGalleryExport,
      );
    } catch (e) {
      _logError('Gallery export failed: $e');
      return;
    } finally {
      releaseMigration();
    }
    if (_isDisposed || !run.hasOutcome) {
      return;
    }
    _lastGalleryExportMessage = galleryExportSummary(
      exported: run.exported,
      failed: run.failed,
      permissionDenied: run.permissionDenied,
      noun: noun,
    );
    notifyListeners();
  }

  /// Why Save to gallery cannot run now (a recording, the move into
  /// private storage, an import or the storage budget is changing files),
  /// or `null` when it can.
  String? get gallerySaveBlockedReason {
    if (isRecording || _isStartingRecording || _isStoppingRecording) {
      return 'Stop recording before saving to the gallery.';
    }
    if (_recordingsMigration.isRunning) {
      return 'Rides are being moved to private storage. Try again when the '
          'move finishes.';
    }
    if (_legacyRideImport.isRunning) {
      return 'Rides are being imported from the old folder. Try again when '
          'the import finishes.';
    }
    if (_isStorageBudgetRunning) {
      return 'Old rides are being deleted for the storage budget. Try again '
          'in a moment.';
    }
    return null;
  }

  /// Save to gallery (Android): copies every existing video file of [ride]
  /// (never its telemetry JSON) to `Movies/MotoCam/Recordings` through the
  /// persisted export queue, whatever its lock state and the auto-export
  /// setting, and records the links. A segment whose copy is already
  /// linked and still exists is not copied again. On Android 9 and lower
  /// the storage permission is requested when the first copy is refused
  /// for lack of it. [onProgress] receives (segments done, segments to do).
  ///
  /// Returns `null` when [gallerySaveBlockedReason] refuses it, off Android
  /// or when the gallery link store is unavailable.
  Future<GalleryExportRun?> saveRideToGallery(
    RideRecord ride, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (!Platform.isAndroid || gallerySaveBlockedReason != null) {
      return null;
    }
    final exporter = await _galleryExporter();
    if (exporter == null || gallerySaveBlockedReason != null) {
      return null;
    }
    final releaseMigration = holdRecordingsMigration();
    try {
      final files = galleryKeysOfRide(ride);
      // A copy the rider deleted in a gallery app may be made again.
      await exporter.forgetMissingLinks(files.keys, GalleryCopies.existingUris);
      final items = <GalleryExportItem>[];
      for (final path in files.values) {
        var exists = false;
        try {
          exists = await File(path).exists();
        } catch (_) {
          exists = false;
        }
        if (exists) {
          items.add(
            GalleryExportItem(
              rideSessionId: ride.rideSessionId,
              sourcePath: path,
            ),
          );
        }
      }
      final queued = await exporter.enqueue(items);
      final run = await exporter.drain(
        onlyKeys: queued.keys,
        askPermission: true,
        shouldPause: _shouldPauseGalleryExport,
        onProgress: onProgress,
      );
      return GalleryExportRun(
        exported: run.exported,
        alreadySaved: queued.alreadySaved + run.alreadySaved,
        missing: run.missing,
        failed: run.failed,
        permissionDenied: run.permissionDenied,
        paused: run.paused,
      );
    } catch (e) {
      _logError('Save to gallery failed: $e');
      return null;
    } finally {
      releaseMigration();
    }
  }

  /// Rider-facing summary of a gallery export run of [noun]s (the locked
  /// clips of a stopped ride, or `clip` for the launch retry).
  @visibleForTesting
  static String galleryExportSummary({
    required int exported,
    required int failed,
    required bool permissionDenied,
    String noun = 'locked clip',
  }) {
    String clips(int n) => '$n $noun${n == 1 ? '' : 's'}';
    final parts = <String>[
      if (exported > 0) '${clips(exported)} copied to the gallery',
      if (failed > 0)
        permissionDenied
            ? '${clips(failed)} not copied (storage permission denied)'
            : '${clips(failed)} could not be copied to the gallery',
    ];
    final message = parts.join('; ');
    return '${message[0].toUpperCase()}${message.substring(1)}.';
  }

  /// Stops the session: waits (up to 60 s) for an in-flight segment roll,
  /// stops the camera, registers the final segment and returns the final
  /// segment's path (or `null` when not recording or already stopping).
  /// When the stop fails it logs the error and returns the last registered
  /// segment's path instead.
  ///
  /// [isStoppingRecording] is `true` and notified for the whole call. When
  /// it returns, [lastSessionSegmentPaths], [lastSessionSegmentTimeline] and
  /// [lockedSegmentPaths] describe the stopped session; they stay unchanged
  /// until the next [startRecording].
  Future<String?> stopRecording() async {
    if (!isRecording || _isStoppingRecording) {
      _log('Not currently recording');
      return null;
    }

    _isStoppingRecording = true;
    notifyListeners();
    try {
      _log('Stopping recording...');

      _segmentTimer?.cancel();
      _segmentTimer = null;

      final rollInFlight = _rollInFlight;
      if (rollInFlight != null) {
        await rollInFlight.timeout(
          _rollWaitTimeout,
          onTimeout: () =>
              _logError('Segment roll still running after $_rollWaitTimeout'),
        );
        // A roll that restarted recording re-armed the segment timer.
        _segmentTimer?.cancel();
        _segmentTimer = null;
      }

      // Cancel timer
      _timerStream?.cancel();
      _timerStream = null;

      final finalSequence = _activeSegmentSequence;
      final finalStartMs = _currentSegmentStartMs;
      String? cacheVideoPath;
      var finalEndMs = _elapsedRideMs();
      try {
        final file = await _controller!.stopVideoRecording();
        finalEndMs = _elapsedRideMs();
        cacheVideoPath = file.path;
      } on CameraException catch (e) {
        // Race safety: when recording already stopped at plugin level,
        // preserve session continuity and let the caller persist telemetry
        // for known segments.
        if (e.code == 'No video is recording') {
          _log('stopVideoRecording race detected: ${e.description ?? e.code}');
          if (_sessionSegmentPaths.isNotEmpty) {
            cacheVideoPath = _sessionSegmentPaths.last;
          } else {
            cacheVideoPath = _currentVideoPath;
          }
        } else {
          rethrow;
        }
      }

      _state = RecordingState.stopped;

      if (cacheVideoPath != null && cacheVideoPath.isNotEmpty) {
        _log('Video stop candidate path: $cacheVideoPath');

        if (!_sessionSegmentPaths.contains(cacheVideoPath)) {
          await _registerCompletedSegment(
            cacheVideoPath,
            sequence: finalSequence,
            startMs: finalStartMs,
            endMs: finalEndMs,
          );
        } else {
          _currentVideoPath = cacheVideoPath;
        }
      }
      _recordingStartTime = null;

      final finalVideoPath = await _resolveReadyFinalVideoPath(
        cacheVideoPath: cacheVideoPath,
      );
      _log('Final persisted video path: $finalVideoPath');

      // Locked clips leave private storage only when the rider opted in.
      var queuedGalleryExport = false;
      if (autoExportLockedClipsToGallery && _sessionSegmentPaths.isNotEmpty) {
        final exportCandidates = _segmentsSelectedForPublicExport();
        if (exportCandidates.isNotEmpty) {
          queuedGalleryExport = _enqueueDeferredGalleryExport(exportCandidates);
        } else {
          _log('No locked segments selected for public export.');
        }
      }
      if (!queuedGalleryExport) {
        _resumeGalleryExportsAfterStop();
      }

      _queueDeferredMaintenance();
      return finalVideoPath;
    } catch (e) {
      _state = RecordingState.stopped;
      _recordingStartTime = null;
      _logError('Error stopping recording: $e');
      _log('Stack trace: ${StackTrace.current}');
      if (_sessionSegmentPaths.isNotEmpty) {
        return _sessionSegmentPaths.last;
      }
      return _currentVideoPath;
    } finally {
      _isStoppingRecording = false;
      notifyListeners();
      // Resumes at once only when no prune was queued (a failed stop).
      _maybeStartRecordingsMigration();
    }
  }

  /// Lists every file (videos, telemetry sidecars, markers) under the
  /// recordings directory and, on Android, the legacy roots earlier builds
  /// recorded to (until the migration has emptied them), in no particular
  /// order. The migration's staging directory lies outside all of them.
  /// Returns an empty list when the recordings directory cannot be set up
  /// or listing fails.
  Future<List<FileSystemEntity>> getRecordings() async {
    if (_recordingsDirectory == null) {
      await _setupRecordingsDirectory();
    }
    if (_recordingsDirectory == null) return [];

    try {
      final files = <FileSystemEntity>[];
      final seenPaths = <String>{};
      final directories = <String?>[
        _recordingsDirectory,
        ...await _legacyRecordingsDirectories(),
      ];
      for (final directoryPath in directories) {
        await _appendFilesFromDirectory(
          files: files,
          seenPaths: seenPaths,
          directoryPath: directoryPath,
        );
      }
      return files;
    } catch (e) {
      _logError('Error getting recordings: $e');
      return [];
    }
  }

  Future<void> _appendFilesFromDirectory({
    required List<FileSystemEntity> files,
    required Set<String> seenPaths,
    required String? directoryPath,
  }) async {
    if (directoryPath == null || directoryPath.isEmpty) {
      return;
    }

    try {
      final dir = Directory(directoryPath);
      if (!await dir.exists()) {
        return;
      }

      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) {
          continue;
        }
        final normalizedPath = _normalizePath(entity.path);
        if (seenPaths.add(normalizedPath)) {
          files.add(entity);
        }
      }
    } catch (_) {
      // Directory may be inaccessible due platform or permission constraints.
    }
  }

  /// Disposes the camera controller to free the camera while idle (for
  /// example while Ride History is open). Waits for an in-progress
  /// initialization first; does nothing while a recording is starting,
  /// active or stopping.
  Future<void> releaseCameraIfIdle() async {
    while (_initInFlight != null) {
      await _initInFlight;
    }
    if (isRecording || _isStartingRecording || _isStoppingRecording) {
      return;
    }

    final previousController = _controller;
    if (previousController == null && !_isInitialized) {
      return;
    }

    _controller = null;
    _isInitialized = false;
    _initState = CameraInitState.idle;
    _initFailure = null;
    _state = RecordingState.idle;
    _recordingStartTime = null;
    _elapsedTime = Duration.zero;
    _timerStream?.cancel();
    _timerStream = null;
    notifyListeners();

    if (previousController == null) {
      return;
    }

    try {
      await previousController.dispose();
    } catch (e) {
      _log('Error disposing idle camera controller: $e');
    }
  }

  /// Cancels the segment, maintenance and elapsed-time timers, closes
  /// [timerStream] and disposes the camera controller without awaiting it.
  /// A gallery export still running afterwards reports no result.
  @override
  void dispose() {
    // Also pauses a recordings migration run at its next check.
    _isDisposed = true;
    _segmentTimer?.cancel();
    _deferredMaintenanceTimer?.cancel();
    _storageBudgetTimer?.cancel();
    _timerStream?.cancel();
    unawaited(_timerController.close());
    unawaited(_controller?.dispose());
    super.dispose();
  }
}
