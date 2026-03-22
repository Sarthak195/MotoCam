import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum RecordingQuality {
  low,
  medium,
  high,
  veryHigh,
  ultraHigh,
}

extension RecordingQualityX on RecordingQuality {
  ResolutionPreset toResolutionPreset() {
    switch (this) {
      case RecordingQuality.low:
        return ResolutionPreset.low;
      case RecordingQuality.medium:
        return ResolutionPreset.medium;
      case RecordingQuality.high:
        return ResolutionPreset.high;
      case RecordingQuality.veryHigh:
        return ResolutionPreset.veryHigh;
      case RecordingQuality.ultraHigh:
        return ResolutionPreset.ultraHigh;
    }
  }

  String get label {
    switch (this) {
      case RecordingQuality.low:
        return 'Low (480p)';
      case RecordingQuality.medium:
        return 'Medium (720p)';
      case RecordingQuality.high:
        return 'High (1080p)';
      case RecordingQuality.veryHigh:
        return 'Very High';
      case RecordingQuality.ultraHigh:
        return 'Ultra High';
    }
  }

  static RecordingQuality fromName(String? value) {
    for (final quality in RecordingQuality.values) {
      if (quality.name == value) {
        return quality;
      }
    }
    return RecordingQuality.medium;
  }
}

class AppSettingsProvider extends ChangeNotifier {
  static const _qualityKey = 'recording_quality';
  static const _fpsKey = 'recording_fps';
  static const _videoBitrateMbpsKey = 'video_bitrate_mbps';
  static const _audioEnabledKey = 'recording_audio_enabled';
  static const _speedRefreshMsKey = 'speed_refresh_ms';

  static const List<int> bitrateOptionsMbps = [4, 8, 12, 16];

  RecordingQuality _recordingQuality = RecordingQuality.medium;
  int _recordingFps = 30;
  int _videoBitrateMbps = 8;
  bool _audioEnabled = true;
  int _speedRefreshMs = 100;
  bool _isLoaded = false;

  RecordingQuality get recordingQuality => _recordingQuality;
  int get recordingFps => _recordingFps;
  int get videoBitrateMbps => _videoBitrateMbps;
  bool get audioEnabled => _audioEnabled;
  int get speedRefreshMs => _speedRefreshMs;
  bool get isLoaded => _isLoaded;

  Future<void> load() async {
    if (_isLoaded) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    _recordingQuality =
        RecordingQualityX.fromName(prefs.getString(_qualityKey));
    _recordingFps = _clampFps(prefs.getInt(_fpsKey) ?? 30);
    _videoBitrateMbps =
        _clampVideoBitrateMbps(prefs.getInt(_videoBitrateMbpsKey) ?? 8);
    _audioEnabled = prefs.getBool(_audioEnabledKey) ?? true;
    _speedRefreshMs =
        _clampSpeedRefreshMs(prefs.getInt(_speedRefreshMsKey) ?? 100);
    _isLoaded = true;
    notifyListeners();
  }

  Future<void> updateRecordingQuality(RecordingQuality quality) async {
    if (_recordingQuality == quality) {
      return;
    }
    _recordingQuality = quality;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_qualityKey, quality.name);
  }

  Future<void> updateRecordingFps(int fps) async {
    final clampedFps = _clampFps(fps);
    if (_recordingFps == clampedFps) {
      return;
    }
    _recordingFps = clampedFps;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_fpsKey, _recordingFps);
  }

  Future<void> updateVideoBitrateMbps(int value) async {
    final clamped = _clampVideoBitrateMbps(value);
    if (_videoBitrateMbps == clamped) {
      return;
    }
    _videoBitrateMbps = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_videoBitrateMbpsKey, _videoBitrateMbps);
  }

  Future<void> updateAudioEnabled(bool enabled) async {
    if (_audioEnabled == enabled) {
      return;
    }
    _audioEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_audioEnabledKey, enabled);
  }

  Future<void> updateSpeedRefreshMs(int milliseconds) async {
    final clamped = _clampSpeedRefreshMs(milliseconds);
    if (_speedRefreshMs == clamped) {
      return;
    }
    _speedRefreshMs = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_speedRefreshMsKey, _speedRefreshMs);
  }

  int _clampFps(int fps) {
    if (fps < 24) return 24;
    if (fps > 60) return 60;
    return fps;
  }

  int _clampSpeedRefreshMs(int value) {
    if (value < 100) return 100;
    if (value > 1000) return 1000;
    return value;
  }

  int _clampVideoBitrateMbps(int value) {
    if (bitrateOptionsMbps.contains(value)) {
      return value;
    }
    return 8;
  }
}
