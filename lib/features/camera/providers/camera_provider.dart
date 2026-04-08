// lib/features/camera/providers/camera_provider.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';

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
  static const String _galleryRelativePath = 'Movies/MotoCam/Recordings';
  static const String _androidPublicGalleryDirectory =
      '/storage/emulated/0/Movies/MotoCam/Recordings';

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
  Timer? _deferredMaintenanceTimer;
  bool _isRollingSegment = false;
  bool _isStoppingRecording = false;
  bool _isExportingToGallery = false;
  bool _isDeferredMaintenanceRunning = false;
  int _pendingIncidentSegmentLocks = 0;
  int _lastSegmentEndMs = 0;
  int _recordingRecoveryCount = 0;
  DateTime? _lastRecordingRecoveryAt;
  String? _lastRecordingRecoveryReason;
  int _lastRollStopMs = 0;
  int _lastRollRestartMs = 0;
  int _lastRollRegisterMs = 0;
  int _lastRollTotalMs = 0;
  DateTime? _lastRollAt;
  final List<int> _recentRollTotalMs = <int>[];

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
  int get segmentDurationSeconds => _segmentDuration.inSeconds;
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
  int get lastRollStopMs => _lastRollStopMs;
  int get lastRollRestartMs => _lastRollRestartMs;
  int get lastRollRegisterMs => _lastRollRegisterMs;
  int get lastRollTotalMs => _lastRollTotalMs;
  DateTime? get lastRollAt => _lastRollAt;
  List<int> get recentRollTotalMs => List.unmodifiable(_recentRollTotalMs);
  int get averageRollTotalMs {
    if (_recentRollTotalMs.isEmpty) {
      return 0;
    }
    final total = _recentRollTotalMs.reduce((a, b) => a + b);
    return (total / _recentRollTotalMs.length).round();
  }
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

  void _recordRollMetrics({
    required int stopMs,
    required int restartMs,
    required int registerMs,
    required int totalMs,
  }) {
    _lastRollStopMs = stopMs;
    _lastRollRestartMs = restartMs;
    _lastRollRegisterMs = registerMs;
    _lastRollTotalMs = totalMs;
    _lastRollAt = DateTime.now();
    _recentRollTotalMs.add(totalMs);
    if (_recentRollTotalMs.length > 10) {
      _recentRollTotalMs.removeAt(0);
    }
    notifyListeners();
  }

  bool _isPermissionGranted(PermissionStatus status) {
    return status.isGranted || status.isLimited;
  }

  Future<bool> _hasAndroidPublicStorageAccess() async {
    if (!Platform.isAndroid) {
      return true;
    }

    final manageStorageStatus = await Permission.manageExternalStorage.status;
    if (manageStorageStatus.isGranted) {
      return true;
    }

    final legacyStorageStatus = await Permission.storage.status;
    return _isPermissionGranted(legacyStorageStatus);
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

  ResolutionPreset resolvePresetForRequestedResolution(
      int requestedResolution) {
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
    int? segmentDurationSeconds,
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
      if (segmentDurationSeconds != null) {
        _segmentDuration =
            Duration(seconds: segmentDurationSeconds.clamp(5, 600));
      } else if (segmentDurationMinutes != null) {
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
        await Permission.manageExternalStorage.request();
        await Permission.storage.request();
        await Permission.videos.request();
        await Permission.notification.request();
      } else {
        await Permission.storage.request();
      }

      final hasStoragePermission =
          !Platform.isAndroid || await _hasAndroidPublicStorageAccess();

      if (!_isPermissionGranted(cameraStatus) ||
          !_isPermissionGranted(microphoneStatus) ||
          !hasStoragePermission) {
        _log('Camera, microphone, or public storage permission denied');
        _isInitialized = false;
        notifyListeners();
        return;
      }

      // Set up recordings directory
      await _setupRecordingsDirectory();
      if (_recordingsDirectory == null || _recordingsDirectory!.isEmpty) {
        _log('Recordings directory is unavailable; camera init aborted.');
        _isInitialized = false;
        notifyListeners();
        return;
      }

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
    required int segmentDurationSeconds,
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
        _segmentDuration.inSeconds != segmentDurationSeconds ||
        _maxRollingSegments != maxRollingSegments;

    if (!hasChanged) {
      return true;
    }

    _resolutionPreset = resolutionPreset;
    _recordingFps = recordingFps;
    _videoBitrateBps = videoBitrateBps;
    _audioEnabled = audioEnabled;
    _preferredCameraName = preferredCameraName.trim();
    _segmentDuration = Duration(seconds: segmentDurationSeconds.clamp(5, 600));
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
      return const <ResolutionPreset>[
        ResolutionPreset.high,
        ResolutionPreset.medium,
        ResolutionPreset.low
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
        _unsupportedResolutionCache[key] ?? <ResolutionPreset>{});
    unsupported.add(preset);
    _unsupportedResolutionCache[key] = unsupported;
  }

  void _markResolutionSupported(String cameraName, ResolutionPreset preset) {
    final key = _resolutionSupportCacheKey(cameraName);
    final unsupported = Set<ResolutionPreset>.from(
        _unsupportedResolutionCache[key] ?? <ResolutionPreset>{});
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
      try {
        await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      } catch (lockError) {
        _log('Capture orientation lock skipped on this device: $lockError');
      }
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
    if (Platform.isAndroid) {
      final hasStorageAccess = await _hasAndroidPublicStorageAccess();
      if (!hasStorageAccess) {
        _recordingsDirectory = null;
        _log(
            'Missing Android public storage access for $_androidPublicGalleryDirectory');
        return;
      }

      try {
        final recordingsDir = Directory(_androidPublicGalleryDirectory);
        if (!await recordingsDir.exists()) {
          await recordingsDir.create(recursive: true);
          _log('Created Android recordings directory: ${recordingsDir.path}');
        } else {
          _log('Android recordings directory exists: ${recordingsDir.path}');
        }
        _recordingsDirectory = recordingsDir.path;
        _log('Recordings directory set to: $_recordingsDirectory');
      } catch (e) {
        _recordingsDirectory = null;
        _log('Failed to initialize Android recordings directory: $e');
      }
      return;
    }

    try {
      final Directory baseDirectory;
      if (Platform.isIOS) {
        baseDirectory = await getApplicationDocumentsDirectory();
      } else {
        baseDirectory = await getApplicationSupportDirectory();
      }

      final recordingsDir = Directory(
        '${baseDirectory.path}${Platform.pathSeparator}MotoCam Recordings',
      );

      if (!await recordingsDir.exists()) {
        await recordingsDir.create(recursive: true);
        _log('Created recordings directory: ${recordingsDir.path}');
      } else {
        _log('Recordings directory already exists: ${recordingsDir.path}');
      }

      _recordingsDirectory = recordingsDir.path;
      _log('Recordings directory set to: $_recordingsDirectory');
    } catch (e) {
      _log('Error setting up recordings directory: $e');
      // Fallback to app cache
      try {
        final cacheDir = await getApplicationCacheDirectory();
        final fallbackDir = Directory(
          '${cacheDir.path}${Platform.pathSeparator}MotoCam Recordings',
        );
        if (!await fallbackDir.exists()) {
          await fallbackDir.create(recursive: true);
        }
        _recordingsDirectory = fallbackDir.path;
        _log('Fallback to cache directory: $_recordingsDirectory');
      } catch (fallbackError) {
        _log('Error setting up fallback cache directory: $fallbackError');
      }
    }
  }

  String _normalizePath(String path) {
    var normalized = path.replaceAll('\\', Platform.pathSeparator);
    normalized = normalized.replaceAll('/', Platform.pathSeparator);
    while (
        normalized.length > 1 && normalized.endsWith(Platform.pathSeparator)) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  bool _isPathInsideDirectory(String filePath, String directoryPath) {
    final normalizedFilePath = _normalizePath(filePath);
    final normalizedDirectoryPath = _normalizePath(directoryPath);
    if (normalizedFilePath == normalizedDirectoryPath) {
      return true;
    }
    return normalizedFilePath
        .startsWith('$normalizedDirectoryPath${Platform.pathSeparator}');
  }

  String _fileNameFromPath(String path) {
    final parts = path.split(Platform.pathSeparator);
    if (parts.isEmpty) {
      return path;
    }
    return parts.last;
  }

  Future<String> _buildUniqueSegmentPath(
    String directoryPath,
    String fileName,
  ) async {
    final resolvedName = fileName.trim().isEmpty
        ? 'segment_${DateTime.now().millisecondsSinceEpoch}.mp4'
        : fileName;
    final dotIndex = resolvedName.lastIndexOf('.');
    final baseName =
        dotIndex <= 0 ? resolvedName : resolvedName.substring(0, dotIndex);
    final extension = dotIndex <= 0 ? '' : resolvedName.substring(dotIndex);

    var suffix = 0;
    while (true) {
      final candidateName =
          suffix == 0 ? resolvedName : '${baseName}_$suffix$extension';
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
      _fileNameFromPath(sourcePath),
    );

    try {
      final movedFile = await sourceFile.rename(targetPath);
      final movedPath = movedFile.path;
      if (await _isSegmentFileReady(movedPath)) {
        _log('Moved segment into persistent directory: $movedPath');
        return movedPath;
      }

      _log(
          'Moved segment failed readiness check, keeping source path: $movedPath');
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
            'Copied segment failed readiness check, keeping source path: $copiedPath');
        await copiedFile.delete();
        return sourcePath;
      } catch (copyError) {
        _log('Failed to persist segment into recordings directory: $copyError');
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
      _log(
          'Recording segments will be captured every ${_segmentDuration.inSeconds}s');

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
      _log(
          'startVideoRecording failed at $_resolutionPreset/${_recordingFps}fps: $e');
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
      if (previousController != null &&
          !identical(previousController, candidateController)) {
        await previousController.dispose();
      }
      notifyListeners();

      try {
        await candidateController.startVideoRecording();
        _log(
            'Recording fallback succeeded at $_resolutionPreset/${_recordingFps}fps.');
        return true;
      } catch (e) {
        _log(
            'Recording fallback failed at $candidatePreset/${candidateFps}fps: $e');
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
    final rollStartedAt = DateTime.now();
    try {
      _log(
          'Rolling recording segment after ${_segmentDuration.inSeconds} seconds');
      final stopStartedAt = DateTime.now();
      final file = await _controller!.stopVideoRecording();
      final stopElapsedMs = DateTime.now().difference(stopStartedAt).inMilliseconds;
      var restartElapsedMs = 0;

      if (!_isStoppingRecording) {
        final restartStartedAt = DateTime.now();
        await _controller!.startVideoRecording();
        _armSegmentTimer();
        restartElapsedMs =
            DateTime.now().difference(restartStartedAt).inMilliseconds;
        _log('Segment roll restart completed in ${restartElapsedMs}ms');
      }

      final registerStartedAt = DateTime.now();
      await _registerCompletedSegment(
        file.path,
        deferMaintenance: true,
      );
      final registerElapsedMs =
          DateTime.now().difference(registerStartedAt).inMilliseconds;
      final totalElapsedMs = DateTime.now().difference(rollStartedAt).inMilliseconds;
      _recordRollMetrics(
        stopMs: stopElapsedMs,
        restartMs: restartElapsedMs,
        registerMs: registerElapsedMs,
        totalMs: totalElapsedMs,
      );
      _log('Segment roll timings: stop=${stopElapsedMs}ms, register=${registerElapsedMs}ms, total=${totalElapsedMs}ms');
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

  Future<void> _registerCompletedSegment(
    String videoPath, {
    bool deferMaintenance = false,
  }) async {
    final persistedVideoPath =
        await _persistSegmentToRecordingsDirectory(videoPath);
    if (!await _isSegmentFileReady(persistedVideoPath)) {
      _log('Skipping segment registration due to unreadable file: '
          '$persistedVideoPath');
      return;
    }

    _currentVideoPath = persistedVideoPath;
    _recordingsDirectory ??= File(persistedVideoPath).parent.path;
    _sessionSegmentPaths.add(persistedVideoPath);

    final startMs = _lastSegmentEndMs;
    final endMs = _recordingStartTime == null
        ? startMs
        : DateTime.now().difference(_recordingStartTime!).inMilliseconds;
    final normalizedEndMs = endMs >= startMs ? endMs : startMs;
    _sessionSegmentTimeline.add(
      SegmentTimelineEntry(
        path: persistedVideoPath,
        startMs: startMs,
        endMs: normalizedEndMs,
      ),
    );
    _lastSegmentEndMs = normalizedEndMs;

    if (_pendingIncidentSegmentLocks > 0) {
      _lockedSegmentPaths.add(persistedVideoPath);
      _pendingIncidentSegmentLocks--;
      _log('Incident lock applied to new segment: $persistedVideoPath');
    }

    while (_sessionSegmentPaths.length > _maxRollingSegments) {
      final removableIndex = _sessionSegmentPaths
          .indexWhere((path) => !_lockedSegmentPaths.contains(path));
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
      } catch (e) {
        _log('Failed deleting old rolling segment: $e');
      }
    }

    if (Platform.isAndroid) {
      if (deferMaintenance) {
        Future<void>.delayed(const Duration(milliseconds: 700), () {
          unawaited(_scanMediaFile(persistedVideoPath));
        });
      } else {
        unawaited(_scanMediaFile(persistedVideoPath));
      }
    }

    if (deferMaintenance) {
      _queueDeferredMaintenance();
    } else {
      await _enforceRecordingRetention(includeTelemetryPrune: true);
    }
  }

  void _queueDeferredMaintenance() {
    _deferredMaintenanceTimer?.cancel();
    _deferredMaintenanceTimer = Timer(const Duration(seconds: 2), () async {
      if (_isDeferredMaintenanceRunning || _isStoppingRecording) {
        return;
      }
      _isDeferredMaintenanceRunning = true;
      try {
        await _enforceRecordingRetention(includeTelemetryPrune: false);
      } finally {
        _isDeferredMaintenanceRunning = false;
      }
    });
  }

  bool _isVideoFilePath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.avi');
  }

  Future<void> _enforceRecordingRetention({
    required bool includeTelemetryPrune,
  }) async {
    final recordingsDirectoryPath = _recordingsDirectory;
    if (recordingsDirectoryPath == null || recordingsDirectoryPath.isEmpty) {
      return;
    }

    final recordingsDir = Directory(recordingsDirectoryPath);
    if (!await recordingsDir.exists()) {
      return;
    }

    if (_sessionSegmentPaths.length <= _maxRollingSegments) {
      if (includeTelemetryPrune) {
        await _pruneOrphanTelemetryFiles(recordingsDir);
      }
      return;
    }

    final videoFiles = <File>[];
    await for (final entity
        in recordingsDir.list(recursive: true, followLinks: false)) {
      if (entity is! File || !_isVideoFilePath(entity.path)) {
        continue;
      }
      videoFiles.add(entity);
    }

    if (videoFiles.length > _maxRollingSegments) {
      videoFiles.sort((a, b) {
        final aTime = a.statSync().modified;
        final bTime = b.statSync().modified;
        return aTime.compareTo(bTime);
      });

      final removeCount = videoFiles.length - _maxRollingSegments;
      final removedPaths = <String>{};

      for (final file in videoFiles.take(removeCount)) {
        final path = file.path;
        try {
          if (await file.exists()) {
            await file.delete();
            removedPaths.add(path);
            _log('Deleted old recording due to retention policy: $path');
          }
        } catch (e) {
          _log('Failed deleting old recording $path: $e');
        }
      }

      if (removedPaths.isNotEmpty) {
        _sessionSegmentPaths.removeWhere((path) => removedPaths.contains(path));
        _lockedSegmentPaths.removeWhere((path) => removedPaths.contains(path));
        _sessionSegmentTimeline
            .removeWhere((entry) => removedPaths.contains(entry.path));
        _pendingGalleryExports
            .removeWhere((path) => removedPaths.contains(path));

        final currentPath = _currentVideoPath;
        if (currentPath != null && removedPaths.contains(currentPath)) {
          _currentVideoPath = _sessionSegmentPaths.isNotEmpty
              ? _sessionSegmentPaths.last
              : null;
        }
      }
    }

    if (includeTelemetryPrune) {
      await _pruneOrphanTelemetryFiles(recordingsDir);
    }
  }

  Future<void> _pruneOrphanTelemetryFiles(Directory recordingsDir) async {
    await for (final entity
        in recordingsDir.list(recursive: true, followLinks: false)) {
      if (entity is! File ||
          !entity.path.toLowerCase().endsWith('.telemetry.json')) {
        continue;
      }

      try {
        final raw = await entity.readAsString();
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final segmentPaths =
            (json['segmentPaths'] as List<dynamic>? ?? const <dynamic>[])
                .map((value) => value.toString().trim())
                .where((path) => path.isNotEmpty)
                .toList();

        if (segmentPaths.isEmpty) {
          await entity.delete();
          _log('Deleted telemetry with no segment paths: ${entity.path}');
          continue;
        }

        var hasAnyExistingSegment = false;
        for (final segmentPath in segmentPaths) {
          if (await File(segmentPath).exists()) {
            hasAnyExistingSegment = true;
            break;
          }
        }

        if (!hasAnyExistingSegment) {
          await entity.delete();
          _log(
              'Deleted telemetry with no remaining segment files: ${entity.path}');
        }
      } catch (_) {
        // Skip malformed telemetry cleanup to avoid accidental data loss.
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

    for (final rawPath in segmentPaths) {
      final sourcePath = rawPath.trim();
      if (sourcePath.isEmpty) {
        continue;
      }

      if (_isPathInsideDirectory(sourcePath, _androidPublicGalleryDirectory)) {
        unawaited(_scanMediaFile(sourcePath));
      } else {
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
        final fallbackPath =
            await _copySegmentToAndroidPublicGallery(sourcePath);
        if (fallbackPath != null) {
          await _scanMediaFile(fallbackPath);
        } else {
          await _scanMediaFile(sourcePath);
        }
      }
    }
  }

  Future<String?> _copySegmentToAndroidPublicGallery(String sourcePath) async {
    if (!Platform.isAndroid) {
      return null;
    }

    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      return null;
    }

    try {
      final galleryDirectory = Directory(_androidPublicGalleryDirectory);
      if (!await galleryDirectory.exists()) {
        await galleryDirectory.create(recursive: true);
      }

      final targetPath = await _buildUniqueSegmentPath(
        galleryDirectory.path,
        _fileNameFromPath(sourcePath),
      );
      final copied = await sourceFile.copy(targetPath);
      _log('Copied segment to public gallery fallback: ${copied.path}');
      return copied.path;
    } catch (e) {
      _log('Public gallery fallback copy failed: $e');
      return null;
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

      String? cacheVideoPath;
      try {
        final file = await _controller!.stopVideoRecording();
        cacheVideoPath = file.path;
      } on CameraException catch (e) {
        // Race safety: when recording already stopped at plugin level, preserve
        // session continuity and let caller persist telemetry for known segments.
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
      _recordingStartTime = null;

      if (cacheVideoPath != null && cacheVideoPath.isNotEmpty) {
        _log('Video stop candidate path: $cacheVideoPath');
        _log('File ready: ${await _isSegmentFileReady(cacheVideoPath)}');

        if (!_sessionSegmentPaths.contains(cacheVideoPath)) {
          await _registerCompletedSegment(cacheVideoPath);
        } else {
          _currentVideoPath = cacheVideoPath;
        }
      }

      final finalVideoPath = await _resolveReadyFinalVideoPath(
        cacheVideoPath: cacheVideoPath,
      );
      _log('Final persisted video path: $finalVideoPath');

      // Keep original output paths and export to gallery asynchronously.
      if (_sessionSegmentPaths.isNotEmpty) {
        _enqueueDeferredGalleryExport(List<String>.from(_sessionSegmentPaths));
      }

      await _enforceRecordingRetention(includeTelemetryPrune: true);

      notifyListeners();
      return finalVideoPath;
    } catch (e) {
      _state = RecordingState.stopped;
      _recordingStartTime = null;
      notifyListeners();
      _log('Error stopping recording: $e');
      _log('Stack trace: ${StackTrace.current}');
      if (_sessionSegmentPaths.isNotEmpty) {
        return _sessionSegmentPaths.last;
      }
      return _currentVideoPath;
    } finally {
      _isStoppingRecording = false;
    }
  }

  // Get list of all recordings
  Future<List<FileSystemEntity>> getRecordings() async {
    if (_recordingsDirectory == null) {
      await _setupRecordingsDirectory();
    }
    if (_recordingsDirectory == null) return [];

    try {
      final files = <FileSystemEntity>[];
      final seenPaths = <String>{};
      await _appendFilesFromDirectory(
        files: files,
        seenPaths: seenPaths,
        directoryPath: _recordingsDirectory,
      );

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

      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
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

  Future<void> releaseCameraIfIdle() async {
    if (isRecording || _isStoppingRecording) {
      return;
    }

    final previousController = _controller;
    if (previousController == null && !_isInitialized) {
      return;
    }

    _controller = null;
    _isInitialized = false;
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

  @override
  void dispose() {
    _segmentTimer?.cancel();
    _deferredMaintenanceTimer?.cancel();
    _timerStream?.cancel();
    _timerController.close();
    _controller?.dispose();
    super.dispose();
  }
}
