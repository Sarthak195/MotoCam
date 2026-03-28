// lib/features/camera/providers/camera_provider.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:async';

enum RecordingState { idle, recording, paused, stopped }

class SegmentTimelineEntry {
  const SegmentTimelineEntry({
    required this.path,
    required this.startMs,
    required this.endMs,
  });

  final String path;
  final int startMs;
  final int endMs;

  Map<String, dynamic> toJson() => {
        'path': path,
        'startMs': startMs,
        'endMs': endMs,
      };
}

class CameraProvider extends ChangeNotifier {
  CameraProvider({this.enableDebugLogging = false});

  static const platform = MethodChannel('com.example.motocam/media');
  static const String _galleryRelativePath = 'Movies/MotoCam/Videos';

  CameraController? _controller;
  RecordingState _state = RecordingState.idle;
  String? _currentVideoPath;
  bool _isInitialized = false;
  String? _recordingsDirectory;
  bool enableDebugLogging;
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
  bool _isRollingSegment = false;
  bool _isStoppingRecording = false;
  bool _isExportingToGallery = false;
  int _pendingIncidentSegmentLocks = 0;
  int _lastSegmentEndMs = 0;
  int _recordingRecoveryCount = 0;
  DateTime? _lastRecordingRecoveryAt;
  String? _lastRecordingRecoveryReason;

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
  CameraController? get controller => _controller;
  RecordingState get state => _state;
  String? get currentVideoPath => _currentVideoPath;
  bool get isInitialized => _isInitialized;
  bool get isRecording => _state == RecordingState.recording;
  String? get recordingsDirectory => _recordingsDirectory;
  Duration get elapsedTime => _elapsedTime;
  Stream<Duration> get timerStream => _timerController.stream;
  ResolutionPreset get resolutionPreset => _resolutionPreset;
  int get recordingFps => _recordingFps;
  int get videoBitrateBps => _videoBitrateBps;
  int get videoBitrateMbps => (_videoBitrateBps / 1000000).round();
  bool get audioEnabled => _audioEnabled;
  String get preferredCameraName => _preferredCameraName;
  String get activeCameraName => _activeCameraName;
  List<CameraDescription> get discoveredCameras =>
      List.unmodifiable(_availableCameras);
  int get segmentDurationMinutes => _segmentDuration.inMinutes;
  int get maxRollingSegments => _maxRollingSegments;
  List<String> get lastSessionSegmentPaths =>
      List.unmodifiable(_sessionSegmentPaths);
  List<Map<String, dynamic>> get lastSessionSegmentTimeline =>
      List.unmodifiable(_sessionSegmentTimeline.map((entry) => entry.toJson()));
  List<String> get lockedSegmentPaths =>
      List.unmodifiable(_lockedSegmentPaths.toList()..sort());
  int get lockedSegmentCount => _lockedSegmentPaths.length;
  int get recordingRecoveryCount => _recordingRecoveryCount;
  DateTime? get lastRecordingRecoveryAt => _lastRecordingRecoveryAt;
  String? get lastRecordingRecoveryReason => _lastRecordingRecoveryReason;
  List<int> get knownSupportedFpsOptions =>
      List.unmodifiable(_supportedFpsOptionsForPreset(_resolutionPreset));
  List<int> get knownSupportedResolutionOptions {
    final unsupported = knownUnsupportedResolutionPresets;
    return List.unmodifiable(
      _safeResolutionOptions
          .where((resolution) =>
              !unsupported.contains(presetForResolution(resolution)))
          .toList(),
    );
  }
  Set<ResolutionPreset> get knownUnsupportedResolutionPresets {
    if (_activeCameraName.isEmpty) {
      return const <ResolutionPreset>{};
    }
    final key = _resolutionSupportCacheKey(_activeCameraName);
    return Set.unmodifiable(
      _unsupportedResolutionCache[key] ?? const <ResolutionPreset>{},
    );
  }

  // Debug logging helper
  void _log(String message) {
    if (enableDebugLogging) {
      debugPrint('[MotoCam] $message');
    }
  }

  static ResolutionPreset presetForResolution(int resolution) {
    if (resolution <= 480) {
      return ResolutionPreset.low;
    }
    if (resolution <= 720) {
      return ResolutionPreset.high;
    }
    if (resolution <= 1080) {
      return ResolutionPreset.veryHigh;
    }
    return ResolutionPreset.ultraHigh;
  }

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

  ResolutionPreset resolvePresetForRequestedResolution(int requestedResolution) {
    final requestedPreset = presetForResolution(requestedResolution);
    final unsupported = knownUnsupportedResolutionPresets;
    if (!unsupported.contains(requestedPreset)) {
      return requestedPreset;
    }

    final lowerOrEqual = _safeResolutionOptions
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

  int resolveAppliedResolutionForRequested(int requestedResolution) {
    return resolutionForPreset(
      resolvePresetForRequestedResolution(requestedResolution),
    );
  }

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
      _log('Failed to query cameras: $e');
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

  // Initialize camera
  Future<void> initializeCamera({
    ResolutionPreset? resolutionPreset,
    int? recordingFps,
    int? videoBitrateBps,
    bool? audioEnabled,
    String? preferredCameraName,
    int? segmentDurationMinutes,
    int? maxRollingSegments,
  }) async {
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
      if (segmentDurationMinutes != null) {
        _segmentDuration =
            Duration(minutes: segmentDurationMinutes.clamp(1, 10));
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

      // Request camera permission
      final cameraStatus = await Permission.camera.request();
      final microphoneStatus = _audioEnabled
          ? await Permission.microphone.request()
          : PermissionStatus.granted;
      if (Platform.isAndroid) {
        await Permission.videos.request();
        await Permission.notification.request();
      } else {
        await Permission.storage.request();
      }

      if (cameraStatus.isDenied || microphoneStatus.isDenied) {
        _log('Camera or microphone permission denied');
        _isInitialized = false;
        notifyListeners();
        return;
      }

      // Set up recordings directory
      await _setupRecordingsDirectory();

      final cameras = await getAvailableCameras(refresh: true);
      if (cameras.isEmpty) {
        _log('No cameras detected on this device');
        _isInitialized = false;
        notifyListeners();
        return;
      }
      final selectedCamera = _resolveCamera(cameras);
      _activeCameraName = selectedCamera.name;
      if (_preferredCameraName.isEmpty) {
        _preferredCameraName = selectedCamera.name;
      }

      final requestedPreset = _resolutionPreset;
      final requestedFps = _recordingFps;
      CameraController? initializedController;
      ResolutionPreset? initializedPreset;
      var initializedFps = requestedFps;

      for (final candidatePreset
          in _resolutionFallbackCandidates(requestedPreset)) {
        var presetInitialized = false;
        final supportedFps = _supportedFpsOptionsForPreset(candidatePreset);
        var candidateFps = initializedFps;
        if (!supportedFps.contains(candidateFps)) {
          candidateFps = supportedFps.last;
        }

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
        _isInitialized = false;
        _log('Unable to initialize camera for any preset on this device.');
        notifyListeners();
        return;
      }

      _controller = initializedController;
      _resolutionPreset = initializedPreset;
      _recordingFps = initializedFps;

      _isInitialized = true;
      _log('Camera initialized successfully');
      if (_resolutionPreset != requestedPreset) {
        _log(
            'Requested preset $requestedPreset is not supported; downgraded to $_resolutionPreset.');
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
      _isInitialized = false;
      notifyListeners();
      _log('Error initializing camera: $e');
    }
  }

  Future<bool> applyRecordingSettings({
    required ResolutionPreset resolutionPreset,
    required int recordingFps,
    required int videoBitrateBps,
    required bool audioEnabled,
    required String preferredCameraName,
    required int segmentDurationMinutes,
    required int maxRollingSegments,
  }) async {
    if (isRecording) {
      _log('Cannot apply recording settings while recording is active');
      return false;
    }

    final hasChanged = _resolutionPreset != resolutionPreset ||
        _recordingFps != recordingFps ||
        _videoBitrateBps != videoBitrateBps ||
      _audioEnabled != audioEnabled ||
      _preferredCameraName != preferredCameraName.trim() ||
      _segmentDuration.inMinutes != segmentDurationMinutes ||
      _maxRollingSegments != maxRollingSegments;

    if (!hasChanged) {
      return true;
    }

    _resolutionPreset = resolutionPreset;
    _recordingFps = recordingFps;
    _videoBitrateBps = videoBitrateBps;
    _audioEnabled = audioEnabled;
    _preferredCameraName = preferredCameraName.trim();
    _segmentDuration = Duration(minutes: segmentDurationMinutes.clamp(1, 10));
    _maxRollingSegments = maxRollingSegments.clamp(1, 120);
    await initializeCamera();
    return _isInitialized;
  }

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
      return const <ResolutionPreset>[ResolutionPreset.high, ResolutionPreset.medium, ResolutionPreset.low];
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
    final unsupported =
        Set<ResolutionPreset>.from(_unsupportedResolutionCache[key] ?? <ResolutionPreset>{});
    unsupported.add(preset);
    _unsupportedResolutionCache[key] = unsupported;
  }

  void _markResolutionSupported(String cameraName, ResolutionPreset preset) {
    final key = _resolutionSupportCacheKey(cameraName);
    final unsupported =
        Set<ResolutionPreset>.from(_unsupportedResolutionCache[key] ?? <ResolutionPreset>{});
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

  String _fpsCacheKeyForPreset(ResolutionPreset preset) =>
      '${preset.name}_${_audioEnabled ? 1 : 0}';

  Future<CameraController?> _tryInitializeController({
    required CameraDescription camera,
    required ResolutionPreset preset,
    required int fps,
  }) async {
    final controller = _buildController(
      camera: camera,
      preset: preset,
      fps: fps,
    );
    try {
      await controller.initialize();
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      return controller;
    } catch (e) {
      _log('Camera init failed for preset $preset at ${fps}fps: $e');
      try {
        await controller.dispose();
      } catch (_) {
        // Best-effort dispose after failed initialize.
      }
      return null;
    }
  }

  CameraController _buildController({
    required CameraDescription camera,
    required ResolutionPreset preset,
    required int fps,
  }) {
    try {
      return CameraController(
        camera,
        preset,
        enableAudio: _audioEnabled,
        fps: fps,
        videoBitrate: _videoBitrateBps,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
    } catch (e) {
      _log(
          'FPS-specific controller build failed for preset $preset at ${fps}fps, using default FPS. Error: $e');
      return CameraController(
        camera,
        preset,
        enableAudio: _audioEnabled,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
    }
  }

  // Set up recordings directory
  Future<void> _setupRecordingsDirectory() async {
    try {
      if (Platform.isAndroid) {
        final recordingsDir = await getTemporaryDirectory();

        if (!await recordingsDir.exists()) {
          await recordingsDir.create(recursive: true);
          _log('Created recordings directory: ${recordingsDir.path}');
        } else {
          _log('Recordings directory already exists: ${recordingsDir.path}');
        }

        _recordingsDirectory = recordingsDir.path;
        _log('Recordings directory set to: $_recordingsDirectory');
      } else if (Platform.isIOS) {
        // iOS: Use app documents directory
        final documentsDir = await getApplicationDocumentsDirectory();
        final recordingsDir =
            Directory('${documentsDir.path}/MotoCam Recordings');

        if (!await recordingsDir.exists()) {
          await recordingsDir.create(recursive: true);
          _log('Created iOS recordings directory: ${recordingsDir.path}');
        }

        _recordingsDirectory = recordingsDir.path;
        _log('iOS recordings directory set to: $_recordingsDirectory');
      } else {
        // Other platforms: Use app cache directory
        final cacheDir = await getApplicationCacheDirectory();
        _recordingsDirectory = cacheDir.path;
        _log('Using cache directory for recordings: $_recordingsDirectory');
      }
    } catch (e) {
      _log('Error setting up recordings directory: $e');
      // Fallback to app cache
      try {
        final cacheDir = await getApplicationCacheDirectory();
        _recordingsDirectory = cacheDir.path;
        _log('Fallback to cache directory: $_recordingsDirectory');
      } catch (fallbackError) {
        _log('Error setting up fallback cache directory: $fallbackError');
      }
    }
  }

  // Start recording
  Future<bool> startRecording() async {
    if (!_isInitialized ||
        _controller == null ||
        _recordingsDirectory == null) {
      _log('Camera not initialized or recordings directory not set');
      _log(
          'isInitialized: $_isInitialized, controller: $_controller, recordingsDir: $_recordingsDirectory');
      return false;
    }

    try {
      _sessionSegmentPaths.clear();
      _sessionSegmentTimeline.clear();
      _lockedSegmentPaths.clear();
      _pendingGalleryExports.clear();
      _pendingIncidentSegmentLocks = 0;
      _lastSegmentEndMs = 0;
      _recordingRecoveryCount = 0;
      _lastRecordingRecoveryAt = null;
      _lastRecordingRecoveryReason = null;
      _isStoppingRecording = false;
      _recordingStartTime = DateTime.now();
      _elapsedTime = Duration.zero;

      _log('Starting recording...');
      _log('Recording segments will be captured in ~5 minute chunks');

      final started = await _startVideoRecordingWithFallback();
      if (!started) {
        _state = RecordingState.idle;
        _recordingStartTime = null;
        _elapsedTime = Duration.zero;
        notifyListeners();
        return false;
      }

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
      notifyListeners();
      return true;
    } catch (e) {
      _log('Error starting recording: $e');
      _log('Stack trace: ${StackTrace.current}');
      return false;
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
    } catch (e) {
      _log('startVideoRecording failed at $_resolutionPreset/${_recordingFps}fps: $e');
    }

    final activeCamera = await _resolveActiveCameraDescription();
    if (activeCamera == null) {
      _log('Unable to resolve active camera for recording fallback.');
      return false;
    }

    final candidates = _resolutionFallbackCandidates(_resolutionPreset).skip(1);
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

      final previousController = _controller;
      _controller = candidateController;
      _resolutionPreset = candidatePreset;
      _recordingFps = candidateFps;
      _markResolutionSupported(activeCamera.name, candidatePreset);
      if (previousController != null && !identical(previousController, candidateController)) {
        await previousController.dispose();
      }
      notifyListeners();

      try {
        await candidateController.startVideoRecording();
        _log('Recording fallback succeeded at $_resolutionPreset/${_recordingFps}fps.');
        return true;
      } catch (e) {
        _log('Recording fallback failed at $candidatePreset/${candidateFps}fps: $e');
        _markResolutionUnsupported(activeCamera.name, candidatePreset);
      }
    }

    return false;
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

  Future<void> _rollSegmentIfNeeded() async {
    if (!isRecording || _isRollingSegment || _isStoppingRecording) {
      return;
    }

    _isRollingSegment = true;
    try {
      _log('Rolling recording segment after ${_segmentDuration.inMinutes} minutes');
      final file = await _controller!.stopVideoRecording();
      await _registerCompletedSegment(file.path);
      if (!_isStoppingRecording) {
        await _controller!.startVideoRecording();
        _armSegmentTimer();
      }
    } catch (e) {
      _log('Error while rolling segment: $e');
      if (!_isStoppingRecording && isRecording) {
        _armSegmentTimer();
      }
    } finally {
      _isRollingSegment = false;
    }
  }

  Future<bool> recoverRecordingPipeline({
    String reason = 'suspected-video-stall',
  }) async {
    if (!isRecording || _controller == null) {
      return false;
    }
    if (_isRollingSegment || _isStoppingRecording) {
      return false;
    }

    _isRollingSegment = true;
    try {
      _log('Attempting recording pipeline recovery: $reason');
      final file = await _controller!.stopVideoRecording();
      await _registerCompletedSegment(file.path);
      await _controller!.startVideoRecording();
      _armSegmentTimer();
      _recordingRecoveryCount++;
      _lastRecordingRecoveryAt = DateTime.now();
      _lastRecordingRecoveryReason = reason;
      _log('Recording pipeline recovery succeeded');
      notifyListeners();
      return true;
    } catch (e) {
      _log('Recording pipeline recovery failed: $e');
      return false;
    } finally {
      _isRollingSegment = false;
    }
  }

  Future<void> _registerCompletedSegment(String videoPath) async {
    _currentVideoPath = videoPath;
    _recordingsDirectory ??= File(videoPath).parent.path;
    _sessionSegmentPaths.add(videoPath);

    final startMs = _lastSegmentEndMs;
    final endMs = _recordingStartTime == null
        ? startMs
        : DateTime.now().difference(_recordingStartTime!).inMilliseconds;
    final normalizedEndMs = endMs >= startMs ? endMs : startMs;
    _sessionSegmentTimeline.add(
      SegmentTimelineEntry(
        path: videoPath,
        startMs: startMs,
        endMs: normalizedEndMs,
      ),
    );
    _lastSegmentEndMs = normalizedEndMs;

    if (_pendingIncidentSegmentLocks > 0) {
      _lockedSegmentPaths.add(videoPath);
      _pendingIncidentSegmentLocks--;
      _log('Incident lock applied to new segment: $videoPath');
    }

    while (_sessionSegmentPaths.length > _maxRollingSegments) {
      final removableIndex =
          _sessionSegmentPaths.indexWhere((path) => !_lockedSegmentPaths.contains(path));
      if (removableIndex < 0) {
        _log(
            'Loop limit exceeded, but all segments are locked. Skipping overwrite for safety.');
        break;
      }

      final oldestPath = _sessionSegmentPaths.removeAt(removableIndex);
      _lockedSegmentPaths.remove(oldestPath);
      _sessionSegmentTimeline.removeWhere((entry) => entry.path == oldestPath);
      try {
        final oldestFile = File(oldestPath);
        if (await oldestFile.exists()) {
          await oldestFile.delete();
          _log('Deleted oldest segment due to rolling limit: $oldestPath');
        }
        final dotIndex = oldestPath.lastIndexOf('.');
        final telemetryPath = dotIndex <= 0
            ? '$oldestPath.telemetry.json'
            : '${oldestPath.substring(0, dotIndex)}.telemetry.json';
        final telemetryFile = File(telemetryPath);
        if (await telemetryFile.exists()) {
          await telemetryFile.delete();
          _log('Deleted telemetry for rolled-out segment: $telemetryPath');
        }
      } catch (e) {
        _log('Failed deleting old rolling segment: $e');
      }
    }
  }

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

    if (protectCurrentSegment && isRecording) {
      _pendingIncidentSegmentLocks++;
    }

    _log(
        'Incident marked ($reason): locked $clampedPast previous segments, pending current lock: ${protectCurrentSegment && isRecording}');
    notifyListeners();
  }

  void _enqueueDeferredGalleryExport(Iterable<String> segmentPaths) {
    if (!Platform.isAndroid) {
      return;
    }

    _pendingGalleryExports.addAll(segmentPaths);
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
    while (_pendingGalleryExports.isNotEmpty) {
      final sourcePath = _pendingGalleryExports.removeAt(0);
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        _log('Skipping export for missing segment: $sourcePath');
        continue;
      }

      final fileName = sourcePath.split(Platform.pathSeparator).last;
      try {
        await platform.invokeMethod<String>('exportVideoToGallery', {
          'sourcePath': sourcePath,
          'displayName': fileName,
          'relativePath': _galleryRelativePath,
        });
        _log('Deferred gallery export completed: $fileName');
      } catch (e) {
        _log('Deferred export failed, trying media scan fallback: $e');
        await _scanMediaFile(sourcePath);
      }
    }
  }

  // Scan media file to make it visible in gallery
  Future<void> _scanMediaFile(String filePath) async {
    try {
      await platform.invokeMethod('scanMediaFile', {'path': filePath});
      _log('Media file scanned successfully: $filePath');
    } catch (e) {
      _log('Error scanning media file: $e');
    }
  }

  // Stop recording
  Future<String?> stopRecording() async {
    if (!isRecording) {
      _log('Not currently recording');
      return null;
    }

    try {
      _log('Stopping recording...');
      _isStoppingRecording = true;

      _segmentTimer?.cancel();
      _segmentTimer = null;

      var waitAttempts = 0;
      while (_isRollingSegment && waitAttempts < 20) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        waitAttempts++;
      }

      // Cancel timer
      _timerStream?.cancel();
      _timerStream = null;

      final file = await _controller!.stopVideoRecording();
      _state = RecordingState.stopped;
      _recordingStartTime = null;
      final cacheVideoPath = file.path;

      _log('Video recorded to cache: $cacheVideoPath');
      _log('File exists: ${await File(cacheVideoPath).exists()}');

      await _registerCompletedSegment(cacheVideoPath);

      // Keep original output paths and export to gallery asynchronously.
      _enqueueDeferredGalleryExport(List<String>.from(_sessionSegmentPaths));

      notifyListeners();
      return cacheVideoPath;
    } catch (e) {
      _log('Error stopping recording: $e');
      _log('Stack trace: ${StackTrace.current}');
      return null;
    } finally {
      _isStoppingRecording = false;
    }
  }

  // Get list of all recordings
  Future<List<FileSystemEntity>> getRecordings() async {
    if (_recordingsDirectory == null) return [];

    try {
      final dir = Directory(_recordingsDirectory!);
      if (!await dir.exists()) return [];

          final files = await dir.list(recursive: true, followLinks: false).toList();
      files.sort((a, b) => File(b.path)
          .statSync()
          .modified
          .compareTo(File(a.path).statSync().modified));
      return files;
    } catch (e) {
      _log('Error getting recordings: $e');
      return [];
    }
  }

  @override
  void dispose() {
    _segmentTimer?.cancel();
    _timerStream?.cancel();
    _timerController.close();
    _controller?.dispose();
    super.dispose();
  }
}
