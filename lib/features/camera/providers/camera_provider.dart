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

  static const List<int> _fpsCandidates = [24, 30, 60];

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
  List<int> get knownSupportedFpsOptions => List.unmodifiable(
      _supportedFpsCache[_fpsCacheKey(_resolutionPreset)] ?? _fpsCandidates);

  // Debug logging helper
  void _log(String message) {
    if (enableDebugLogging) {
      debugPrint('[MotoCam] $message');
    }
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
        return;
      }

      // Set up recordings directory
      await _setupRecordingsDirectory();

      final cameras = await getAvailableCameras(refresh: true);
      if (cameras.isEmpty) {
        _log('No cameras detected on this device');
        return;
      }
      final selectedCamera = _resolveCamera(cameras);
      _activeCameraName = selectedCamera.name;
      if (_preferredCameraName.isEmpty) {
        _preferredCameraName = selectedCamera.name;
      }

      final supportedFps = knownSupportedFpsOptions;
      if (!supportedFps.contains(_recordingFps)) {
        _recordingFps = supportedFps.last;
      }

      await _controller?.dispose();
      _controller = await _buildController(selectedCamera);

      try {
        await _controller!.initialize();
        await _controller!.lockCaptureOrientation(DeviceOrientation.portraitUp);
      } catch (e) {
        _log('Configured FPS failed on this device, retrying default FPS: $e');
        _markFpsUnsupported(_recordingFps);
        _recordingFps = _fallbackFps();
        await _controller?.dispose();
        _controller = CameraController(
          selectedCamera,
          _resolutionPreset,
          enableAudio: _audioEnabled,
          fps: _recordingFps,
          videoBitrate: _videoBitrateBps,
          imageFormatGroup: ImageFormatGroup.jpeg,
        );
        await _controller!.initialize();
        await _controller!.lockCaptureOrientation(DeviceOrientation.portraitUp);
      }

      _isInitialized = true;
      _log('Camera initialized successfully');
      _log('Resolution preset: $_resolutionPreset');
      _log('Target FPS: $_recordingFps');
      _log('Video bitrate bps: $_videoBitrateBps');
      _log('Audio enabled: $_audioEnabled');
      _log('Selected camera: ${cameraLabel(selectedCamera)}');
      _log('Recordings directory: $_recordingsDirectory');
      notifyListeners();
    } catch (e) {
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
    final key = _fpsCacheKey(preset);
    if (_supportedFpsCache.containsKey(key)) {
      return List.unmodifiable(_supportedFpsCache[key]!);
    }

    return List.unmodifiable(_fpsCandidates);
  }

  void _markFpsUnsupported(int fps) {
    final key = _fpsCacheKey(_resolutionPreset);
    final current = List<int>.from(_supportedFpsCache[key] ?? _fpsCandidates);
    current.remove(fps);
    if (current.isEmpty) {
      current.add(30);
    }
    _supportedFpsCache[key] = current;
  }

  int _fallbackFps() {
    final options =
        _supportedFpsCache[_fpsCacheKey(_resolutionPreset)] ?? _fpsCandidates;
    if (options.contains(30)) {
      return 30;
    }
    return options.last;
  }

  String _fpsCacheKey(ResolutionPreset preset) =>
      '${preset.name}_${_audioEnabled ? 1 : 0}';

  Future<CameraController> _buildController(CameraDescription camera) async {
    try {
      return CameraController(
        camera,
        _resolutionPreset,
        enableAudio: _audioEnabled,
        fps: _recordingFps,
        videoBitrate: _videoBitrateBps,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
    } catch (e) {
      _log('FPS-specific controller failed, using default FPS. Error: $e');
      return CameraController(
        camera,
        _resolutionPreset,
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
  Future<void> startRecording() async {
    if (!_isInitialized ||
        _controller == null ||
        _recordingsDirectory == null) {
      _log('Camera not initialized or recordings directory not set');
      _log(
          'isInitialized: $_isInitialized, controller: $_controller, recordingsDir: $_recordingsDirectory');
      return;
    }

    try {
      _sessionSegmentPaths.clear();
      _sessionSegmentTimeline.clear();
      _lockedSegmentPaths.clear();
      _pendingGalleryExports.clear();
      _pendingIncidentSegmentLocks = 0;
      _lastSegmentEndMs = 0;
      _isStoppingRecording = false;
      _recordingStartTime = DateTime.now();
      _elapsedTime = Duration.zero;

      _log('Starting recording...');
      _log('Recording segments will be captured in ~5 minute chunks');

      await _controller!.startVideoRecording();
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
    } catch (e) {
      _log('Error starting recording: $e');
      _log('Stack trace: ${StackTrace.current}');
    }
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
