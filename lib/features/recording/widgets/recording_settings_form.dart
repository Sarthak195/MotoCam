// lib/features/recording/widgets/recording_settings_form.dart
//
// The editable state of the Settings page, shared by the main page and its
// sub-pages (Advanced, Storage, Safety, Privacy and data). It holds the
// rider's choices until SAVE and carries the rules the old settings sheet
// applied while editing: preset and profile choices, the custom profile,
// the frame-rate refresh after a resolution change and the start-up
// fallbacks. It persists nothing.

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import '../../../core/providers/app_settings_provider.dart';
import '../../camera/providers/camera_provider.dart';
import 'recording_settings_sheet.dart';

/// Looks up the frame rates a resolution preset supports.
typedef FpsOptionsLookup = Future<List<int>> Function(ResolutionPreset preset);

/// The Settings page's form state.
class RecordingSettingsForm extends ChangeNotifier {
  /// Creates the form from the saved [settings], applying the same start-up
  /// rules as the old sheet: an fps the camera no longer offers falls back
  /// ([resolveInitialFps]), a resolution known to fail falls back to the
  /// highest supported one, and both switch the profile to custom.
  RecordingSettingsForm({
    required AppSettingsProvider settings,
    required String activeCameraName,
    required List<int> initialFpsOptions,
    required List<CameraDescription> initialCameraOptions,
    required Set<ResolutionPreset> initialUnsupportedPresets,
    required this.lookupFpsOptions,
  }) : savedResolution = settings.recordingResolution,
       savedFps = settings.recordingFps,
       savedBitrateMbps = settings.videoBitrateMbps,
       savedSegmentDurationSeconds = settings.segmentDurationSeconds,
       savedAudioEnabled = settings.audioEnabled {
    resolution = settings.recordingResolution;
    fps = settings.recordingFps;
    bitrateMbps = settings.videoBitrateMbps;
    qualityProfileId = settings.qualityProfileId;
    presetTier =
        AppSettingsProvider.profileById(settings.qualityProfileId)?.tier ??
        QualityPresetTier.balanced;
    audioEnabled = settings.audioEnabled;
    exportLockedClipsToGallery = settings.exportLockedClipsToGallery;
    keepScreenOnWhileRecording = settings.keepScreenOnWhileRecording;
    speedRefreshMs = settings.speedRefreshMs;
    segmentDurationSeconds = settings.segmentDurationSeconds;
    loopSegmentCount = settings.loopSegmentCount;
    recordingsStorageBudgetGb = settings.recordingsStorageBudgetGb;
    incidentSensitivity = settings.incidentSensitivity;
    availableFps = List<int>.from(initialFpsOptions);
    final initialFps = resolveInitialFps(fps, availableFps);
    if (initialFps != fps) {
      fps = initialFps;
      qualityProfileId = AppSettingsProvider.customQualityProfileId;
    }
    unsupportedResolutionPresets = Set<ResolutionPreset>.from(
      initialUnsupportedPresets,
    );
    cameraOptions = List<CameraDescription>.from(initialCameraOptions);

    cameraName = settings.selectedCameraName;
    if (cameraName.isEmpty) {
      cameraName = activeCameraName;
    }
    if (cameraName.isEmpty && cameraOptions.isNotEmpty) {
      cameraName = cameraOptions.first.name;
    }

    if (isResolutionUnsupported(resolution)) {
      final fallbackResolutions = AppSettingsProvider.resolutionOptions
          .where((option) => !isResolutionUnsupported(option))
          .toList();
      if (fallbackResolutions.isNotEmpty) {
        resolution = fallbackResolutions.last;
        qualityProfileId = AppSettingsProvider.customQualityProfileId;
      }
    }
  }

  /// Looks up the frame rates of a preset (the camera provider's
  /// `getSupportedFpsOptionsForPreset`).
  final FpsOptionsLookup lookupFpsOptions;

  /// The saved resolution when the page opened.
  final int savedResolution;

  /// The saved frame rate when the page opened.
  final int savedFps;

  /// The saved bitrate when the page opened.
  final int savedBitrateMbps;

  /// The saved clip length when the page opened.
  final int savedSegmentDurationSeconds;

  /// The saved audio choice when the page opened.
  final bool savedAudioEnabled;

  /// Requested vertical resolution.
  late int resolution;

  /// Requested frame rate.
  late int fps;

  /// Requested bitrate in Mbps.
  late int bitrateMbps;

  /// Selected quality preset id, or the custom id.
  late String qualityProfileId;

  /// Selected quality group.
  late QualityPresetTier presetTier;

  /// Whether audio is recorded.
  late bool audioEnabled;

  /// Whether locked clips are copied to the gallery when a ride stops.
  late bool exportLockedClipsToGallery;

  /// Whether the screen stays on while recording.
  late bool keepScreenOnWhileRecording;

  /// Speed UI refresh interval in milliseconds.
  late int speedRefreshMs;

  /// Clip (segment) length in seconds.
  late int segmentDurationSeconds;

  /// Loop buffer size in segments.
  late int loopSegmentCount;

  /// Storage budget in GB; 0 is off.
  late int recordingsStorageBudgetGb;

  /// Crash detection sensitivity.
  late IncidentSensitivity incidentSensitivity;

  /// Frame rates offered for [resolution].
  late List<int> availableFps;

  /// Presets known to fail on this phone.
  late Set<ResolutionPreset> unsupportedResolutionPresets;

  /// Cameras to choose from.
  late List<CameraDescription> cameraOptions;

  /// Selected camera name.
  late String cameraName;

  bool _disposed = false;

  /// Whether [option] is a resolution known to fail on this phone.
  bool isResolutionUnsupported(int option) => unsupportedResolutionPresets
      .contains(CameraProvider.presetForResolution(option));

  /// Resolutions known to fail on this phone, in option order.
  List<int> get unsupportedResolutions => AppSettingsProvider.resolutionOptions
      .where(isResolutionUnsupported)
      .toList();

  void _changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Chooses a quality group and its first preset, then loads the preset's
  /// values once its frame rates are known.
  Future<void> selectTier(QualityPresetTier tier) async {
    final tierProfiles = AppSettingsProvider.qualityProfilesForTier(tier);
    if (tierProfiles.isEmpty) {
      return;
    }
    final profile = tierProfiles.first;
    presetTier = tier;
    qualityProfileId = profile.id;
    _changed();
    await _applyProfile(profile);
  }

  /// Chooses a preset by id (or custom).
  Future<void> selectProfile(String id) async {
    qualityProfileId = id;
    _changed();
    if (id == AppSettingsProvider.customQualityProfileId) {
      return;
    }
    final profile = AppSettingsProvider.profileById(id);
    if (profile == null) {
      return;
    }
    presetTier = profile.tier;
    _changed();
    await _applyProfile(profile);
  }

  Future<void> _applyProfile(RecordingQualityProfile profile) async {
    final fpsOptions = await lookupFpsOptions(
      CameraProvider.presetForResolution(profile.resolution),
    );
    if (_disposed) {
      return;
    }
    resolution = profile.resolution;
    bitrateMbps = profile.bitrateMbps;
    availableFps = List<int>.from(fpsOptions);
    if (availableFps.contains(profile.fps)) {
      fps = profile.fps;
    } else if (availableFps.isNotEmpty) {
      fps = availableFps.last;
      qualityProfileId = AppSettingsProvider.customQualityProfileId;
    }
    _changed();
  }

  /// Chooses a resolution (custom profile) and refreshes the frame rates.
  Future<void> selectResolution(int value) async {
    resolution = value;
    qualityProfileId = AppSettingsProvider.customQualityProfileId;
    _changed();
    final fpsOptions = await lookupFpsOptions(
      CameraProvider.presetForResolution(value),
    );
    if (_disposed) {
      return;
    }
    availableFps = List<int>.from(fpsOptions);
    if (!availableFps.contains(fps) && availableFps.isNotEmpty) {
      fps = availableFps.last;
    }
    _changed();
  }

  /// Chooses a frame rate (custom profile).
  void selectFps(int value) {
    fps = value;
    qualityProfileId = AppSettingsProvider.customQualityProfileId;
    _changed();
  }

  /// Chooses a bitrate (custom profile).
  void selectBitrate(int value) {
    bitrateMbps = value;
    qualityProfileId = AppSettingsProvider.customQualityProfileId;
    _changed();
  }

  /// Chooses a camera.
  void selectCamera(String value) {
    cameraName = value;
    _changed();
  }

  /// Chooses a clip length.
  void selectSegmentDuration(int seconds) {
    segmentDurationSeconds = seconds;
    _changed();
  }

  /// Chooses a loop buffer size.
  void selectLoopSegmentCount(int count) {
    loopSegmentCount = count;
    _changed();
  }

  /// Chooses a storage budget.
  void selectStorageBudget(int gigabytes) {
    recordingsStorageBudgetGb = gigabytes;
    _changed();
  }

  /// Chooses a speed refresh interval.
  void selectSpeedRefresh(int ms) {
    speedRefreshMs = ms;
    _changed();
  }

  /// Chooses a crash detection sensitivity.
  void selectIncidentSensitivity(IncidentSensitivity value) {
    incidentSensitivity = value;
    _changed();
  }

  /// Turns audio on or off.
  void setAudioEnabled(bool value) {
    audioEnabled = value;
    _changed();
  }

  /// Turns gallery copies of locked clips on or off.
  void setExportLockedClipsToGallery(bool value) {
    exportLockedClipsToGallery = value;
    _changed();
  }

  /// Turns keep-screen-on while recording on or off.
  void setKeepScreenOnWhileRecording(bool value) {
    keepScreenOnWhileRecording = value;
    _changed();
  }

  /// The camera the lens picker shows: the selected one when it is still
  /// offered, otherwise the first option (as the old sheet did). SAVE
  /// returns [cameraName] itself, unchanged.
  String get displayedCameraName {
    if (cameraOptions.isEmpty ||
        cameraOptions.any((camera) => camera.name == cameraName)) {
      return cameraName;
    }
    return cameraOptions.first.name;
  }

  /// The values SAVE pops.
  RecordingSettingsFormResult toResult() {
    return RecordingSettingsFormResult(
      resolution: resolution,
      fps: fps,
      bitrateMbps: bitrateMbps,
      audioEnabled: audioEnabled,
      speedRefreshMs: speedRefreshMs,
      cameraName: cameraName,
      segmentDurationSeconds: segmentDurationSeconds,
      loopSegmentCount: loopSegmentCount,
      incidentSensitivity: incidentSensitivity,
      exportLockedClipsToGallery: exportLockedClipsToGallery,
      keepScreenOnWhileRecording: keepScreenOnWhileRecording,
      recordingsStorageBudgetGb: recordingsStorageBudgetGb,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Short label of a resolution for a segmented tray: "720p", "4K".
String shortResolutionLabel(int resolution) =>
    resolution >= 2160 ? '4K' : '${resolution}p';

/// Short label of a clip length: "30 s", "2 min", "1 min 30 s".
String shortClipLengthLabel(int seconds) {
  if (seconds < 60) {
    return '$seconds s';
  }
  final minutes = seconds ~/ 60;
  final remainder = seconds % 60;
  return remainder == 0 ? '$minutes min' : '$minutes min $remainder s';
}

/// The main page's choices: the board's [common] values plus [selected]
/// when it is one of the less common ones, so the saved value always shows.
List<int> mainPageOptions(List<int> common, int selected) {
  if (common.contains(selected)) {
    return common;
  }
  return [...common, selected]..sort();
}

/// The "requested and applied" status of one recording setting.
///
/// [applied] is what the camera runs now, [requested] the form value and
/// [saved] the saved value when the page opened. Equal values read
/// "Applied X". Otherwise the text says when the request takes effect: from
/// the next recording while [recording], when saved for an unsaved change,
/// and "could not apply" for a saved value the camera did not take.
String appliedStatusText({
  required String applied,
  required String requested,
  required String saved,
  required bool recording,
}) {
  if (applied == requested) {
    return 'Applied $applied';
  }
  if (recording) {
    return 'Applied $applied, $requested from next recording';
  }
  if (requested != saved) {
    return 'Applied $applied, $requested when you save';
  }
  return 'Applied $applied. $requested could not apply';
}

/// About how many hours of video fit in a storage budget of [gigabytes]
/// (GiB, as the budget is enforced) at [bitrateMbps]; audio and file
/// overhead are not counted.
double storageBudgetHours(int gigabytes, int bitrateMbps) {
  if (gigabytes <= 0 || bitrateMbps <= 0) {
    return 0;
  }
  final bits = gigabytes * 1024 * 1024 * 1024 * 8;
  return bits / (bitrateMbps * 1000 * 1000) / 3600;
}
