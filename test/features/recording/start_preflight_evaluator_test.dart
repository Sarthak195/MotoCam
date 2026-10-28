import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/features/recording/start_preflight_evaluator.dart';
import 'package:motocam/features/recording/widgets/start_preflight_sheet.dart';

StartPreflightInputs inputs({
  bool cameraPermissionGranted = true,
  bool audioEnabled = true,
  bool microphonePermissionGranted = true,
  bool locationPermissionGranted = true,
  bool locationServicesEnabled = true,
  bool cameraReady = true,
  bool recordingStorageWritable = true,
  bool isAndroid = true,
  bool notificationsGranted = true,
  bool ignoresBatteryOptimization = true,
  bool batteryExemptionOffered = false,
  bool incidentDetectionAvailable = true,
  int? batteryLevelPercent,
  double? batteryTemperatureC,
}) {
  return StartPreflightInputs(
    cameraPermissionGranted: cameraPermissionGranted,
    audioEnabled: audioEnabled,
    microphonePermissionGranted: microphonePermissionGranted,
    locationPermissionGranted: locationPermissionGranted,
    locationServicesEnabled: locationServicesEnabled,
    cameraReady: cameraReady,
    recordingStorageWritable: recordingStorageWritable,
    isAndroid: isAndroid,
    notificationsGranted: notificationsGranted,
    ignoresBatteryOptimization: ignoresBatteryOptimization,
    batteryExemptionOffered: batteryExemptionOffered,
    incidentDetectionAvailable: incidentDetectionAvailable,
    batteryLevelPercent: batteryLevelPercent,
    batteryTemperatureC: batteryTemperatureC,
  );
}

StartPreflightCheck? row(List<StartPreflightCheck> checks, String title) {
  for (final check in checks) {
    if (check.title == title) {
      return check;
    }
  }
  return null;
}

void main() {
  group('StartPreflightEvaluator', () {
    test('everything fine lists the Android rows, all OK', () {
      final checks = StartPreflightEvaluator.evaluate(inputs());
      expect(checks.map((c) => c.title), [
        'Camera Permission',
        'Microphone Permission',
        'Location Permission',
        'Location Services',
        'Camera Ready',
        'Media Write Access',
        'Foreground Notification',
        'Battery Optimization Exemption',
      ]);
      expect(checks.every((c) => c.status == StartPreflightStatus.ok), isTrue);
      expect(StartPreflightEvaluator.hasBlockingIssue(checks), isFalse);
      expect(startPreflightNeedsSheet(checks), isFalse);
    });

    test('each blocking row fails with a blocking failed status', () {
      final cases = <String, StartPreflightInputs>{
        'Camera Permission': inputs(cameraPermissionGranted: false),
        'Microphone Permission': inputs(microphonePermissionGranted: false),
        'Location Permission': inputs(locationPermissionGranted: false),
        'Location Services': inputs(locationServicesEnabled: false),
        'Camera Ready': inputs(cameraReady: false),
        'Media Write Access': inputs(recordingStorageWritable: false),
      };
      cases.forEach((title, input) {
        final checks = StartPreflightEvaluator.evaluate(input);
        final check = row(checks, title)!;
        expect(check.status, StartPreflightStatus.failed, reason: title);
        expect(check.isBlocking, isTrue, reason: title);
        expect(check.opensSheet, isTrue, reason: title);
        expect(
          StartPreflightEvaluator.hasBlockingIssue(checks),
          isTrue,
          reason: title,
        );
        expect(startPreflightNeedsSheet(checks), isTrue, reason: title);
        // Only that row fails.
        expect(
          checks.where((c) => c.status != StartPreflightStatus.ok).length,
          1,
          reason: title,
        );
      });
    });

    test('failed rows keep their explanation', () {
      final checks = StartPreflightEvaluator.evaluate(
        inputs(
          cameraPermissionGranted: false,
          microphonePermissionGranted: false,
          locationPermissionGranted: false,
          locationServicesEnabled: false,
          cameraReady: false,
          recordingStorageWritable: false,
        ),
      );
      expect(
        row(checks, 'Camera Permission')!.detail,
        'Camera permission is required',
      );
      expect(
        row(checks, 'Microphone Permission')!.detail,
        'Microphone is required for audio',
      );
      expect(
        row(checks, 'Location Permission')!.detail,
        'Required for speed, distance, and route telemetry',
      );
      expect(
        row(checks, 'Location Services')!.detail,
        'Turn ON location services in system settings',
      );
      expect(
        row(checks, 'Camera Ready')!.detail,
        'Camera initialization failed, retry from Recording screen',
      );
      expect(
        row(checks, 'Media Write Access')!.detail,
        'Unable to write to app recording storage',
      );
    });

    test('the microphone row is omitted while audio is off', () {
      final checks = StartPreflightEvaluator.evaluate(
        inputs(audioEnabled: false, microphonePermissionGranted: false),
      );
      expect(row(checks, 'Microphone Permission'), isNull);
      expect(StartPreflightEvaluator.hasBlockingIssue(checks), isFalse);
    });

    test('notifications missing is a warning that opens the sheet', () {
      final checks = StartPreflightEvaluator.evaluate(
        inputs(notificationsGranted: false),
      );
      final check = row(checks, 'Foreground Notification')!;
      expect(check.status, StartPreflightStatus.warning);
      expect(check.isBlocking, isFalse);
      expect(check.opensSheet, isTrue);
      expect(StartPreflightEvaluator.hasBlockingIssue(checks), isFalse);
      expect(startPreflightNeedsSheet(checks), isTrue);
    });

    test('battery exemption missing warns and opens the sheet', () {
      final checks = StartPreflightEvaluator.evaluate(
        inputs(ignoresBatteryOptimization: false),
      );
      final check = row(checks, 'Battery Optimization Exemption')!;
      expect(check.status, StartPreflightStatus.warning);
      expect(check.opensSheet, isTrue);
      expect(startPreflightNeedsSheet(checks), isTrue);
    });

    test('after the one-time offer the battery row no longer opens it', () {
      final checks = StartPreflightEvaluator.evaluate(
        inputs(
          ignoresBatteryOptimization: false,
          batteryExemptionOffered: true,
        ),
      );
      final check = row(checks, 'Battery Optimization Exemption')!;
      expect(check.status, StartPreflightStatus.warning);
      expect(check.opensSheet, isFalse);
      expect(startPreflightNeedsSheet(checks), isFalse);
    });

    test('the sheet still opens for a blocking failure after the offer', () {
      final checks = StartPreflightEvaluator.evaluate(
        inputs(
          ignoresBatteryOptimization: false,
          batteryExemptionOffered: true,
          cameraReady: false,
        ),
      );
      expect(startPreflightNeedsSheet(checks), isTrue);
    });

    test('an exempt app is OK regardless of the offer flag', () {
      final checks = StartPreflightEvaluator.evaluate(
        inputs(ignoresBatteryOptimization: true, batteryExemptionOffered: true),
      );
      final check = row(checks, 'Battery Optimization Exemption')!;
      expect(check.status, StartPreflightStatus.ok);
      expect(check.opensSheet, isTrue);
    });

    test('the notification and battery rows are Android only', () {
      final checks = StartPreflightEvaluator.evaluate(
        inputs(
          isAndroid: false,
          notificationsGranted: false,
          ignoresBatteryOptimization: false,
        ),
      );
      expect(row(checks, 'Foreground Notification'), isNull);
      expect(row(checks, 'Battery Optimization Exemption'), isNull);
    });

    test('a missing motion sensor adds a non-blocking warning', () {
      final checks = StartPreflightEvaluator.evaluate(
        inputs(incidentDetectionAvailable: false),
      );
      final check = row(checks, 'Incident Detection')!;
      expect(check.status, StartPreflightStatus.warning);
      expect(check.isBlocking, isFalse);
      expect(check.opensSheet, isTrue);
      expect(
        row(StartPreflightEvaluator.evaluate(inputs()), 'Incident Detection'),
        isNull,
      );
    });

    test('battery level row: unknown, fine, the boundary and low', () {
      expect(
        row(StartPreflightEvaluator.evaluate(inputs()), 'Battery Level'),
        isNull,
      );
      final fine = row(
        StartPreflightEvaluator.evaluate(inputs(batteryLevelPercent: 80)),
        'Battery Level',
      )!;
      expect(fine.status, StartPreflightStatus.ok);
      expect(fine.detail, '80%');
      final boundary = row(
        StartPreflightEvaluator.evaluate(inputs(batteryLevelPercent: 15)),
        'Battery Level',
      )!;
      expect(boundary.status, StartPreflightStatus.ok);
      final low = row(
        StartPreflightEvaluator.evaluate(inputs(batteryLevelPercent: 14)),
        'Battery Level',
      )!;
      expect(low.status, StartPreflightStatus.warning);
      expect(low.detail, '14% (low for long rides)');
      expect(low.isBlocking, isFalse);
    });

    test('temperature row: unknown, fine, below the boundary and hot', () {
      expect(
        row(StartPreflightEvaluator.evaluate(inputs()), 'Device Temperature'),
        isNull,
      );
      final fine = row(
        StartPreflightEvaluator.evaluate(inputs(batteryTemperatureC: 35.04)),
        'Device Temperature',
      )!;
      expect(fine.status, StartPreflightStatus.ok);
      expect(fine.detail, '35.0 C');
      final below = row(
        StartPreflightEvaluator.evaluate(inputs(batteryTemperatureC: 42.9)),
        'Device Temperature',
      )!;
      expect(below.status, StartPreflightStatus.ok);
      final hot = row(
        StartPreflightEvaluator.evaluate(inputs(batteryTemperatureC: 43.0)),
        'Device Temperature',
      )!;
      expect(hot.status, StartPreflightStatus.warning);
      expect(hot.detail, '43.0 C (high temperature)');
      expect(hot.isBlocking, isFalse);
    });

    test('optional rows come last in display order', () {
      final checks = StartPreflightEvaluator.evaluate(
        inputs(
          incidentDetectionAvailable: false,
          batteryLevelPercent: 50,
          batteryTemperatureC: 30,
        ),
      );
      expect(checks.map((c) => c.title).toList().sublist(8), [
        'Incident Detection',
        'Battery Level',
        'Device Temperature',
      ]);
    });
  });
}
