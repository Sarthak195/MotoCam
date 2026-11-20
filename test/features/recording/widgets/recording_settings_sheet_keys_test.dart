import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motocam/core/providers/app_settings_provider.dart';
import 'package:motocam/features/camera/providers/camera_provider.dart';
import 'package:motocam/features/recording/widgets/recording_settings_sheet.dart';

// Regression tests for the two red error screens seen on a OnePlus 9 debug
// build (2026-11-20): framework.dart 6268 '_dependents.isEmpty' (whole screen)
// and 2168 '_elements.contains(element)' (the settings sheet's scroll area).
//
// Seed: the sheet's dropdowns are siblings in one Column, each keyed by its
// value. With bare ValueKey<int> keys, picking the High Detail group
// (2160p, 24 fps) put ValueKey(24) on the FPS field next to the default 24
// segment loop buffer. The duplicate key error was caught at the Scrollable's
// RawGestureDetector, which left part of the old subtree active. The next
// rebuild of the sheet (here a rotation) then failed with 2168, and closing
// the sheet failed with 6268 at the Overlay.

const _portrait = Size(1080, 2400);
const _landscape = Size(2400, 1080);

Future<void> _openSheet(
  WidgetTester tester, {
  Map<String, Object> prefs = const <String, Object>{},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final settings = AppSettingsProvider();
  await settings.load();
  final camera = CameraProvider();
  addTearDown(camera.dispose);

  tester.view.physicalSize = _portrait;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppSettingsProvider>.value(value: settings),
        ChangeNotifierProvider<CameraProvider>.value(value: camera),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const RecordingSettingsSheet(
                    initialFpsOptions: <int>[24, 30, 60],
                    initialCameraOptions: [],
                    initialUnsupportedPresets: {},
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  expect(find.text('Recording Settings'), findsOneWidget);
}

Future<void> _pickHighDetail(WidgetTester tester) async {
  await tester.tap(find.text('Balanced'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('High Detail').last);
  await tester.pumpAndSettle();
}

Future<void> _rotate(WidgetTester tester) async {
  tester.view.physicalSize = _landscape;
  await tester.pumpAndSettle();
  tester.view.physicalSize = _portrait;
  await tester.pumpAndSettle();
}

Future<void> _closeSheet(WidgetTester tester) async {
  tester.state<NavigatorState>(find.byType(Navigator)).pop();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'High Detail (24 fps) beside the default 24 segment loop buffer, then '
    'closing the sheet, raises no framework error',
    (tester) async {
      await _openSheet(tester);
      await _pickHighDetail(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('24 FPS'), findsOneWidget);
      expect(find.text('24 segments'), findsOneWidget);

      await _closeSheet(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Recording Settings'), findsNothing);
    },
  );

  testWidgets(
    'High Detail (24 fps) beside the 24 segment loop buffer, then rotating '
    'and closing, raises no framework error',
    (tester) async {
      await _openSheet(tester);
      await _pickHighDetail(tester);
      await _rotate(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Recording Settings'), findsOneWidget);
      expect(find.text('24 FPS'), findsOneWidget);

      await _closeSheet(tester);
      expect(tester.takeException(), isNull);
    },
  );

  // Every pair of sibling dropdowns that can hold the same number.
  final collidingPrefs = <String, Map<String, Object>>{
    'bitrate 12 and loop buffer 12': {
      'flutter.video_bitrate_mbps': 12,
      'flutter.dashcam_loop_segment_count': 12,
    },
    'bitrate 8 and storage budget 8': {
      'flutter.video_bitrate_mbps': 8,
      'flutter.recordings_storage_budget_gb': 8,
    },
    'bitrate 16 and storage budget 16': {
      'flutter.video_bitrate_mbps': 16,
      'flutter.recordings_storage_budget_gb': 16,
    },
    'fps 30 and segment length 30 s': {
      'flutter.recording_fps': 30,
      'flutter.dashcam_segment_duration_seconds': 30,
    },
    'fps 60 and segment length 60 s': {
      'flutter.recording_fps': 60,
      'flutter.dashcam_segment_duration_seconds': 60,
    },
    'speed refresh 300 ms and segment length 300 s': {
      'flutter.speed_refresh_ms': 300,
      'flutter.dashcam_segment_duration_seconds': 300,
    },
  };
  for (final entry in collidingPrefs.entries) {
    testWidgets(
      'saved settings with ${entry.key} open, rotate and close without a '
      'framework error',
      (tester) async {
        await _openSheet(tester, prefs: entry.value);
        await _rotate(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Recording Settings'), findsOneWidget);

        await _closeSheet(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'picking 300 ms speed refresh beside the default 300 s segment length '
    'raises no framework error',
    (tester) async {
      await _openSheet(tester);
      final refresh = find.text('100 ms');
      await tester.scrollUntilVisible(
        refresh,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      await tester.tap(find.text('300 ms').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await _rotate(tester);
      await _closeSheet(tester);
      expect(tester.takeException(), isNull);
    },
  );
}
