import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Groups the quality presets shown in the settings sheet.
enum QualityPresetTier {
  /// Everyday presets up to 1080p.
  balanced,

  /// The 4K preset.
  highDetail,
}

/// How easily a g-force spike auto-locks the current segment.
enum IncidentSensitivity {
  /// Highest threshold, fewest auto-locks.
  low,

  /// The default threshold.
  medium,

  /// Lowest threshold, most auto-locks.
  high,
}

/// An immutable resolution / FPS / bitrate preset.
class RecordingQualityProfile {
  /// Creates a preset.
  const RecordingQualityProfile({
    required this.id,
    required this.resolution,
    required this.fps,
    required this.bitrateMbps,
    required this.tier,
  });

  /// Stable preset id, for example `'1080p_30_8'`.
  final String id;

  /// Vertical resolution in lines (for example 1080).
  final int resolution;

  /// Frames per second.
  final int fps;

  /// Video bitrate in Mbps.
  final int bitrateMbps;

  /// The group the preset is listed under.
  final QualityPresetTier tier;

  /// Display label such as `1080p / 30 FPS / 8 Mbps`.
  String get label =>
      '$resolution'
      'p / $fps FPS / $bitrateMbps Mbps';
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
  static const _exportLockedClipsKey = 'export_locked_clips_to_gallery';
  static const _keepScreenOnKey = 'keep_screen_on_while_recording';
  static const _speedRefreshMsKey = 'speed_refresh_ms';
  static const _segmentDurationSecondsKey = 'dashcam_segment_duration_seconds';
  static const _segmentMinutesKey = 'dashcam_segment_minutes';
  static const _loopSegmentsKey = 'dashcam_loop_segment_count';
  static const _incidentSensitivityKey = 'incident_sensitivity';
  static const _cameraNameKey = 'camera_name';
  static const _storageBudgetGbKey = 'recordings_storage_budget_gb';

  /// Selectable video bitrates in Mbps.
  static const List<int> bitrateOptionsMbps = [4, 8, 12, 16];

  /// Selectable resolutions in vertical lines.
  static const List<int> resolutionOptions = [480, 720, 1080, 2160];

  /// Selectable segment lengths in seconds.
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

  /// Selectable loop-buffer sizes (number of segments kept).
  static const List<int> loopSegmentCountOptions = [6, 12, 18, 24, 36, 48];

  /// Storage budget choices for all recordings, in GB (0 = off).
  static const List<int> storageBudgetOptionsGb = [0, 4, 8, 16, 32, 64];

  /// Pseudo profile id used when no preset matches the current values.
  static const String customQualityProfileId = 'custom';

  /// The shipped quality presets.
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
  bool _exportLockedClipsToGallery = false;
  bool _keepScreenOnWhileRecording = true;
  int _speedRefreshMs = 100;
  int _segmentDurationSeconds = 300;
  int _loopSegmentCount = 24;
  int _recordingsStorageBudgetGb = 0;
  IncidentSensitivity _incidentSensitivity = IncidentSensitivity.medium;
  String _selectedCameraName = '';
  bool _isLoaded = false;

  /// Selected resolution in vertical lines (one of [resolutionOptions]).
  int get recordingResolution => _recordingResolution;

  /// Selected frame rate, clamped to 24-60.
  int get recordingFps => _recordingFps;

  /// Selected video bitrate in Mbps (one of [bitrateOptionsMbps]).
  int get videoBitrateMbps => _videoBitrateMbps;

  /// Id of the preset matching the current values, or
  /// [customQualityProfileId].
  String get qualityProfileId => _qualityProfileId;

  /// Whether audio is recorded.
  bool get audioEnabled => _audioEnabled;

  /// Whether locked clips are copied to the shared gallery
  /// (`Movies/MotoCam/Recordings`, Android) when a ride stops. Off by
  /// default: gallery copies are visible to every gallery app and MotoCam
  /// never removes them.
  bool get exportLockedClipsToGallery => _exportLockedClipsToGallery;

  /// Whether the screen is kept on while a recording is active (Android).
  /// On by default: it is the fallback in case capture does not continue
  /// with the screen off on a given phone.
  bool get keepScreenOnWhileRecording => _keepScreenOnWhileRecording;

  /// Telemetry UI refresh interval in milliseconds, clamped to 100-1000.
  int get speedRefreshMs => _speedRefreshMs;

  /// Segment length in seconds (one of [segmentDurationOptionsSeconds]).
  int get segmentDurationSeconds => _segmentDurationSeconds;

  /// Loop-buffer size (one of [loopSegmentCountOptions]).
  int get loopSegmentCount => _loopSegmentCount;

  /// Storage budget for all recordings in GB (one of
  /// [storageBudgetOptionsGb]); 0 (the default) turns it off. While a ride
  /// records, the oldest unlocked rides are deleted when the recordings
  /// exceed it; locked rides are never deleted.
  int get recordingsStorageBudgetGb => _recordingsStorageBudgetGb;

  /// [recordingsStorageBudgetGb] in bytes (GB as 1024^3 bytes); 0 when off.
  int get recordingsStorageBudgetBytes =>
      _recordingsStorageBudgetGb * 1024 * 1024 * 1024;

  /// Selected incident sensitivity.
  IncidentSensitivity get incidentSensitivity => _incidentSensitivity;

  /// Preferred camera name; empty means automatic selection.
  String get selectedCameraName => _selectedCameraName;

  /// Jolt trigger (g) at the current sensitivity: the 100 ms average of the
  /// linear acceleration must reach it for at least 60 ms (see
  /// `CrashDetector`), roughly a 3.5 to 5 m/s change of velocity at medium.
  /// A jolt only auto-locks once it is confirmed by an abrupt stop or a
  /// tip-over, so the sensitivity mostly decides which knocks are checked.
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

  /// Minimum time from an automatic incident lock's confirmation to the next
  /// jolt that can start another one.
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

  /// Whether [load] has completed.
  bool get isLoaded => _isLoaded;

  /// Display label for [resolution], for example `720p` or `4K (2160p)`.
  static String resolutionLabel(int resolution) {
    if (resolution >= 2160) {
      return '4K (2160p)';
    }
    return '${resolution}p';
  }

  /// The shipped preset with [id], or null if there is none.
  static RecordingQualityProfile? profileById(String id) {
    for (final profile in qualityProfiles) {
      if (profile.id == id) {
        return profile;
      }
    }
    return null;
  }

  /// The shipped presets in [tier].
  static List<RecordingQualityProfile> qualityProfilesForTier(
    QualityPresetTier tier,
  ) {
    return qualityProfiles.where((profile) => profile.tier == tier).toList();
  }

  /// Display label for [tier].
  static String qualityTierLabel(QualityPresetTier tier) {
    switch (tier) {
      case QualityPresetTier.balanced:
        return 'Balanced';
      case QualityPresetTier.highDetail:
        return 'High Detail';
    }
  }

  /// Display label for a segment length of [seconds].
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

  /// Display label for a storage budget of [gigabytes] (0 is off).
  static String storageBudgetLabel(int gigabytes) =>
      gigabytes <= 0 ? 'Off' : '$gigabytes GB';

  /// Display label for [sensitivity].
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

  /// The shipped preset with exactly these values, or null.
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

  /// Reads every setting from [SharedPreferences] once, clamps it to the
  /// allowed options and migrates the legacy `recording_quality` and
  /// `dashcam_segment_minutes` keys. The preset id is always derived from
  /// the loaded values. Later calls do nothing.
  Future<void> load() async {
    if (_isLoaded) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final legacyQuality = prefs.getString(_qualityKey);
    _recordingResolution = _clampResolution(
      prefs.getInt(_resolutionKey) ??
          _legacyResolutionFromQuality(legacyQuality),
    );
    _recordingFps = _clampFps(prefs.getInt(_fpsKey) ?? 30);
    _videoBitrateMbps = _clampVideoBitrateMbps(
      prefs.getInt(_videoBitrateMbpsKey) ?? 8,
    );
    _audioEnabled = prefs.getBool(_audioEnabledKey) ?? true;
    _exportLockedClipsToGallery = prefs.getBool(_exportLockedClipsKey) ?? false;
    _keepScreenOnWhileRecording = prefs.getBool(_keepScreenOnKey) ?? true;
    _speedRefreshMs = _clampSpeedRefreshMs(
      prefs.getInt(_speedRefreshMsKey) ?? 100,
    );
    final persistedSeconds = prefs.getInt(_segmentDurationSecondsKey);
    if (persistedSeconds != null) {
      _segmentDurationSeconds = _clampSegmentDurationSeconds(persistedSeconds);
    } else {
      final legacyMinutes = prefs.getInt(_segmentMinutesKey) ?? 5;
      _segmentDurationSeconds = _clampSegmentDurationSeconds(
        legacyMinutes * 60,
      );
    }
    _loopSegmentCount = _clampLoopSegmentCount(
      prefs.getInt(_loopSegmentsKey) ?? 24,
    );
    _incidentSensitivity = _incidentSensitivityFromName(
      prefs.getString(_incidentSensitivityKey),
    );
    _recordingsStorageBudgetGb = _clampStorageBudgetGb(
      prefs.getInt(_storageBudgetGbKey) ?? 0,
    );
    _selectedCameraName = prefs.getString(_cameraNameKey) ?? '';
    _syncQualityProfileIdFromValues();
    _isLoaded = true;
    notifyListeners();
  }

  /// Sets and persists the preferred camera name (trimmed).
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

  /// Sets and persists the incident sensitivity.
  Future<void> updateIncidentSensitivity(
    IncidentSensitivity sensitivity,
  ) async {
    if (_incidentSensitivity == sensitivity) {
      return;
    }
    _incidentSensitivity = sensitivity;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_incidentSensitivityKey, sensitivity.name);
  }

  /// Applies and persists the preset with [profileId]; unknown ids are
  /// ignored.
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

  /// Sets and persists the resolution; values outside [resolutionOptions]
  /// become 1080.
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

  /// Sets and persists the frame rate, clamped to 24-60.
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

  /// Sets and persists the bitrate; values outside [bitrateOptionsMbps]
  /// become 8.
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

  /// Sets and persists whether audio is recorded.
  Future<void> updateAudioEnabled(bool enabled) async {
    if (_audioEnabled == enabled) {
      return;
    }
    _audioEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_audioEnabledKey, enabled);
  }

  /// Sets and persists [exportLockedClipsToGallery].
  Future<void> updateExportLockedClipsToGallery(bool enabled) async {
    if (_exportLockedClipsToGallery == enabled) {
      return;
    }
    _exportLockedClipsToGallery = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_exportLockedClipsKey, enabled);
  }

  /// Sets and persists [keepScreenOnWhileRecording].
  Future<void> updateKeepScreenOnWhileRecording(bool enabled) async {
    if (_keepScreenOnWhileRecording == enabled) {
      return;
    }
    _keepScreenOnWhileRecording = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keepScreenOnKey, enabled);
  }

  /// Sets and persists the telemetry refresh interval, clamped to 100-1000 ms.
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

  /// Sets and persists the segment length; values outside
  /// [segmentDurationOptionsSeconds] become 300. Also writes the legacy
  /// minutes key.
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

  /// Sets and persists the loop-buffer size; values outside
  /// [loopSegmentCountOptions] become 24.
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

  /// Sets and persists [recordingsStorageBudgetGb]; values outside
  /// [storageBudgetOptionsGb] become 0 (off).
  Future<void> updateRecordingsStorageBudgetGb(int gigabytes) async {
    final clamped = _clampStorageBudgetGb(gigabytes);
    if (_recordingsStorageBudgetGb == clamped) {
      return;
    }
    _recordingsStorageBudgetGb = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_storageBudgetGbKey, _recordingsStorageBudgetGb);
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

  int _clampStorageBudgetGb(int value) {
    if (storageBudgetOptionsGb.contains(value)) {
      return value;
    }
    return 0;
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
