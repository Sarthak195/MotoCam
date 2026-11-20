// The pure helpers behind the redesigned recording screen: the thermal
// level, the storage estimate, the band clock, the parked test and the
// view snapshot's derived values.

import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/core/ui/state_band.dart';
import 'package:motocam/features/recording/recording_screen_logic.dart';
import 'package:motocam/features/recording/start_preflight_evaluator.dart';
import 'package:motocam/features/recording/widgets/recording_view_state.dart';

RecordingViewState _view({
  bool isRecording = false,
  bool isApplyingSettings = false,
  bool isStarting = false,
  bool isStopping = false,
  bool isPersistingRide = false,
  bool isPreparingCamera = false,
  bool showApplied = true,
  int appliedResolution = 1080,
  int appliedFps = 30,
  int requestedResolution = 1080,
  int requestedFps = 30,
  int requestedBitrateMbps = 8,
  int appliedBitrateMbps = 8,
}) {
  return RecordingViewState(
    isRecording: isRecording,
    isBlackoutMode: false,
    isApplyingSettings: isApplyingSettings,
    isStarting: isStarting,
    isStopping: isStopping,
    isPersistingRide: isPersistingRide,
    isPreparingCamera: isPreparingCamera,
    isSegmentLocked: false,
    cameraName: '',
    requestedResolution: requestedResolution,
    requestedFps: requestedFps,
    appliedResolution: appliedResolution,
    appliedFps: appliedFps,
    showApplied: showApplied,
    requestedBitrateMbps: requestedBitrateMbps,
    appliedBitrateMbps: appliedBitrateMbps,
    audioEnabled: true,
    segmentLabel: '3 min',
    loopSegmentCount: 5,
    incidentSensitivityName: 'medium',
    speedRefreshMs: 500,
    incidentDetectionUnavailable: false,
    locationOff: false,
    highIncidentSensitivity: false,
    presetWarning: null,
  );
}

void main() {
  group('thermalLevelFor', () {
    test('maps the platform thermal status to three levels', () {
      expect(thermalLevelFor(thermalStatus: 'none'), ThermalLevel.normal);
      expect(thermalLevelFor(thermalStatus: 'light'), ThermalLevel.normal);
      expect(thermalLevelFor(thermalStatus: 'moderate'), ThermalLevel.warm);
      for (final status in ['severe', 'critical', 'emergency', 'shutdown']) {
        expect(thermalLevelFor(thermalStatus: status), ThermalLevel.hot);
      }
    });

    test('is unknown with neither a status nor a temperature', () {
      expect(thermalLevelFor(), ThermalLevel.unknown);
      expect(thermalLevelFor(thermalStatus: 'unknown'), ThermalLevel.unknown);
    });

    test('falls back to the battery temperature, hot from 43 C', () {
      expect(thermalLevelFor(batteryTemperatureC: 42.9), ThermalLevel.normal);
      expect(thermalLevelFor(batteryTemperatureC: 43), ThermalLevel.hot);
      expect(
        thermalLevelFor(thermalStatus: 'unknown', batteryTemperatureC: 44),
        ThermalLevel.hot,
      );
    });

    test('the battery threshold is the START checklist one', () {
      expect(
        thermalHotBatteryCelsius,
        StartPreflightEvaluator.hotBatteryCelsius,
      );
    });

    test('a hot battery wins over a calm status, a cool one keeps it', () {
      expect(
        thermalLevelFor(thermalStatus: 'none', batteryTemperatureC: 45),
        ThermalLevel.hot,
      );
      expect(
        thermalLevelFor(thermalStatus: 'moderate', batteryTemperatureC: 30),
        ThermalLevel.warm,
      );
      expect(
        thermalLevelFor(thermalStatus: 'severe', batteryTemperatureC: 30),
        ThermalLevel.hot,
      );
    });
  });

  group('storage estimate', () {
    test('is null when the free space is unknown', () {
      expect(storageHoursLeft(freeBytes: null, bitrateMbps: 20), isNull);
    });

    test('hours of video at the bitrate, never below 20 Mbps', () {
      // 20 Mbps is 9 GB an hour.
      expect(
        storageHoursLeft(freeBytes: 9000000000, bitrateMbps: 20),
        closeTo(1.0, 1e-9),
      );
      expect(
        storageHoursLeft(freeBytes: 9000000000, bitrateMbps: 8),
        closeTo(1.0, 1e-9),
      );
      expect(
        storageHoursLeft(freeBytes: 9000000000, bitrateMbps: 40),
        closeTo(0.5, 1e-9),
      );
    });

    test('labels floor to one decimal, then whole hours, then 99+', () {
      expect(storageHoursLabel(6.29), '6.2');
      expect(storageHoursLabel(0.04), '0.0');
      expect(storageHoursLabel(9.99), '9.9');
      expect(storageHoursLabel(14.7), '14');
      expect(storageHoursLabel(150), '99+');
    });

    test('warns under an hour', () {
      expect(storageLowHours, 1.0);
    });
  });

  test('the band clock reads MM:SS, then H:MM:SS', () {
    expect(formatBandElapsed(Duration.zero), '00:00');
    expect(
      formatBandElapsed(const Duration(minutes: 41, seconds: 12)),
      '41:12',
    );
    expect(
      formatBandElapsed(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '1:02:03',
    );
    expect(formatBandElapsed(const Duration(seconds: -5)), '00:00');
  });

  test('parked is below 5 km/h', () {
    expect(isParkedSpeed(0), isTrue);
    expect(isParkedSpeed(4.9), isTrue);
    expect(isParkedSpeed(5), isFalse);
    expect(isParkedSpeed(62), isFalse);
    expect(isParkedSpeed(double.nan), isTrue);
  });

  group('RecordingViewState', () {
    test('band state follows saving, recording, starting, ready', () {
      expect(_view().bandState, BandState.ready);
      expect(_view(isStarting: true).bandState, BandState.starting);
      expect(_view(isRecording: true).bandState, BandState.recording);
      expect(
        _view(isRecording: true, isStopping: true).bandState,
        BandState.saving,
      );
      // The ride file is still being written after the camera stopped.
      expect(_view(isPersistingRide: true).bandState, BandState.saving);
      expect(_view(isApplyingSettings: true).bandState, BandState.ready);
    });

    test('the main control keeps the harness labels in every state', () {
      expect(_view().mainControlLabel, 'START RECORDING');
      expect(_view(isRecording: true).mainControlLabel, 'STOP RECORDING');
      expect(
        _view(isApplyingSettings: true).mainControlLabel,
        'APPLYING SETTINGS...',
      );
      expect(
        _view(isRecording: true, isStopping: true).mainControlLabel,
        'SAVING RECORDING...',
      );
      expect(_view(isStarting: true).mainControlLabel, 'STARTING...');
      expect(
        _view(isPreparingCamera: true).mainControlLabel,
        'PREPARING CAMERA...',
      );
      expect(_view(isStarting: true).isMainBusy, isTrue);
      expect(_view().isMainBusy, isFalse);
    });

    test('the applied chip shows the applied profile and flags a resolution '
        'or frame rate the camera changed', () {
      final same = _view();
      expect(same.appliedProfileLabel, '1080p30');
      expect(same.profileDiffers, isFalse);

      final lower = _view(appliedResolution: 720);
      expect(lower.appliedProfileLabel, '720p30');
      expect(lower.requestedProfileLabel, '1080p30');
      expect(lower.profileDiffers, isTrue);

      // Before the camera is up, the request is all there is.
      final pending = _view(appliedResolution: 720, showApplied: false);
      expect(pending.appliedProfileLabel, '1080p30');
      expect(pending.profileDiffers, isFalse);
    });

    test('the bitrate never shows an asked variant', () {
      final view = _view(requestedBitrateMbps: 8, appliedBitrateMbps: 20);
      expect(view.shownBitrateMbps, 20);
      expect(view.profileDiffers, isFalse);
    });

    test('LOCK only while recording and not stopping; Settings while not '
        'starting or stopping', () {
      expect(_view().lockEnabled, isFalse);
      expect(_view(isRecording: true).lockEnabled, isTrue);
      expect(_view(isRecording: true, isStopping: true).lockEnabled, isFalse);
      expect(_view(isRecording: true).settingsEnabled, isTrue);
      expect(_view(isStarting: true).settingsEnabled, isFalse);
      expect(_view().blackoutEnabled, isFalse);
      expect(_view(isRecording: true).blackoutEnabled, isTrue);
    });
  });
}
