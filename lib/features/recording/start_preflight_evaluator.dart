// lib/features/recording/start_preflight_evaluator.dart
//
// Pure evaluation of the START checklist. The screen gathers the platform
// status into [StartPreflightInputs]; this file only decides each row.

import 'widgets/start_preflight_sheet.dart';

/// Everything the START checklist depends on, gathered by the caller.
class StartPreflightInputs {
  /// Creates the inputs.
  const StartPreflightInputs({
    required this.cameraPermissionGranted,
    required this.audioEnabled,
    required this.microphonePermissionGranted,
    required this.locationPermissionGranted,
    required this.locationServicesEnabled,
    required this.cameraReady,
    required this.recordingStorageWritable,
    required this.isAndroid,
    required this.notificationsGranted,
    required this.ignoresBatteryOptimization,
    required this.batteryExemptionOffered,
    required this.incidentDetectionAvailable,
    this.batteryLevelPercent,
    this.batteryTemperatureC,
  });

  /// Whether the camera permission is granted.
  final bool cameraPermissionGranted;

  /// Whether audio recording is on (the microphone row only exists then).
  final bool audioEnabled;

  /// Whether the microphone permission is granted.
  final bool microphonePermissionGranted;

  /// Whether the while-in-use location permission is granted.
  final bool locationPermissionGranted;

  /// Whether the system location services are on.
  final bool locationServicesEnabled;

  /// Whether the camera controller is initialized.
  final bool cameraReady;

  /// Whether a probe file could be written to the recordings directory.
  final bool recordingStorageWritable;

  /// Whether this is Android (the notification and battery rows are
  /// Android-only).
  final bool isAndroid;

  /// Whether the notification permission is granted (Android only).
  final bool notificationsGranted;

  /// Whether the app is exempt from battery optimisation (Android only).
  final bool ignoresBatteryOptimization;

  /// Whether the one-time battery-exemption offer was already made.
  final bool batteryExemptionOffered;

  /// Whether the device has the motion sensor automatic crash locking needs.
  final bool incidentDetectionAvailable;

  /// Battery charge in percent, or `null` when unknown (the row is omitted).
  final int? batteryLevelPercent;

  /// Battery temperature in degrees Celsius, or `null` when unknown (the row
  /// is omitted).
  final double? batteryTemperatureC;
}

/// Decides the rows of the START checklist from [StartPreflightInputs].
class StartPreflightEvaluator {
  const StartPreflightEvaluator._();

  /// Battery percentage below which the battery row warns.
  static const int lowBatteryPercent = 15;

  /// Battery temperature (degrees Celsius) from which the temperature row
  /// warns.
  static const double hotBatteryCelsius = 43.0;

  /// Returns the checklist rows in display order.
  ///
  /// The permission, location services, camera and storage rows are blocking
  /// when they fail. The rest only warn. The battery-exemption row stops
  /// opening the sheet by itself once its one-time offer was made
  /// ([StartPreflightInputs.batteryExemptionOffered]) and the app is still
  /// not exempt.
  static List<StartPreflightCheck> evaluate(StartPreflightInputs inputs) {
    final checks = <StartPreflightCheck>[
      _blocking(
        title: 'Camera Permission',
        passed: inputs.cameraPermissionGranted,
        okDetail: 'Granted',
        failDetail: 'Camera permission is required',
      ),
      if (inputs.audioEnabled)
        _blocking(
          title: 'Microphone Permission',
          passed: inputs.microphonePermissionGranted,
          okDetail: 'Granted',
          failDetail: 'Microphone is required for audio',
        ),
      _blocking(
        title: 'Location Permission',
        passed: inputs.locationPermissionGranted,
        okDetail: 'Granted',
        failDetail: 'Required for speed, distance, and route telemetry',
      ),
      _blocking(
        title: 'Location Services',
        passed: inputs.locationServicesEnabled,
        okDetail: 'Enabled',
        failDetail: 'Turn ON location services in system settings',
      ),
      _blocking(
        title: 'Camera Ready',
        passed: inputs.cameraReady,
        okDetail: 'Preview and encoder are initialized',
        failDetail: 'Camera initialization failed, retry from Recording screen',
      ),
      _blocking(
        title: 'Media Write Access',
        passed: inputs.recordingStorageWritable,
        okDetail: 'App recording storage is writable',
        failDetail: 'Unable to write to app recording storage',
      ),
    ];

    if (inputs.isAndroid) {
      checks.add(
        _advisory(
          title: 'Foreground Notification',
          passed: inputs.notificationsGranted,
          okDetail: 'Allowed',
          warnDetail:
              'Recommended so background recording status stays visible',
        ),
      );

      // After the one-time exemption offer the rider has decided, so the row
      // is still listed but no longer opens the sheet on every START.
      final offerDeclined =
          !inputs.ignoresBatteryOptimization && inputs.batteryExemptionOffered;
      checks.add(
        _advisory(
          title: 'Battery Optimization Exemption',
          passed: inputs.ignoresBatteryOptimization,
          okDetail: 'Enabled',
          warnDetail: 'Recommended for stable screen-off recording',
          opensSheet: !offerDeclined,
        ),
      );
    }

    if (!inputs.incidentDetectionAvailable) {
      checks.add(
        const StartPreflightCheck(
          title: 'Incident Detection',
          detail:
              'Unavailable: no motion sensor. Clips are not auto-locked; '
              'use LOCK.',
          status: StartPreflightStatus.warning,
          isBlocking: false,
        ),
      );
    }

    final batteryLevel = inputs.batteryLevelPercent;
    if (batteryLevel != null) {
      final low = batteryLevel < lowBatteryPercent;
      checks.add(
        StartPreflightCheck(
          title: 'Battery Level',
          detail: '$batteryLevel%${low ? ' (low for long rides)' : ''}',
          status: low ? StartPreflightStatus.warning : StartPreflightStatus.ok,
          isBlocking: false,
        ),
      );
    }

    final batteryTemp = inputs.batteryTemperatureC;
    if (batteryTemp != null) {
      final hot = batteryTemp >= hotBatteryCelsius;
      checks.add(
        StartPreflightCheck(
          title: 'Device Temperature',
          detail:
              '${batteryTemp.toStringAsFixed(1)} C'
              '${hot ? ' (high temperature)' : ''}',
          status: hot ? StartPreflightStatus.warning : StartPreflightStatus.ok,
          isBlocking: false,
        ),
      );
    }

    return checks;
  }

  /// Whether any row is a blocking row that failed.
  static bool hasBlockingIssue(Iterable<StartPreflightCheck> checks) {
    return checks.any(
      (check) =>
          check.isBlocking && check.status == StartPreflightStatus.failed,
    );
  }

  static StartPreflightCheck _blocking({
    required String title,
    required bool passed,
    required String okDetail,
    required String failDetail,
  }) {
    return StartPreflightCheck(
      title: title,
      detail: passed ? okDetail : failDetail,
      status: passed ? StartPreflightStatus.ok : StartPreflightStatus.failed,
      isBlocking: true,
    );
  }

  static StartPreflightCheck _advisory({
    required String title,
    required bool passed,
    required String okDetail,
    required String warnDetail,
    bool opensSheet = true,
  }) {
    return StartPreflightCheck(
      title: title,
      detail: passed ? okDetail : warnDetail,
      status: passed ? StartPreflightStatus.ok : StartPreflightStatus.warning,
      isBlocking: false,
      opensSheet: opensSheet,
    );
  }
}
