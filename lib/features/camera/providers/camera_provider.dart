// lib/features/camera/providers/camera_provider.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:async';

enum RecordingState { idle, recording, paused, stopped }

class CameraProvider extends ChangeNotifier {
  CameraProvider({this.enableDebugLogging = false});

  static const platform = MethodChannel('com.example.motocam/media');

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
  final Map<String, List<int>> _supportedFpsCache = {};

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
  List<int> get knownSupportedFpsOptions => List.unmodifiable(
      _supportedFpsCache[_fpsCacheKey(_resolutionPreset)] ?? _fpsCandidates);

  // Debug logging helper
  void _log(String message) {
    if (enableDebugLogging) {
      debugPrint('[MotoCam] $message');
    }
  }

  // Initialize camera
  Future<void> initializeCamera({
    ResolutionPreset? resolutionPreset,
    int? recordingFps,
    int? videoBitrateBps,
    bool? audioEnabled,
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

      // Request camera permission
      final cameraStatus = await Permission.camera.request();
      final microphoneStatus = _audioEnabled
          ? await Permission.microphone.request()
          : PermissionStatus.granted;
      await Permission.storage.request();
      await Permission.manageExternalStorage.request();

      if (cameraStatus.isDenied || microphoneStatus.isDenied) {
        _log('Camera or microphone permission denied');
        return;
      }

      // Set up recordings directory
      await _setupRecordingsDirectory();

      final cameras = await availableCameras();
      final backCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      );

      final supportedFps = knownSupportedFpsOptions;
      if (!supportedFps.contains(_recordingFps)) {
        _recordingFps = supportedFps.last;
      }

      await _controller?.dispose();
      _controller = await _buildController(backCamera);

      try {
        await _controller!.initialize();
      } catch (e) {
        _log('Configured FPS failed on this device, retrying default FPS: $e');
        _markFpsUnsupported(_recordingFps);
        _recordingFps = _fallbackFps();
        await _controller?.dispose();
        _controller = CameraController(
          backCamera,
          _resolutionPreset,
          enableAudio: _audioEnabled,
          fps: _recordingFps,
          videoBitrate: _videoBitrateBps,
          imageFormatGroup: ImageFormatGroup.jpeg,
        );
        await _controller!.initialize();
      }

      _isInitialized = true;
      _log('Camera initialized successfully');
      _log('Resolution preset: $_resolutionPreset');
      _log('Target FPS: $_recordingFps');
      _log('Video bitrate bps: $_videoBitrateBps');
      _log('Audio enabled: $_audioEnabled');
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
  }) async {
    if (isRecording) {
      _log('Cannot apply recording settings while recording is active');
      return false;
    }

    final hasChanged = _resolutionPreset != resolutionPreset ||
        _recordingFps != recordingFps ||
        _videoBitrateBps != videoBitrateBps ||
        _audioEnabled != audioEnabled;

    if (!hasChanged) {
      return true;
    }

    _resolutionPreset = resolutionPreset;
    _recordingFps = recordingFps;
    _videoBitrateBps = videoBitrateBps;
    _audioEnabled = audioEnabled;
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
        // Android: Try to save to /storage/emulated/0/MotoCam Recordings/
        final externalStoragePath = '/storage/emulated/0';
        final recordingsDir =
            Directory('$externalStoragePath/MotoCam Recordings');

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
      // Generate a unique filename with timestamp
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final fileName = 'motocam_$timestamp.mp4';

      _currentVideoPath = fileName; // Store filename for UI display
      _recordingStartTime = DateTime.now();
      _elapsedTime = Duration.zero;

      _log('Starting recording...');
      _log('Recording will be saved to: $_recordingsDirectory/$fileName');

      await _controller!.startVideoRecording();
      _state = RecordingState.recording;

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
      // Cancel timer
      _timerStream?.cancel();
      _timerStream = null;

      final file = await _controller!.stopVideoRecording();
      _state = RecordingState.stopped;
      _recordingStartTime = null;
      final cacheVideoPath = file.path;

      _log('Video recorded to cache: $cacheVideoPath');
      _log('File exists: ${await File(cacheVideoPath).exists()}');

      // Ensure recordings directory is set
      if (_recordingsDirectory == null) {
        _log('Error: Recordings directory not set');
        notifyListeners();
        return cacheVideoPath;
      }

      // Move video from cache to MotoCam Recordings folder
      try {
        final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
        final fileName = 'motocam_$timestamp.mp4';
        final finalPath = '$_recordingsDirectory/$fileName';

        _log('Moving video from cache to: $finalPath');

        final sourceFile = File(cacheVideoPath);
        final movedFile = await sourceFile.rename(finalPath);

        _log('✓ Video successfully moved to: $finalPath');

        // Verify file exists at new location
        final exists = await movedFile.exists();
        _log('File exists at destination: $exists');

        // Get file size
        try {
          final fileSize = await movedFile.length();
          _log('File size: ${(fileSize / 1024 / 1024).toStringAsFixed(2)} MB');
        } catch (e) {
          _log('Could not get file size: $e');
        }

        // Scan the media file to make it visible in gallery
        await _scanMediaFile(finalPath);

        notifyListeners();
        return finalPath;
      } catch (moveError) {
        _log('Error moving file (will try copy): $moveError');

        // Fallback: try copying the file
        try {
          final timestamp =
              DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
          final fileName = 'motocam_$timestamp.mp4';
          final finalPath = '$_recordingsDirectory/$fileName';

          _log('Attempting copy fallback to: $finalPath');

          final sourceFile = File(cacheVideoPath);
          final copiedFile = await sourceFile.copy(finalPath);

          _log('✓ Video successfully copied to: $finalPath');

          // Verify file exists at new location
          final exists = await copiedFile.exists();
          _log('File exists at destination: $exists');

          // Scan the media file to make it visible in gallery
          await _scanMediaFile(finalPath);

          notifyListeners();
          return finalPath;
        } catch (copyError) {
          _log('Error copying file: $copyError');
          _log('Returning original cache path: $cacheVideoPath');
          notifyListeners();
          return cacheVideoPath;
        }
      }
    } catch (e) {
      _log('Error stopping recording: $e');
      _log('Stack trace: ${StackTrace.current}');
      return null;
    }
  }

  // Get list of all recordings
  Future<List<FileSystemEntity>> getRecordings() async {
    if (_recordingsDirectory == null) return [];

    try {
      final dir = Directory(_recordingsDirectory!);
      if (!await dir.exists()) return [];

      final files = await dir.list().toList();
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
    _timerStream?.cancel();
    _timerController.close();
    _controller?.dispose();
    super.dispose();
  }
}
