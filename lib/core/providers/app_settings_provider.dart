import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum QualityPresetTier { balanced, highDetail }

enum IncidentSensitivity { low, medium, high }

class RecordingQualityProfile {
  const RecordingQualityProfile({
    required this.id,
    required this.resolution,
    required this.fps,
    required this.bitrateMbps,
    required this.tier,
  });

  final String id;
  final int resolution;
  final int fps;
  final int bitrateMbps;
  final QualityPresetTier tier;

  String get label => '$resolution''p / $fps FPS / $bitrateMbps Mbps';
}

/// Persisted user preferences for recording quality, segment duration,
/// incident sensitivity, and camera selection.
///
/// Settings are backed by [SharedPreferences] and are loaded asynchronously
/// via [load].  The [isLoaded] flag indicates whether the initial read has
/// completed; UI code should wait for this before reading values.
class AppSettingsProvider extends ChangeNotifier {
  static const _qualityKey = 'recording_quality';
  static const _qualityProfileIdKey = 'recording_quality_profile_id';
  static const _resolutionKey = 'recording_resolution_p';
  static const _fpsKey = 'recording_fps';
  static const _videoBitrateMbpsKey = 'video_bitrate_mbps';
  static const _audioEnabledKey = 'recording_audio_enabled';
  static const _speedRefreshMsKey = 'speed_refresh_ms';
  static const _segmentDurationSecondsKey =
      'dashcam_segment_duration_seconds';
  static const _segmentMinutesKey = 'dashcam_segment_minutes';
  static const _loopSegmentsKey = 'dashcam_loop_segment_count';
  static const _incidentSensitivityKey = 'incident_sensitivity';
  static const _cameraNameKey = 'camera_name';

  static const List<int> bitrateOptionsMbps = [4, 8, 12, 16];
  static const List<int> resolutionOptions = [480, 720, 1080, 2160];
  static const List<int> segmentDurationOptionsSeconds = [
    5,
    10,
    15,
    30,
    60,
    120,
    180,
    300,
    600,
  ];
  static const List<int> loopSegmentCountOptions = [6, 12, 18, 24, 36, 48];
  static const String customQualityProfileId = 'custom';
  static const List<RecordingQualityProfile> qualityProfiles = [
    RecordingQualityProfile(
      id: '720p_30_4',
      resolution: 720,
      fps: 30,
      bitrateMbps: 4,
      tier: QualityPresetTier.balanced,
    ),
    RecordingQualityProfile(
      id: '1080p_30_8',
      resolution: 1080,
      fps: 30,
      bitrateMbps: 8,
      tier: QualityPresetTier.balanced,
    ),
    RecordingQualityProfile(
      id: '1080p_60_12',
      resolution: 1080,
      fps: 60,
      bitrateMbps: 12,
      tier: QualityPresetTier.balanced,
    ),
    RecordingQualityProfile(
      id: '2160p_24_16',
      resolution: 2160,
      fps: 24,
      bitrateMbps: 16,
      tier: QualityPresetTier.highDetail,
    ),
  ];

  int _recordingResolution = 1080;
  int _recordingFps = 30;
  int _videoBitrateMbps = 8;
  String _qualityProfileId = '1080p_30_8';
  bool _audioEnabled = true;
  int _speedRefreshMs = 100;
  int _segmentDurationSeconds = 300;
  int _loopSegmentCount = 24;
  IncidentSensitivity _incidentSensitivity = IncidentSensitivity.medium;
  String _selectedCameraName = '';
  bool _isLoaded = false;

  int get recordingResolution => _recordingResolution;
  int get recordingFps => _recordingFps;
  int get videoBitrateMbps => _videoBitrateMbps;
  String get qualityProfileId => _qualityProfileId;
  RecordingQualityProfile? get activeQualityProfile =>
      profileById(_qualityProfileId);
  bool get audioEnabled => _audioEnabled;
  int get speedRefreshMs => _speedRefreshMs;
  int get segmentDurationSeconds => _segmentDurationSeconds;
  int get loopSegmentCount => _loopSegmentCount;
  IncidentSensitivity get incidentSensitivity => _incidentSensitivity;
  String get selectedCameraName => _selectedCameraName;
  double get incidentTriggerGForce {
    switch (_incidentSensitivity) {
      case IncidentSensitivity.low:
        return 4.5;
      case IncidentSensitivity.medium:
        return 3.5;
      case IncidentSensitivity.high:
        return 2.8;
    }
  }

  Duration get incidentDebounce {
    switch (_incidentSensitivity) {
      case IncidentSensitivity.low:
        return const Duration(seconds: 10);
      case IncidentSensitivity.medium:
        return const Duration(seconds: 6);
      case IncidentSensitivity.high:
        return const Duration(seconds: 3);
    }
  }
  bool get isLoaded => _isLoaded;

  static String resolutionLabel(int resolution) {
    if (resolution >= 2160) {
      return '4K (2160p)';
    }
    return '${resolution}p';
  }

  static ResolutionPreset toResolutionPreset(int resolution) {
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

  static int fromResolutionPreset(ResolutionPreset preset) {
    switch (preset) {
      case ResolutionPreset.low:
        return 480;
      case ResolutionPreset.medium:
        return 480;
      case ResolutionPreset.high:
        return 720;
      case ResolutionPreset.veryHigh:
        return 1080;
      case ResolutionPreset.ultraHigh:
        return 2160;
      case ResolutionPreset.max:
        return 2160;
    }
  }

  static RecordingQualityProfile? profileById(String id) {
    for (final profile in qualityProfiles) {
      if (profile.id == id) {
        return profile;
      }
    }
    return null;
  }

  static List<RecordingQualityProfile> qualityProfilesForTier(
      QualityPresetTier tier) {
    return qualityProfiles.where((profile) => profile.tier == tier).toList();
  }

  static String qualityTierLabel(QualityPresetTier tier) {
    switch (tier) {
      case QualityPresetTier.balanced:
        return 'Balanced';
      case QualityPresetTier.highDetail:
        return 'High Detail';
    }
  }

  static String segmentDurationLabel(int seconds) {
    if (seconds < 60) {
      return '$seconds sec per segment';
    }
    if (seconds % 60 == 0) {
      final minutes = seconds ~/ 60;
      return '$minutes min per segment';
    }
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return '$minutes min $remainder sec per segment';
  }

  static String incidentSensitivityLabel(IncidentSensitivity sensitivity) {
    switch (sensitivity) {
      case IncidentSensitivity.low:
        return 'Low (fewer auto-locks)';
      case IncidentSensitivity.medium:
        return 'Medium';
      case IncidentSensitivity.high:
        return 'High (more auto-locks)';
    }
  }

  static RecordingQualityProfile? findMatchingQualityProfile({
    required int resolution,
    required int fps,
    required int bitrateMbps,
  }) {
    for (final profile in qualityProfiles) {
      if (profile.resolution == resolution &&
          profile.fps == fps &&
          profile.bitrateMbps == bitrateMbps) {
        return profile;
      }
    }
    return null;
  }

  Future<void> load() async {
    if (_isLoaded) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final legacyQuality = prefs.getString(_qualityKey);
    _recordingResolution = _clampResolution(
      prefs.getInt(_resolutionKey) ?? _legacyResolutionFromQuality(legacyQuality),
    );
    _recordingFps = _clampFps(prefs.getInt(_fpsKey) ?? 30);
    _videoBitrateMbps =
        _clampVideoBitrateMbps(prefs.getInt(_videoBitrateMbpsKey) ?? 8);
    _audioEnabled = prefs.getBool(_audioEnabledKey) ?? true;
    _speedRefreshMs =
        _clampSpeedRefreshMs(prefs.getInt(_speedRefreshMsKey) ?? 100);
    _qualityProfileId =
        prefs.getString(_qualityProfileIdKey) ?? customQualityProfileId;
    final persistedSeconds = prefs.getInt(_segmentDurationSecondsKey);
    if (persistedSeconds != null) {
      _segmentDurationSeconds =
          _clampSegmentDurationSeconds(persistedSeconds);
    } else {
      final legacyMinutes = prefs.getInt(_segmentMinutesKey) ?? 5;
      _segmentDurationSeconds =
          _clampSegmentDurationSeconds(legacyMinutes * 60);
    }
    _loopSegmentCount =
        _clampLoopSegmentCount(prefs.getInt(_loopSegmentsKey) ?? 24);
    _incidentSensitivity = _incidentSensitivityFromName(
      prefs.getString(_incidentSensitivityKey),
    );
    _selectedCameraName = prefs.getString(_cameraNameKey) ?? '';
    _syncQualityProfileIdFromValues();
    _isLoaded = true;
    notifyListeners();
  }

  Future<void> updateSelectedCameraName(String cameraName) async {
    final trimmed = cameraName.trim();
    if (_selectedCameraName == trimmed) {
      return;
    }
    _selectedCameraName = trimmed;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cameraNameKey, _selectedCameraName);
  }

  Future<void> updateIncidentSensitivity(IncidentSensitivity sensitivity) async {
    if (_incidentSensitivity == sensitivity) {
      return;
    }
    _incidentSensitivity = sensitivity;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_incidentSensitivityKey, sensitivity.name);
  }

  Future<void> updateRecordingQualityProfile(String profileId) async {
    final profile = profileById(profileId);
    if (profile == null) {
      return;
    }

    _recordingResolution = _clampResolution(profile.resolution);
    _recordingFps = _clampFps(profile.fps);
    _videoBitrateMbps = _clampVideoBitrateMbps(profile.bitrateMbps);
    _qualityProfileId = profile.id;
    notifyListeners();
    await _persistVideoSettings();
  }

  Future<void> updateRecordingResolution(int resolution) async {
    final clamped = _clampResolution(resolution);
    if (_recordingResolution == clamped) {
      return;
    }
    _recordingResolution = clamped;
    _syncQualityProfileIdFromValues();
    notifyListeners();
    await _persistVideoSettings();
  }

  Future<void> updateRecordingFps(int fps) async {
    final clampedFps = _clampFps(fps);
    if (_recordingFps == clampedFps) {
      return;
    }
    _recordingFps = clampedFps;
    _syncQualityProfileIdFromValues();
    notifyListeners();
    await _persistVideoSettings();
  }

  Future<void> updateVideoBitrateMbps(int value) async {
    final clamped = _clampVideoBitrateMbps(value);
    if (_videoBitrateMbps == clamped) {
      return;
    }
    _videoBitrateMbps = clamped;
    _syncQualityProfileIdFromValues();
    notifyListeners();
    await _persistVideoSettings();
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

  Future<void> updateSegmentDurationSeconds(int seconds) async {
    final clamped = _clampSegmentDurationSeconds(seconds);
    if (_segmentDurationSeconds == clamped) {
      return;
    }
    _segmentDurationSeconds = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_segmentDurationSecondsKey, _segmentDurationSeconds);
    // Keep legacy key in sync for older builds reading minute-based values.
    await prefs.setInt(
      _segmentMinutesKey,
      (_segmentDurationSeconds / 60).ceil(),
    );
  }

  Future<void> updateLoopSegmentCount(int value) async {
    final clamped = _clampLoopSegmentCount(value);
    if (_loopSegmentCount == clamped) {
      return;
    }
    _loopSegmentCount = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_loopSegmentsKey, _loopSegmentCount);
  }

  int _legacyResolutionFromQuality(String? quality) {
    switch (quality) {
      case 'low':
        return 480;
      case 'medium':
        return 720;
      case 'high':
        return 1080;
      case 'veryHigh':
        return 1080;
      case 'ultraHigh':
        return 2160;
      default:
        return 1080;
    }
  }

  int _clampResolution(int value) {
    if (resolutionOptions.contains(value)) {
      return value;
    }
    return 1080;
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

  int _clampSegmentDurationSeconds(int value) {
    if (segmentDurationOptionsSeconds.contains(value)) {
      return value;
    }
    return 300;
  }

  int _clampLoopSegmentCount(int value) {
    if (loopSegmentCountOptions.contains(value)) {
      return value;
    }
    return 24;
  }

  IncidentSensitivity _incidentSensitivityFromName(String? value) {
    for (final sensitivity in IncidentSensitivity.values) {
      if (sensitivity.name == value) {
        return sensitivity;
      }
    }
    return IncidentSensitivity.medium;
  }

  Future<void> _persistVideoSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_resolutionKey, _recordingResolution);
    await prefs.setInt(_fpsKey, _recordingFps);
    await prefs.setInt(_videoBitrateMbpsKey, _videoBitrateMbps);
    await prefs.setString(_qualityProfileIdKey, _qualityProfileId);
  }

  void _syncQualityProfileIdFromValues() {
    final matching = findMatchingQualityProfile(
      resolution: _recordingResolution,
      fps: _recordingFps,
      bitrateMbps: _videoBitrateMbps,
    );
    _qualityProfileId = matching?.id ?? customQualityProfileId;
  }
}
