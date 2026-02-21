// lib/features/camera/providers/camera_provider.dart

import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';

enum RecordingState { idle, recording, paused, stopped }

class CameraProvider extends ChangeNotifier {
  CameraController? _controller;
  RecordingState _state = RecordingState.idle;
  String? _currentVideoPath;
  bool _isInitialized = false;

  // Getters
  CameraController? get controller => _controller;
  RecordingState get state => _state;
  String? get currentVideoPath => _currentVideoPath;
  bool get isInitialized => _isInitialized;
  bool get isRecording => _state == RecordingState.recording;

  // Initialize camera
  Future<void> initializeCamera() async {
    try {
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
      notifyListeners();
    } catch (e) {
      debugPrint('Error initializing camera: $e');
    }
  }

  // Start recording
  Future<void> startRecording(String filePath) async {
    if (!_isInitialized || _controller == null) return;

    try {
      await _controller!.startVideoRecording();
      _state = RecordingState.recording;
      _currentVideoPath = filePath;
      notifyListeners();
    } catch (e) {
      debugPrint('Error starting recording: $e');
    }
  }

  // Stop recording
  Future<String?> stopRecording() async {
    if (!isRecording) return null;

    try {
      final file = await _controller!.stopVideoRecording();
      _state = RecordingState.stopped;
      notifyListeners();
      return file.path;
    } catch (e) {
      debugPrint('Error stopping recording: $e');
      return null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
}