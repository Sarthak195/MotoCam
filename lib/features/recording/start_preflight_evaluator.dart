// lib/features/recording/start_preflight_evaluator.dart
//
// Pure evaluation of the START checklist. The screen gathers the platform
// status into [StartPreflightInputs]; this file only decides each row and
// how the rows are grouped on the checklist page.

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

/// One row of the checklist page: a group (Permissions, Storage, GPS...)
/// that is either all OK, or one of its checks that is not OK.
class StartPreflightRow {
  /// Creates a row.
  const StartPreflightRow({
    required this.group,
    required this.title,
    required this.detail,
    required this.status,
    required this.isBlocking,
    this.fix,
  });

  /// The group this row stands for.
  final StartPreflightGroup group;

  /// Group name shown as the row title, for example "Permissions".
  final String title;

  /// What is wrong, or the OK summary of the whole group.
  final String detail;

  /// The row's state: OK only when every check of the group is OK.
  final StartPreflightStatus status;

  /// Whether this row is a failed blocking check (START stays disabled).
  final bool isBlocking;

  /// What the row's Fix button does; null when nothing can be fixed here.
  final StartPreflightFix? fix;
}

/// The checklist page's content: the rows in display order and the phone
/// temperature, which is shown as a chip and not as a row.
class StartPreflightLayout {
  /// Creates a layout.
  const StartPreflightLayout({required this.rows, this.heat});

  /// Rows in display order.
  final List<StartPreflightRow> rows;

  /// The phone temperature check, or null when the temperature is unknown.
  final StartPreflightCheck? heat;
}

/// Decides the rows of the START checklist from [StartPreflightInputs].
class StartPreflightEvaluator {
  const StartPreflightEvaluator._();

  /// Battery percentage below which the battery row warns.
  static const int lowBatteryPercent = 15;

  /// Battery temperature (degrees Celsius) from which the temperature row
  /// warns.
  static const double hotBatteryCelsius = 43.0;

  /// Display order of the groups on the checklist page. The phone
  /// temperature is not a row (it is the heat chip).
  static const List<StartPreflightGroup> groupOrder = [
    StartPreflightGroup.permissions,
    StartPreflightGroup.camera,
    StartPreflightGroup.storage,
    StartPreflightGroup.gps,
    StartPreflightGroup.battery,
    StartPreflightGroup.notifications,
    StartPreflightGroup.crashDetection,
    StartPreflightGroup.other,
  ];

  /// Returns the checklist rows in display order.
  ///
  /// The permission, location services, camera and storage rows are blocking
  /// when they fail. The rest only warn. The battery-exemption row stops
  /// opening the sheet by itself once its one-time offer was made
  /// ([StartPreflightInputs.batteryExemptionOffered]) and the app is still
  /// not exempt. Incident detection, battery level and phone temperature
  /// never open the sheet by themselves: the rider cannot fix them before
  /// START, so they are only shown when the sheet opens for another check.
  static List<StartPreflightCheck> evaluate(StartPreflightInputs inputs) {
    final checks = <StartPreflightCheck>[
      _blocking(
        title: 'Camera Permission',
        group: StartPreflightGroup.permissions,
        fix: StartPreflightFix.appSettings,
        passed: inputs.cameraPermissionGranted,
        okDetail: 'Granted',
        failDetail: 'Camera permission is required',
      ),
      if (inputs.audioEnabled)
        _blocking(
          title: 'Microphone Permission',
          group: StartPreflightGroup.permissions,
          fix: StartPreflightFix.appSettings,
          passed: inputs.microphonePermissionGranted,
          okDetail: 'Granted',
          failDetail: 'Microphone is required for audio',
        ),
      _blocking(
        title: 'Location Permission',
        group: StartPreflightGroup.permissions,
        fix: StartPreflightFix.appSettings,
        passed: inputs.locationPermissionGranted,
        okDetail: 'Granted',
        failDetail: 'Required for speed, distance, and route telemetry',
      ),
      _blocking(
        title: 'Location Services',
        group: StartPreflightGroup.gps,
        fix: StartPreflightFix.locationServices,
        passed: inputs.locationServicesEnabled,
        okDetail: 'Location is on',
        failDetail: 'Location is off. Turn it on to start recording',
      ),
      _blocking(
        title: 'Camera Ready',
        group: StartPreflightGroup.camera,
        fix: StartPreflightFix.retryCamera,
        passed: inputs.cameraReady,
        okDetail: 'Preview and encoder are initialized',
        failDetail: 'Camera initialization failed, retry',
      ),
      _blocking(
        title: 'Media Write Access',
        group: StartPreflightGroup.storage,
        passed: inputs.recordingStorageWritable,
        okDetail: 'App recording storage is writable',
        failDetail: 'Unable to write to app recording storage',
      ),
    ];

    if (inputs.isAndroid) {
      checks.add(
        _advisory(
          title: 'Foreground Notification',
          group: StartPreflightGroup.notifications,
          fix: StartPreflightFix.appSettings,
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
          group: StartPreflightGroup.battery,
          fix: StartPreflightFix.batteryExemption,
          passed: inputs.ignoresBatteryOptimization,
          okDetail: 'Exempt from battery saver',
          warnDetail: 'Battery saver may stop recording',
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
          opensSheet: false,
          group: StartPreflightGroup.crashDetection,
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
          opensSheet: false,
          group: StartPreflightGroup.battery,
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
          opensSheet: false,
          group: StartPreflightGroup.heat,
          measurement: '${batteryTemp.toStringAsFixed(1)} C',
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

  /// Name of [group] as the checklist shows it.
  static String groupTitle(StartPreflightGroup group) {
    switch (group) {
      case StartPreflightGroup.permissions:
        return 'Permissions';
      case StartPreflightGroup.camera:
        return 'Camera';
      case StartPreflightGroup.storage:
        return 'Storage';
      case StartPreflightGroup.gps:
        return 'GPS';
      case StartPreflightGroup.battery:
        return 'Battery';
      case StartPreflightGroup.notifications:
        return 'Notification';
      case StartPreflightGroup.crashDetection:
        return 'Crash detection';
      case StartPreflightGroup.heat:
        return 'Phone temperature';
      case StartPreflightGroup.other:
        return 'Other';
    }
  }

  /// Groups [checks] into the rows of the checklist page.
  ///
  /// A group whose checks are all OK becomes one OK row with a summary
  /// ("Camera, microphone, location" for the permissions). A group with a
  /// check that is not OK becomes one row per such check, carrying that
  /// check's detail, blocking flag and fix; its OK checks are not repeated.
  /// The phone temperature is returned apart, for the heat chip.
  static StartPreflightLayout layout(List<StartPreflightCheck> checks) {
    StartPreflightCheck? heat;
    final byGroup = <StartPreflightGroup, List<StartPreflightCheck>>{};
    for (final check in checks) {
      if (check.group == StartPreflightGroup.heat) {
        heat = check;
        continue;
      }
      byGroup.putIfAbsent(check.group, () => []).add(check);
    }

    final rows = <StartPreflightRow>[];
    for (final group in groupOrder) {
      final members = byGroup[group];
      if (members == null || members.isEmpty) {
        continue;
      }
      final open = members
          .where((check) => check.status != StartPreflightStatus.ok)
          .toList();
      if (open.isEmpty) {
        rows.add(
          StartPreflightRow(
            group: group,
            title: group == StartPreflightGroup.other
                ? members.map((check) => check.title).join(', ')
                : groupTitle(group),
            detail: _okSummary(group, members),
            status: StartPreflightStatus.ok,
            isBlocking: false,
          ),
        );
        continue;
      }
      for (final check in open) {
        rows.add(
          StartPreflightRow(
            group: group,
            title: group == StartPreflightGroup.other
                ? check.title
                : groupTitle(group),
            detail: check.detail,
            status: check.status,
            isBlocking:
                check.isBlocking && check.status == StartPreflightStatus.failed,
            fix: check.fix,
          ),
        );
      }
    }
    return StartPreflightLayout(rows: rows, heat: heat);
  }

  static String _okSummary(
    StartPreflightGroup group,
    List<StartPreflightCheck> members,
  ) {
    if (group == StartPreflightGroup.permissions) {
      final names = [
        for (final check in members)
          switch (check.title) {
            'Camera Permission' => 'camera',
            'Microphone Permission' => 'microphone',
            'Location Permission' => 'location',
            _ => check.title.toLowerCase(),
          },
      ].join(', ');
      return names.isEmpty
          ? names
          : '${names[0].toUpperCase()}${names.substring(1)}';
    }
    return members.map((check) => check.detail).join(', ');
  }

  static StartPreflightCheck _blocking({
    required String title,
    required StartPreflightGroup group,
    required bool passed,
    required String okDetail,
    required String failDetail,
    StartPreflightFix? fix,
  }) {
    return StartPreflightCheck(
      title: title,
      detail: passed ? okDetail : failDetail,
      status: passed ? StartPreflightStatus.ok : StartPreflightStatus.failed,
      isBlocking: true,
      group: group,
      fix: fix,
    );
  }

  static StartPreflightCheck _advisory({
    required String title,
    required StartPreflightGroup group,
    required bool passed,
    required String okDetail,
    required String warnDetail,
    StartPreflightFix? fix,
    bool opensSheet = true,
  }) {
    return StartPreflightCheck(
      title: title,
      detail: passed ? okDetail : warnDetail,
      status: passed ? StartPreflightStatus.ok : StartPreflightStatus.warning,
      isBlocking: false,
      opensSheet: opensSheet,
      group: group,
      fix: fix,
    );
  }
}
