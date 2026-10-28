import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/providers/app_settings_provider.dart';
import '../../camera/providers/camera_provider.dart';
import '../recording_screen_logic.dart';

/// Frame rate the settings sheet starts with: [savedFps] when [availableFps]
/// contains it, otherwise 30 when available, otherwise the last option.
///
/// [availableFps] can shrink after camera-init failures, so the saved rate
/// may no longer be offered. An empty list returns [savedFps].
int resolveInitialFps(int savedFps, List<int> availableFps) {
  if (availableFps.isEmpty || availableFps.contains(savedFps)) {
    return savedFps;
  }
  return availableFps.contains(30) ? 30 : availableFps.last;
}

/// Values the rider saved in [RecordingSettingsSheet], returned when the
/// sheet is closed with SAVE SETTINGS.
class RecordingSettingsFormResult {
  /// Creates a result holding every field of the settings form.
  const RecordingSettingsFormResult({
    required this.resolution,
    required this.fps,
    required this.bitrateMbps,
    required this.audioEnabled,
    required this.speedRefreshMs,
    required this.cameraName,
    required this.segmentDurationSeconds,
    required this.loopSegmentCount,
    required this.incidentSensitivity,
    this.exportLockedClipsToGallery = false,
    this.keepScreenOnWhileRecording = true,
  });

  /// Requested vertical resolution in pixels (e.g. 1080).
  final int resolution;

  /// Requested frame rate.
  final int fps;

  /// Requested video bitrate in Mbps.
  final int bitrateMbps;

  /// Whether audio is recorded.
  final bool audioEnabled;

  /// Minimum interval between speed UI refreshes, in milliseconds.
  final int speedRefreshMs;

  /// Name of the selected camera (CameraDescription.name).
  final String cameraName;

  /// Length of one recording segment, in seconds.
  final int segmentDurationSeconds;

  /// Number of unlocked segments kept by the loop buffer.
  final int loopSegmentCount;

  /// Sensitivity of automatic incident detection.
  final IncidentSensitivity incidentSensitivity;

  /// Whether locked clips are copied to the shared gallery when a ride
  /// stops (Android).
  final bool exportLockedClipsToGallery;

  /// Whether the screen is kept on while a recording is active (Android).
  final bool keepScreenOnWhileRecording;
}

/// Modal form for the recording, camera and telemetry settings.
///
/// Reads the saved values from [AppSettingsProvider] and pops a
/// [RecordingSettingsFormResult] on SAVE SETTINGS; it does not persist or
/// apply anything itself.
class RecordingSettingsSheet extends StatefulWidget {
  /// Frame rates offered for the saved resolution.
  final List<int> initialFpsOptions;

  /// Cameras the rider can choose from.
  final List<CameraDescription> initialCameraOptions;

  /// Resolution presets known to fail on this device; shown as unsupported.
  final Set<ResolutionPreset> initialUnsupportedPresets;

  /// Creates the settings form with the given option lists.
  const RecordingSettingsSheet({
    super.key,
    required this.initialFpsOptions,
    required this.initialCameraOptions,
    required this.initialUnsupportedPresets,
  });

  @override
  State<RecordingSettingsSheet> createState() => _RecordingSettingsSheetState();
}

class _RecordingSettingsSheetState extends State<RecordingSettingsSheet> {
  late int selectedResolution;
  late int selectedFps;
  late int selectedBitrateMbps;
  late String selectedQualityProfileId;
  late QualityPresetTier selectedPresetTier;
  late bool audioEnabled;
  late bool exportLockedClipsToGallery;
  late bool keepScreenOnWhileRecording;
  late int speedRefreshMs;
  late int segmentDurationSeconds;
  late int loopSegmentCount;
  late IncidentSensitivity incidentSensitivity;
  late List<int> availableFps;
  late Set<ResolutionPreset> unsupportedResolutionPresets;
  late List<CameraDescription> cameraOptions;
  late String selectedCameraName;

  @override
  void initState() {
    super.initState();
    final settings = context.read<AppSettingsProvider>();
    final cameraProvider = context.read<CameraProvider>();

    selectedResolution = settings.recordingResolution;
    selectedFps = settings.recordingFps;
    selectedBitrateMbps = settings.videoBitrateMbps;
    selectedQualityProfileId = settings.qualityProfileId;
    selectedPresetTier =
        AppSettingsProvider.profileById(settings.qualityProfileId)?.tier ??
        QualityPresetTier.balanced;
    audioEnabled = settings.audioEnabled;
    exportLockedClipsToGallery = settings.exportLockedClipsToGallery;
    keepScreenOnWhileRecording = settings.keepScreenOnWhileRecording;
    speedRefreshMs = settings.speedRefreshMs;
    segmentDurationSeconds = settings.segmentDurationSeconds;
    loopSegmentCount = settings.loopSegmentCount;
    incidentSensitivity = settings.incidentSensitivity;
    availableFps = List<int>.from(widget.initialFpsOptions);
    final initialFps = resolveInitialFps(selectedFps, availableFps);
    if (initialFps != selectedFps) {
      selectedFps = initialFps;
      selectedQualityProfileId = AppSettingsProvider.customQualityProfileId;
    }
    unsupportedResolutionPresets = Set<ResolutionPreset>.from(
      widget.initialUnsupportedPresets,
    );
    cameraOptions = List<CameraDescription>.from(widget.initialCameraOptions);

    selectedCameraName = settings.selectedCameraName;
    if (selectedCameraName.isEmpty) {
      selectedCameraName = cameraProvider.activeCameraName;
    }
    if (selectedCameraName.isEmpty && cameraOptions.isNotEmpty) {
      selectedCameraName = cameraOptions.first.name;
    }

    final resolutionIsUnsupported = unsupportedResolutionPresets.contains(
      CameraProvider.presetForResolution(selectedResolution),
    );
    if (resolutionIsUnsupported) {
      final fallbackResolutions = AppSettingsProvider.resolutionOptions
          .where(
            (resolution) => !unsupportedResolutionPresets.contains(
              CameraProvider.presetForResolution(resolution),
            ),
          )
          .toList();
      if (fallbackResolutions.isNotEmpty) {
        selectedResolution = fallbackResolutions.last;
        selectedQualityProfileId = AppSettingsProvider.customQualityProfileId;
      }
    }
  }

  InputDecoration _settingsInputDecoration() {
    return InputDecoration(
      filled: true,
      fillColor: const Color(0xFF1B1B1B),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _buildSettingsLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cameraProvider = context.read<CameraProvider>();
    final maxSheetHeight = MediaQuery.of(context).size.height * 0.88;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxSheetHeight),
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 12,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Recording Settings',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                _buildSettingsLabel('Quality group'),
                DropdownButtonFormField<QualityPresetTier>(
                  key: ValueKey(selectedPresetTier),
                  initialValue: selectedPresetTier,
                  dropdownColor: const Color(0xFF1B1B1B),
                  decoration: _settingsInputDecoration(),
                  items: QualityPresetTier.values
                      .map(
                        (tier) => DropdownMenuItem<QualityPresetTier>(
                          value: tier,
                          child: Text(
                            AppSettingsProvider.qualityTierLabel(tier),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;

                    final tierProfiles =
                        AppSettingsProvider.qualityProfilesForTier(value);
                    if (tierProfiles.isEmpty) {
                      return;
                    }

                    final selectedProfile = tierProfiles.first;
                    setState(() {
                      selectedPresetTier = value;
                      selectedQualityProfileId = selectedProfile.id;
                    });

                    unawaited(() async {
                      final fpsOptions = await cameraProvider
                          .getSupportedFpsOptionsForPreset(
                            preset: CameraProvider.presetForResolution(
                              selectedProfile.resolution,
                            ),
                          );
                      if (!mounted) {
                        return;
                      }
                      setState(() {
                        selectedResolution = selectedProfile.resolution;
                        selectedBitrateMbps = selectedProfile.bitrateMbps;
                        availableFps = List<int>.from(fpsOptions);
                        if (availableFps.contains(selectedProfile.fps)) {
                          selectedFps = selectedProfile.fps;
                        } else {
                          selectedFps = availableFps.last;
                          selectedQualityProfileId =
                              AppSettingsProvider.customQualityProfileId;
                        }
                      });
                    }());
                  },
                ),
                const SizedBox(height: 12),
                _buildSettingsLabel('Recording quality preset'),
                DropdownButtonFormField<String>(
                  key: ValueKey(selectedQualityProfileId),
                  initialValue: selectedQualityProfileId,
                  dropdownColor: const Color(0xFF1B1B1B),
                  decoration: _settingsInputDecoration(),
                  items: [
                    const DropdownMenuItem<String>(
                      value: AppSettingsProvider.customQualityProfileId,
                      child: Text('Custom'),
                    ),
                    ...AppSettingsProvider.qualityProfilesForTier(
                      selectedPresetTier,
                    ).map(
                      (profile) => DropdownMenuItem<String>(
                        value: profile.id,
                        child: Text(profile.label),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => selectedQualityProfileId = value);

                    if (value == AppSettingsProvider.customQualityProfileId) {
                      return;
                    }

                    final profile = AppSettingsProvider.profileById(value);
                    if (profile == null) {
                      return;
                    }

                    setState(() => selectedPresetTier = profile.tier);

                    unawaited(() async {
                      final fpsOptions = await cameraProvider
                          .getSupportedFpsOptionsForPreset(
                            preset: CameraProvider.presetForResolution(
                              profile.resolution,
                            ),
                          );
                      if (!mounted) {
                        return;
                      }
                      setState(() {
                        selectedResolution = profile.resolution;
                        selectedBitrateMbps = profile.bitrateMbps;
                        availableFps = List<int>.from(fpsOptions);
                        if (availableFps.contains(profile.fps)) {
                          selectedFps = profile.fps;
                        } else {
                          selectedFps = availableFps.last;
                          selectedQualityProfileId =
                              AppSettingsProvider.customQualityProfileId;
                        }
                      });
                    }());
                  },
                ),
                const SizedBox(height: 12),
                if (cameraOptions.isNotEmpty) ...[
                  _buildSettingsLabel('Camera lens'),
                  DropdownButtonFormField<String>(
                    key: ValueKey(selectedCameraName),
                    initialValue:
                        cameraOptions.any(
                          (camera) => camera.name == selectedCameraName,
                        )
                        ? selectedCameraName
                        : cameraOptions.first.name,
                    dropdownColor: const Color(0xFF1B1B1B),
                    decoration: _settingsInputDecoration(),
                    items: cameraOptions
                        .map(
                          (camera) => DropdownMenuItem<String>(
                            value: camera.name,
                            child: Text(cameraProvider.cameraLabel(camera)),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => selectedCameraName = value);
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                _buildSettingsLabel('Recording resolution'),
                DropdownButtonFormField<int>(
                  key: ValueKey(selectedResolution),
                  initialValue: selectedResolution,
                  dropdownColor: const Color(0xFF1B1B1B),
                  decoration: _settingsInputDecoration(),
                  items: AppSettingsProvider.resolutionOptions.map((
                    resolution,
                  ) {
                    final isUnsupported = unsupportedResolutionPresets.contains(
                      CameraProvider.presetForResolution(resolution),
                    );
                    final label = AppSettingsProvider.resolutionLabel(
                      resolution,
                    );
                    return DropdownMenuItem<int>(
                      value: resolution,
                      enabled: !isUnsupported,
                      child: Text(
                        isUnsupported ? '$label (unsupported)' : label,
                        style: TextStyle(
                          color: isUnsupported ? Colors.white38 : Colors.white,
                        ),
                      ),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      selectedResolution = value;
                      selectedQualityProfileId =
                          AppSettingsProvider.customQualityProfileId;
                    });

                    unawaited(() async {
                      final fpsOptions = await cameraProvider
                          .getSupportedFpsOptionsForPreset(
                            preset: CameraProvider.presetForResolution(value),
                          );
                      if (!mounted) {
                        return;
                      }
                      setState(() {
                        availableFps = List<int>.from(fpsOptions);
                        if (!availableFps.contains(selectedFps)) {
                          selectedFps = availableFps.last;
                        }
                      });
                    }());
                  },
                ),
                if (unsupportedResolutionPresets.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Known unsupported on this device: ${AppSettingsProvider.resolutionOptions.where((resolution) => unsupportedResolutionPresets.contains(CameraProvider.presetForResolution(resolution))).map(AppSettingsProvider.resolutionLabel).join(', ')}',
                    style: const TextStyle(
                      color: Colors.orange,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                _buildSettingsLabel('Frame rate (FPS)'),
                DropdownButtonFormField<int>(
                  key: ValueKey(selectedFps),
                  initialValue: selectedFps,
                  dropdownColor: const Color(0xFF1B1B1B),
                  decoration: _settingsInputDecoration(),
                  items: availableFps
                      .map(
                        (fps) => DropdownMenuItem<int>(
                          value: fps,
                          child: Text('$fps FPS'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      selectedFps = value;
                      selectedQualityProfileId =
                          AppSettingsProvider.customQualityProfileId;
                    });
                  },
                ),
                const SizedBox(height: 12),
                _buildSettingsLabel('Video bitrate'),
                DropdownButtonFormField<int>(
                  key: ValueKey(selectedBitrateMbps),
                  initialValue: selectedBitrateMbps,
                  dropdownColor: const Color(0xFF1B1B1B),
                  decoration: _settingsInputDecoration(),
                  items: AppSettingsProvider.bitrateOptionsMbps
                      .map(
                        (mbps) => DropdownMenuItem<int>(
                          value: mbps,
                          child: Text('$mbps Mbps'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      selectedBitrateMbps = value;
                      selectedQualityProfileId =
                          AppSettingsProvider.customQualityProfileId;
                    });
                  },
                ),
                if (!cameraProvider.supportsVideoBitrateControl)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'No effect on this device: the Android camera plugin '
                      'records at its own bitrate for the chosen resolution.',
                      style: TextStyle(color: Colors.orange, fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 12),
                _buildSettingsLabel('Segment length'),
                DropdownButtonFormField<int>(
                  key: ValueKey(segmentDurationSeconds),
                  initialValue: segmentDurationSeconds,
                  dropdownColor: const Color(0xFF1B1B1B),
                  decoration: _settingsInputDecoration(),
                  items: AppSettingsProvider.segmentDurationOptionsSeconds
                      .map(
                        (seconds) => DropdownMenuItem<int>(
                          value: seconds,
                          child: Text(
                            AppSettingsProvider.segmentDurationLabel(seconds),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => segmentDurationSeconds = value);
                  },
                ),
                const SizedBox(height: 12),
                _buildSettingsLabel('Loop buffer size'),
                DropdownButtonFormField<int>(
                  key: ValueKey(loopSegmentCount),
                  initialValue: loopSegmentCount,
                  dropdownColor: const Color(0xFF1B1B1B),
                  decoration: _settingsInputDecoration(),
                  items: AppSettingsProvider.loopSegmentCountOptions
                      .map(
                        (segments) => DropdownMenuItem<int>(
                          value: segments,
                          child: Text('$segments segments'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => loopSegmentCount = value);
                  },
                ),
                const SizedBox(height: 12),
                _buildSettingsLabel('Speed UI refresh'),
                DropdownButtonFormField<int>(
                  key: ValueKey(speedRefreshMs),
                  initialValue: speedRefreshMs,
                  dropdownColor: const Color(0xFF1B1B1B),
                  decoration: _settingsInputDecoration(),
                  items: const [100, 200, 300, 500]
                      .map(
                        (ms) => DropdownMenuItem<int>(
                          value: ms,
                          child: Text('$ms ms'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => speedRefreshMs = value);
                  },
                ),
                const SizedBox(height: 12),
                _buildSettingsLabel('Incident sensitivity'),
                DropdownButtonFormField<IncidentSensitivity>(
                  key: ValueKey(incidentSensitivity),
                  initialValue: incidentSensitivity,
                  dropdownColor: const Color(0xFF1B1B1B),
                  decoration: _settingsInputDecoration(),
                  items: IncidentSensitivity.values
                      .map(
                        (sensitivity) => DropdownMenuItem<IncidentSensitivity>(
                          value: sensitivity,
                          child: Text(
                            AppSettingsProvider.incidentSensitivityLabel(
                              sensitivity,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => incidentSensitivity = value);
                  },
                ),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: Colors.blue,
                  activeTrackColor: Colors.blue.withValues(alpha: 0.35),
                  value: audioEnabled,
                  title: const Text(
                    'Record audio',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: const Text(
                    'Disable for lower CPU and storage usage',
                    style: TextStyle(color: Colors.white70),
                  ),
                  onChanged: (value) {
                    setState(() => audioEnabled = value);
                  },
                ),
                if (defaultTargetPlatform == TargetPlatform.android)
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: Colors.blue,
                    activeTrackColor: Colors.blue.withValues(alpha: 0.35),
                    value: exportLockedClipsToGallery,
                    title: const Text(
                      'Copy locked clips to gallery',
                      style: TextStyle(color: Colors.white),
                    ),
                    subtitle: const Text(
                      'When a ride stops, locked clips are copied to '
                      'Movies/MotoCam/Recordings. Gallery copies are visible '
                      'to other apps and are not deleted by MotoCam.',
                      style: TextStyle(color: Colors.white70),
                    ),
                    onChanged: (value) {
                      setState(() => exportLockedClipsToGallery = value);
                    },
                  ),
                if (defaultTargetPlatform == TargetPlatform.android)
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: Colors.blue,
                    activeTrackColor: Colors.blue.withValues(alpha: 0.35),
                    value: keepScreenOnWhileRecording,
                    title: const Text(
                      'Keep screen on while recording',
                      style: TextStyle(color: Colors.white),
                    ),
                    subtitle: const Text(
                      'Recording is designed to continue with the screen off, '
                      'but this is not yet confirmed on every phone. Keeping '
                      'the screen on is the safe fallback; it uses more '
                      'battery.',
                      style: TextStyle(color: Colors.white70),
                    ),
                    onChanged: (value) {
                      setState(() => keepScreenOnWhileRecording = value);
                    },
                  ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pop(
                        RecordingSettingsFormResult(
                          resolution: selectedResolution,
                          fps: selectedFps,
                          bitrateMbps: selectedBitrateMbps,
                          audioEnabled: audioEnabled,
                          speedRefreshMs: speedRefreshMs,
                          cameraName: selectedCameraName,
                          segmentDurationSeconds: segmentDurationSeconds,
                          loopSegmentCount: loopSegmentCount,
                          incidentSensitivity: incidentSensitivity,
                          exportLockedClipsToGallery:
                              exportLockedClipsToGallery,
                          keepScreenOnWhileRecording:
                              keepScreenOnWhileRecording,
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 52),
                      backgroundColor: recordingStartButtonColor,
                      foregroundColor: recordingButtonLabelColor,
                    ),
                    child: const Text(
                      'SAVE SETTINGS',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
