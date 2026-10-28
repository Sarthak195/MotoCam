// lib/features/camera/providers/camera_provider.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import '../../../core/ride_file/ride_telemetry_codec.dart' as ride_codec;
import '../../../core/services/app_permission_service.dart';
import '../../../core/utils/integrity_utils.dart' as integrity_utils;
import '../../../core/utils/path_utils.dart' as path_utils;
import 'camera_init_status.dart';
import 'recording_retention.dart';
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
  /// and are never removed by MotoCam, so export is opt-in.
  bool autoExportLockedClipsToGallery = false;

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
  final List<String> _pendingGalleryExports = <String>[];
  Timer? _segmentTimer;
  Timer? _deferredMaintenanceTimer;
  Future<void>? _initInFlight;
  Future<void>? _rollInFlight;
  bool _isStartingRecording = false;
  bool _isStoppingRecording = false;
  bool _isExportingToGallery = false;
  bool _isDeferredMaintenanceRunning = false;
  bool _hasPrunedTelemetryTempFiles = false;
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
        unawaited(integrity_utils.pruneStaleTelemetryTempFiles(recordingsDir));
      }
      return true;
    } catch (e) {
      _logError('Error setting up recordings directory: $e');
      return false;
    }
  }

  Future<Directory?> _resolveRecordingsBaseDirectory() async {
    if (Platform.isAndroid) {
      return getExternalStorageDirectory();
    }
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

  // Roots that earlier builds fell back to when the primary root was
  // unavailable. Only scanned so rides stored there stay visible.
  Future<List<String>> _legacyFallbackRecordingsDirectories() async {
    if (!Platform.isAndroid) {
      return const <String>[];
    }
    final roots = <String>[];
    for (final resolve in <Future<Directory> Function()>[
      getApplicationDocumentsDirectory,
      getApplicationCacheDirectory,
    ]) {
      try {
        final base = await resolve();
        roots.add(
          '${base.path}${Platform.pathSeparator}$_recordingsDirectoryName',
        );
      } catch (_) {
        // Root unavailable on this device.
      }
    }
    return roots;
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

    // On Android the plugin's cache dir and the recordings root are on
    // different mounts, so the rename fails and the copy fallback runs.
    try {
      final movedFile = await sourceFile.rename(targetPath);
      final movedPath = movedFile.path;
      if (await _isSegmentFileReady(movedPath)) {
        _log('Moved segment into persistent directory: $movedPath');
        return movedPath;
      }

      _log(
        'Moved segment failed readiness check, keeping source path: $movedPath',
      );
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
  // recorded is registered. It only offsets the margin: the stopped segment
  // is copied into the recordings directory before the loop deletes
  // anything, so the copy needs a full segment of free space on its own.
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
      await _cycleSegment();
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
  Future<bool> _cycleSegment() async {
    final controller = _controller!;

    // Checked before the stop so the platform call does not widen the gap
    // between segments.
    final hasRoom = await _hasRoomForNextSegment(
      reclaimableBytes: await _bytesReclaimedByNextRegistration(),
    );

    final cycleStartedAt = DateTime.now();
    final stoppedSequence = _activeSegmentSequence;
    final stoppedStartMs = _currentSegmentStartMs;

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

  // Runs the orphan-sidecar prune shortly after a stop, off the stop path.
  void _queueDeferredMaintenance() {
    _deferredMaintenanceTimer?.cancel();
    _deferredMaintenanceTimer = Timer(const Duration(seconds: 2), () async {
      if (_isDeferredMaintenanceRunning) {
        return;
      }
      _isDeferredMaintenanceRunning = true;
      try {
        await _pruneOrphanTelemetryFiles();
      } finally {
        _isDeferredMaintenanceRunning = false;
      }
    });
  }

  // Static so the isolate closure cannot capture the provider.
  static Future<List<String>> _findOrphanTelemetryFilesInBackground(
    String directoryPath,
  ) {
    return Isolate.run(() => findOrphanTelemetryFiles(directoryPath));
  }

  // Deletes unlocked telemetry sidecars whose videos are all gone. Parsing
  // runs on a background isolate.
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

  void _enqueueDeferredGalleryExport(Iterable<String> segmentPaths) {
    if (!Platform.isAndroid) {
      return;
    }

    for (final rawPath in segmentPaths) {
      final sourcePath = rawPath.trim();
      if (sourcePath.isNotEmpty &&
          !_pendingGalleryExports.contains(sourcePath)) {
        _pendingGalleryExports.add(sourcePath);
      }
    }

    if (_pendingGalleryExports.isEmpty) {
      return;
    }

    if (_isExportingToGallery) {
      return;
    }

    _isExportingToGallery = true;
    Future<void>.delayed(const Duration(seconds: 2), () async {
      try {
        await _drainGalleryExportQueue();
      } finally {
        _isExportingToGallery = false;
      }
    });
  }

  Future<void> _drainGalleryExportQueue() async {
    var exported = 0;
    var failed = 0;
    var permissionDenied = false;
    // Requested at most once per drain.
    bool? storageGranted;

    Future<void> export(String sourcePath, String fileName) {
      return platform.invokeMethod<String>('exportVideoToGallery', {
        'sourcePath': sourcePath,
        'displayName': fileName,
        'relativePath': _galleryRelativePath,
      });
    }

    while (_pendingGalleryExports.isNotEmpty) {
      final sourcePath = _pendingGalleryExports.removeAt(0);
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        _log('Skipping export for missing segment: $sourcePath');
        continue;
      }

      final fileName = path_utils.fileNameFromPath(sourcePath);
      try {
        await export(sourcePath, fileName);
        exported++;
        _log('Deferred gallery export completed: $fileName');
      } on PlatformException catch (e) {
        if (e.code != 'PERMISSION_DENIED') {
          failed++;
          _logError('Deferred gallery export failed for $fileName: $e');
          continue;
        }
        // Android 9 and lower: the native side needs WRITE_EXTERNAL_STORAGE
        // (Permission.storage). Ask once per drain, then retry this clip
        // once. The dart:io copy fallback is not used: it needs the same
        // permission.
        if (storageGranted == null) {
          try {
            storageGranted = AppPermissionService.isPermissionGranted(
              await Permission.storage.request(),
            );
          } catch (requestError) {
            // For example no foreground activity to show the prompt.
            _logError('Storage permission request failed: $requestError');
            storageGranted = false;
          }
        }
        if (!storageGranted) {
          permissionDenied = true;
          failed++;
          continue;
        }
        try {
          await export(sourcePath, fileName);
          exported++;
        } catch (retryError) {
          failed++;
          _logError('Gallery export retry failed for $fileName: $retryError');
        }
      } catch (e) {
        // The private copy stays in the recordings directory.
        failed++;
        _logError('Deferred gallery export failed for $fileName: $e');
      }
    }

    if (_isDisposed || (exported == 0 && failed == 0)) {
      return;
    }
    _lastGalleryExportMessage = galleryExportSummary(
      exported: exported,
      failed: failed,
      permissionDenied: permissionDenied,
    );
    notifyListeners();
  }

  /// Rider-facing summary of a gallery export run.
  @visibleForTesting
  static String galleryExportSummary({
    required int exported,
    required int failed,
    required bool permissionDenied,
  }) {
    String clips(int n) => '$n locked clip${n == 1 ? '' : 's'}';
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
      if (autoExportLockedClipsToGallery && _sessionSegmentPaths.isNotEmpty) {
        final exportCandidates = _segmentsSelectedForPublicExport();
        if (exportCandidates.isNotEmpty) {
          _enqueueDeferredGalleryExport(exportCandidates);
        } else {
          _log('No locked segments selected for public export.');
        }
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
    }
  }

  /// Lists every file (videos, telemetry sidecars, markers) under the
  /// recordings directory and the roots earlier builds fell back to, in no
  /// particular order. Returns an empty list when the recordings directory
  /// cannot be set up or listing fails.
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
        ...await _legacyFallbackRecordingsDirectories(),
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
    _isDisposed = true;
    _segmentTimer?.cancel();
    _deferredMaintenanceTimer?.cancel();
    _timerStream?.cancel();
    unawaited(_timerController.close());
    unawaited(_controller?.dispose());
    super.dispose();
  }
}
