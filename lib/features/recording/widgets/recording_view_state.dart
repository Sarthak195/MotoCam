// lib/features/recording/widgets/recording_view_state.dart
//
// One immutable snapshot of what the recording screen's widgets show. The
// screen's State keeps every flag and flow and builds this in build(); the
// widgets under this folder only read it.

import 'package:flutter/foundation.dart';

import '../../../core/ui/state_band.dart';

/// What the recording screen shows, taken once per build.
@immutable
class RecordingViewState {
  /// Creates a snapshot.
  const RecordingViewState({
    required this.isRecording,
    required this.isBlackoutMode,
    required this.isApplyingSettings,
    required this.isStarting,
    required this.isStopping,
    required this.isPersistingRide,
    required this.isPreparingCamera,
    required this.isSegmentLocked,
    required this.cameraName,
    required this.requestedResolution,
    required this.requestedFps,
    required this.appliedResolution,
    required this.appliedFps,
    required this.showApplied,
    required this.requestedBitrateMbps,
    required this.appliedBitrateMbps,
    required this.audioEnabled,
    required this.segmentLabel,
    required this.loopSegmentCount,
    required this.incidentSensitivityName,
    required this.speedRefreshMs,
    required this.incidentDetectionUnavailable,
    required this.locationOff,
    required this.highIncidentSensitivity,
    required this.presetWarning,
    this.settingsPending = false,
  });

  /// A recording is running.
  final bool isRecording;

  /// The Blackout overlay is up.
  final bool isBlackoutMode;

  /// Saved settings are being applied to the camera.
  final bool isApplyingSettings;

  /// START was pressed and the recording is not confirmed yet.
  final bool isStarting;

  /// STOP was pressed and the camera is stopping.
  final bool isStopping;

  /// The ride file is being written (also a Retry of a failed save).
  final bool isPersistingRide;

  /// The camera is initializing while idle.
  final bool isPreparingCamera;

  /// The segment being recorded is locked.
  final bool isSegmentLocked;

  /// Selected camera name; empty for the default camera.
  final String cameraName;

  /// Resolution the rider asked for, in lines.
  final int requestedResolution;

  /// Frame rate the rider asked for.
  final int requestedFps;

  /// Resolution the camera was configured with, in lines.
  final int appliedResolution;

  /// Frame rate the camera was configured with.
  final int appliedFps;

  /// Whether the applied values are known (the camera is initialized and no
  /// saved setting waits for the next START).
  final bool showApplied;

  /// Settings saved during a ride wait for the next START; the camera still
  /// runs the old ones.
  final bool settingsPending;

  /// Bitrate the rider asked for, in Mbps.
  final int requestedBitrateMbps;

  /// Bitrate the camera was configured with, in Mbps.
  final int appliedBitrateMbps;

  /// Audio is recorded.
  final bool audioEnabled;

  /// Clip length label, for example "3 min".
  final String segmentLabel;

  /// Number of clips the loop keeps.
  final int loopSegmentCount;

  /// Incident sensitivity name, for example "medium".
  final String incidentSensitivityName;

  /// Speed refresh interval in milliseconds.
  final int speedRefreshMs;

  /// No motion sensor: clips are not auto-locked.
  final bool incidentDetectionUnavailable;

  /// Location services are off while tracking.
  final bool locationOff;

  /// Incident sensitivity is set to high.
  final bool highIncidentSensitivity;

  /// Warning about a resolution known to fail on this camera, or null.
  final String? presetWarning;

  /// The ride is being saved: a stop, or the ride file still being written
  /// after one. START waits for it.
  bool get isSaving => isStopping || (isPersistingRide && !isRecording);

  /// The START or STOP control cannot be used now.
  bool get isMainBusy =>
      isApplyingSettings || isStarting || isSaving || isPreparingCamera;

  /// Accessibility label of the START or STOP control. The phone harness
  /// reads these strings.
  String get mainControlLabel {
    if (isApplyingSettings) {
      return 'APPLYING SETTINGS...';
    }
    if (isSaving) {
      return 'SAVING RECORDING...';
    }
    if (isStarting) {
      return 'STARTING...';
    }
    if (isPreparingCamera) {
      return 'PREPARING CAMERA...';
    }
    return isRecording ? 'STOP RECORDING' : 'START RECORDING';
  }

  /// Settings can be opened (they apply to the next START while recording).
  bool get settingsEnabled => !isApplyingSettings && !isStarting && !isStopping;

  /// Blackout can be switched on or off.
  bool get blackoutEnabled => !isApplyingSettings && isRecording;

  /// The Rides (or, while recording, Pop-out) control can be used.
  bool get secondaryEnabled =>
      !isApplyingSettings && !isStarting && !isStopping;

  /// LOCK can be used.
  bool get lockEnabled => isRecording && !isStopping;

  /// The state the band at the top names.
  BandState get bandState {
    if (isSaving) {
      return BandState.saving;
    }
    if (isRecording) {
      return BandState.recording;
    }
    if (isStarting) {
      return BandState.starting;
    }
    return BandState.ready;
  }

  /// Resolution the chip shows: the applied one when known.
  int get shownResolution =>
      showApplied ? appliedResolution : requestedResolution;

  /// Frame rate the chip shows: the applied one when known.
  int get shownFps => showApplied ? appliedFps : requestedFps;

  /// Bitrate the chip and the storage estimate use: the applied one when
  /// known. It always equals the request today, so the chip never shows an
  /// "asked" bitrate.
  int get shownBitrateMbps =>
      showApplied ? appliedBitrateMbps : requestedBitrateMbps;

  /// The camera applied another resolution or frame rate than was asked.
  bool get profileDiffers =>
      showApplied &&
      (appliedResolution != requestedResolution || appliedFps != requestedFps);

  /// Applied profile, for example "1080p30".
  String get appliedProfileLabel => '${shownResolution}p$shownFps';

  /// Caption over the chip's values: "APPLIED" only when the values are
  /// the camera's, "NEXT START" for settings that wait for the next START,
  /// "SET" for saved values the camera has not reported.
  String get profileCaption => showApplied
      ? 'APPLIED'
      : settingsPending
      ? 'NEXT START'
      : 'SET';

  /// Start of the chip's semantics label, matching [profileCaption].
  String get profileSemanticsTitle => showApplied
      ? 'Applied recording profile'
      : settingsPending
      ? 'Recording profile from next START'
      : 'Set recording profile';

  /// Requested profile, for example "1080p30".
  String get requestedProfileLabel => '${requestedResolution}p$requestedFps';

  /// The rest of the recording profile, for the details panel, for example
  /// "Cam 0, audio on, 3 min x 5 loop, incident MEDIUM, speed 500 ms".
  String get profileDetail => [
    if (cameraName.isNotEmpty) 'Cam $cameraName',
    audioEnabled ? 'audio on' : 'audio off',
    '$segmentLabel x $loopSegmentCount loop',
    'incident ${incidentSensitivityName.toUpperCase()}',
    'speed $speedRefreshMs ms',
  ].join(', ');
}
