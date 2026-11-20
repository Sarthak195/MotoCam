// lib/features/recording/widgets/recording_settings_sheet.dart
//
// The settings result type and the start-up frame-rate rule. The Settings
// page itself (board A-Settings) is in recording_settings_page.dart, which
// this file exports so existing imports keep working.

import '../../../core/providers/app_settings_provider.dart';
import 'recording_settings_page.dart';

export 'recording_settings_page.dart';

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

/// Values the rider saved on the Settings page, returned when it is closed
/// with SAVE.
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
    this.recordingsStorageBudgetGb = 0,
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

  /// Storage budget for all recordings in GB; 0 is off.
  final int recordingsStorageBudgetGb;
}

/// The Settings page under its old name, for the call site that still
/// shows it in a scroll-controlled modal bottom sheet. New code pushes it
/// with [showRecordingSettingsPage].
class RecordingSettingsSheet extends RecordingSettingsPage {
  /// Creates the settings form with the given option lists.
  const RecordingSettingsSheet({
    super.key,
    required super.initialFpsOptions,
    required super.initialCameraOptions,
    required super.initialUnsupportedPresets,
    super.onShareDiagnosticLog,
    super.onClearDiagnosticLog,
  });
}
