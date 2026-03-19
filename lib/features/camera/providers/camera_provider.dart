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

  // Debug logging helper
  void _log(String message) {
    if (enableDebugLogging) {
      debugPrint('[MotoCam] $message');
    }
  }

  // Initialize camera
  Future<void> initializeCamera() async {
    try {
      // Request camera permission
      final cameraStatus = await Permission.camera.request();
      final microphoneStatus = await Permission.microphone.request();
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

      _controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: true,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _controller!.initialize();
      _isInitialized = true;
      _log('Camera initialized successfully');
      _log('Recordings directory: $_recordingsDirectory');
      notifyListeners();
    } catch (e) {
      _log('Error initializing camera: $e');
    }
  }

  // Set up recordings directory
  Future<void> _setupRecordingsDirectory() async {
    try {
      if (Platform.isAndroid) {
        // Android: Try to save to /storage/emulated/0/MotoCam Recordings/
        final externalStoragePath = '/storage/emulated/0';
        final recordingsDir = Directory('$externalStoragePath/MotoCam Recordings');
        
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
        final recordingsDir = Directory('${documentsDir.path}/MotoCam Recordings');
        
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
    if (!_isInitialized || _controller == null || _recordingsDirectory == null) {
      _log('Camera not initialized or recordings directory not set');
      _log('isInitialized: $_isInitialized, controller: $_controller, recordingsDir: $_recordingsDirectory');
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
      
      // Start timer to update elapsed time every 100ms
      _timerStream?.cancel();
      _timerStream = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (_recordingStartTime != null && _state == RecordingState.recording) {
          _elapsedTime = DateTime.now().difference(_recordingStartTime!);
          _timerController.add(_elapsedTime);
          notifyListeners();
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
          final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
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
      files.sort((a, b) => File(b.path).statSync().modified.compareTo(File(a.path).statSync().modified));
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