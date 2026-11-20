// Widget tests for the START checklist page (board A-Checklist): Fix
// buttons, the recheck after a fix, the disabled START while a blocking
// item is open, the heat chip, and no overflow at 390x844 and 844x390.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/core/theme/app_theme.dart';
import 'package:motocam/features/recording/start_preflight_evaluator.dart';
import 'package:motocam/features/recording/widgets/start_preflight_sheet.dart';

import '../../../support/load_fonts.dart';

List<StartPreflightCheck> evaluate({
  bool cameraPermissionGranted = true,
  bool locationPermissionGranted = true,
  bool locationServicesEnabled = true,
  bool cameraReady = true,
  bool recordingStorageWritable = true,
  bool notificationsGranted = true,
  bool ignoresBatteryOptimization = true,
  bool incidentDetectionAvailable = true,
  int? batteryLevelPercent,
  double? batteryTemperatureC,
}) {
  return StartPreflightEvaluator.evaluate(
    StartPreflightInputs(
      cameraPermissionGranted: cameraPermissionGranted,
      audioEnabled: true,
      microphonePermissionGranted: true,
      locationPermissionGranted: locationPermissionGranted,
      locationServicesEnabled: locationServicesEnabled,
      cameraReady: cameraReady,
      recordingStorageWritable: recordingStorageWritable,
      isAndroid: true,
      notificationsGranted: notificationsGranted,
      ignoresBatteryOptimization: ignoresBatteryOptimization,
      batteryExemptionOffered: false,
      incidentDetectionAvailable: incidentDetectionAvailable,
      batteryLevelPercent: batteryLevelPercent,
      batteryTemperatureC: batteryTemperatureC,
    ),
  );
}

/// Opens the checklist from a button; [result] receives what
/// [showStartPreflightPage] completes with.
Future<void> openChecklist(
  WidgetTester tester, {
  required List<StartPreflightCheck> checks,
  required void Function(bool) onResult,
  StartPreflightFixHandler? onFix,
  StartPreflightRecheck? onRecheck,
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                onResult(
                  await showStartPreflightPage(
                    context,
                    checks: checks,
                    onFix: onFix,
                    onRecheck: onRecheck,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder get startButton => find.bySemanticsLabel('Start Recording');

Future<void> tapStart(WidgetTester tester) async {
  await tester.ensureVisible(find.text('START'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('START'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadBundledFonts);

  group('layout', () {
    final worstCase = evaluate(
      cameraPermissionGranted: false,
      locationPermissionGranted: false,
      locationServicesEnabled: false,
      cameraReady: false,
      recordingStorageWritable: false,
      notificationsGranted: false,
      ignoresBatteryOptimization: false,
      incidentDetectionAvailable: false,
      batteryLevelPercent: 9,
      batteryTemperatureC: 46,
    );
    for (final size in const [Size(390, 844), Size(844, 390)]) {
      for (final textScale in const [1.0, 1.3]) {
        testWidgets('no overflow at ${size.width.toInt()}x'
            '${size.height.toInt()}, text x$textScale', (tester) async {
          await openChecklist(
            tester,
            checks: worstCase,
            onResult: (_) {},
            onFix: (_) async {},
            size: size,
            textScale: textScale,
          );
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.text('START'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(startButton, findsOneWidget);
        });
      }
    }

    testWidgets('all OK fits without scrolling in portrait', (tester) async {
      await openChecklist(
        tester,
        checks: evaluate(batteryLevelPercent: 80, batteryTemperatureC: 30),
        onResult: (_) {},
      );
      expect(tester.takeException(), isNull);
      final start = tester.getRect(find.text('START'));
      expect(start.bottom, lessThanOrEqualTo(844));
      expect(find.text('All checks OK.'), findsOneWidget);
    });

    testWidgets('meets the Android tap target guideline', (tester) async {
      final handle = tester.ensureSemantics();
      await openChecklist(
        tester,
        checks: evaluate(
          locationServicesEnabled: false,
          ignoresBatteryOptimization: false,
        ),
        onResult: (_) {},
        onFix: (_) async {},
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('the harness labels are kept', (tester) async {
      await openChecklist(tester, checks: evaluate(), onResult: (_) {});
      expect(find.bySemanticsLabel('Ready To Record?'), findsOneWidget);
      expect(find.text('Ready to record?'), findsOneWidget);
      expect(startButton, findsOneWidget);
      expect(find.bySemanticsLabel('Close'), findsOneWidget);
    });
  });

  group('rows', () {
    testWidgets('grouped rows: OK groups once, open checks with Fix', (
      tester,
    ) async {
      await openChecklist(
        tester,
        checks: evaluate(
          ignoresBatteryOptimization: false,
          locationServicesEnabled: false,
        ),
        onResult: (_) {},
        onFix: (_) async {},
      );
      expect(find.text('Permissions'), findsOneWidget);
      expect(find.text('Camera, microphone, location'), findsOneWidget);
      expect(find.text('GPS'), findsOneWidget);
      expect(
        find.text('Location is off. Turn it on to start recording'),
        findsOneWidget,
      );
      expect(find.text('Battery saver may stop recording'), findsOneWidget);
      expect(find.bySemanticsLabel('Fix GPS'), findsOneWidget);
      expect(find.bySemanticsLabel('Fix Battery'), findsOneWidget);
      expect(find.text('Fix'), findsNWidgets(2));
    });

    testWidgets('without a fix handler no Fix button is drawn', (tester) async {
      await openChecklist(
        tester,
        checks: evaluate(locationServicesEnabled: false),
        onResult: (_) {},
      );
      expect(find.text('Fix'), findsNothing);
      expect(find.text('Blocked'), findsOneWidget);
    });

    testWidgets('a row that cannot be fixed has no Fix button', (tester) async {
      await openChecklist(
        tester,
        checks: evaluate(
          recordingStorageWritable: false,
          incidentDetectionAvailable: false,
        ),
        onResult: (_) {},
        onFix: (_) async {},
      );
      expect(find.bySemanticsLabel('Fix Storage'), findsNothing);
      expect(find.bySemanticsLabel('Fix Crash detection'), findsNothing);
      expect(find.text('Fix'), findsNothing);
    });

    testWidgets('heat is a chip, not a row, and does not block START', (
      tester,
    ) async {
      var result = false;
      await openChecklist(
        tester,
        checks: evaluate(batteryTemperatureC: 45),
        onResult: (value) => result = value,
      );
      expect(
        find.bySemanticsLabel('Phone temperature warm, 45.0 C'),
        findsOneWidget,
      );
      expect(find.text('Device Temperature'), findsNothing);
      expect(find.text('Phone temperature'), findsNothing);
      expect(
        find.text(
          'Warm. Shown as a chip while you ride. It does not block START.',
        ),
        findsOneWidget,
      );
      await tapStart(tester);
      expect(result, isTrue);
    });
  });

  group('START', () {
    testWidgets('disabled while a blocking item is open', (tester) async {
      bool? result;
      await openChecklist(
        tester,
        checks: evaluate(locationServicesEnabled: false),
        onResult: (value) => result = value,
        onFix: (_) async {},
      );
      expect(find.text('Blocked. Fix GPS to start.'), findsOneWidget);
      final semantics = tester.getSemantics(startButton);
      expect(semantics.flagsCollection.isEnabled, isNot(true));
      await tapStart(tester);
      expect(result, isNull);
      expect(find.text('Ready to record?'), findsOneWidget);
    });

    testWidgets('the button node carries only its label, the caption is '
        'its own node', (tester) async {
      final handle = tester.ensureSemantics();
      await openChecklist(
        tester,
        checks: evaluate(batteryLevelPercent: 80, batteryTemperatureC: 30),
        onResult: (_) {},
      );
      // Android joins value, label and hint into the content description,
      // and the phone harness matches "Start Recording" exactly.
      final data = tester.getSemantics(startButton).getSemanticsData();
      expect(data.label, 'Start Recording');
      expect(data.hint, isEmpty);
      expect(data.value, isEmpty);
      expect(find.bySemanticsLabel('All checks OK.'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the caption names every blocking group', (tester) async {
      await openChecklist(
        tester,
        checks: evaluate(
          cameraPermissionGranted: false,
          locationServicesEnabled: false,
          recordingStorageWritable: false,
        ),
        onResult: (_) {},
      );
      expect(
        find.text('Blocked. Fix Permissions, Storage and GPS to start.'),
        findsOneWidget,
      );
    });

    testWidgets('open warnings leave START enabled', (tester) async {
      bool? result;
      await openChecklist(
        tester,
        checks: evaluate(ignoresBatteryOptimization: false),
        onResult: (value) => result = value,
      );
      expect(find.text('1 item open. Recording still works.'), findsOneWidget);
      await tapStart(tester);
      expect(result, isTrue);
    });

    testWidgets('Close completes with false', (tester) async {
      bool? result;
      await openChecklist(
        tester,
        checks: evaluate(ignoresBatteryOptimization: false),
        onResult: (value) => result = value,
      );
      await tester.tap(find.bySemanticsLabel('Close'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });
  });

  group('Fix', () {
    testWidgets('runs the fix, rechecks, and a fixed GPS enables START', (
      tester,
    ) async {
      final fixes = <StartPreflightFix>[];
      final pending = Completer<void>();
      var rechecks = 0;
      bool? result;
      await openChecklist(
        tester,
        checks: evaluate(locationServicesEnabled: false),
        onResult: (value) => result = value,
        onFix: (fix) {
          fixes.add(fix);
          return pending.future;
        },
        onRecheck: () async {
          rechecks++;
          return evaluate();
        },
      );

      await tester.tap(find.bySemanticsLabel('Fix GPS'));
      await tester.pump();
      expect(fixes, [StartPreflightFix.locationServices]);
      expect(find.text('Checking again...'), findsOneWidget);
      // A second tap while the fix runs does nothing.
      await tester.tap(find.bySemanticsLabel('Fix GPS'));
      await tester.pump();
      expect(fixes, hasLength(1));

      pending.complete();
      await tester.pumpAndSettle();
      expect(rechecks, 1);
      expect(find.text('All checks OK.'), findsOneWidget);
      expect(find.text('Fix'), findsNothing);

      await tapStart(tester);
      expect(result, isTrue);
    });

    testWidgets('each row passes its own fix kind', (tester) async {
      final fixes = <StartPreflightFix>[];
      await openChecklist(
        tester,
        checks: evaluate(
          cameraPermissionGranted: false,
          cameraReady: false,
          notificationsGranted: false,
          ignoresBatteryOptimization: false,
        ),
        onResult: (_) {},
        onFix: (fix) async => fixes.add(fix),
      );
      for (final label in const [
        'Fix Permissions',
        'Fix Camera',
        'Fix Battery',
        'Fix Notification',
      ]) {
        await tester.ensureVisible(find.bySemanticsLabel(label));
        await tester.pumpAndSettle();
        await tester.tap(find.bySemanticsLabel(label));
        await tester.pumpAndSettle();
      }
      expect(fixes, [
        StartPreflightFix.appSettings,
        StartPreflightFix.retryCamera,
        StartPreflightFix.batteryExemption,
        StartPreflightFix.appSettings,
      ]);
    });

    testWidgets('a failing fix keeps the page usable', (tester) async {
      await openChecklist(
        tester,
        checks: evaluate(locationServicesEnabled: false),
        onResult: (_) {},
        onFix: (_) async => throw StateError('no settings app'),
      );
      await tester.tap(find.bySemanticsLabel('Fix GPS'));
      await tester.pumpAndSettle();
      expect(find.text('Blocked. Fix GPS to start.'), findsOneWidget);
    });
  });

  testWidgets('the old sheet call still works in a bottom sheet', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    bool? result;
    final checks = evaluate(ignoresBatteryOptimization: false);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await showModalBottomSheet<bool>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => StartPreflightSheet(
                      checks: checks,
                      hasBlockingIssue: false,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Fix'), findsNothing);
    await tapStart(tester);
    expect(result, isTrue);
  });
}
