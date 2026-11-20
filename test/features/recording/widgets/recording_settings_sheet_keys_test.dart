import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motocam/core/providers/app_settings_provider.dart';
import 'package:motocam/core/theme/app_theme.dart';
import 'package:motocam/features/camera/providers/camera_provider.dart';
import 'package:motocam/features/recording/widgets/recording_settings_sheet.dart';

import '../../../support/load_fonts.dart';

// Regression tests for the two red error screens seen on a OnePlus 9 debug
// build of feat/landscape-engine (2026-11-20): framework.dart 6268
// '_dependents.isEmpty' (whole screen) and 2168 '_elements.contains(element)'
// (the old settings sheet's scroll area).
//
// Seed there: the sheet's dropdowns were siblings in one Column, each keyed
// by its bare value, so fps 24 (High Detail) and the 24 segment loop buffer
// both had ValueKey(24). On the Settings page each keyed dropdown sits alone
// in its own _DropdownRow, and the other numeric fields are SegmentedRows
// without value keys, so the same choices must not raise any framework error
// here, in portrait or landscape, through a rotation and on closing.

const _portrait = Size(390, 844);
const _landscape = Size(844, 390);

Future<void> _openSettings(
  WidgetTester tester, {
  Map<String, Object> prefs = const <String, Object>{},
  Size size = _portrait,
  bool bottomSheet = false,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final settings = AppSettingsProvider();
  await settings.load();
  final camera = CameraProvider();
  addTearDown(camera.dispose);
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppSettingsProvider>.value(value: settings),
        ChangeNotifierProvider<CameraProvider>.value(value: camera),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  if (bottomSheet) {
                    unawaited(
                      showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        builder: (_) => const RecordingSettingsSheet(
                          initialFpsOptions: <int>[24, 30, 60],
                          initialCameraOptions: [],
                          initialUnsupportedPresets: {},
                        ),
                      ),
                    );
                  } else {
                    unawaited(
                      showRecordingSettingsPage(
                        context,
                        initialFpsOptions: const <int>[24, 30, 60],
                        initialCameraOptions: const [],
                        initialUnsupportedPresets: const {},
                      ),
                    );
                  }
                },
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
  expect(find.text('Settings'), findsOneWidget);
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      120,
      scrollable: find.byType(Scrollable).last,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _pickHighDetail(WidgetTester tester) async {
  await _tapVisible(tester, find.text('Advanced'));
  await _tapVisible(tester, find.text('Balanced'));
  await tester.tap(find.text('High Detail').last);
  await tester.pumpAndSettle();
}

Future<void> _rotate(WidgetTester tester, Size from) async {
  tester.view.physicalSize = Size(from.height, from.width);
  await tester.pumpAndSettle();
  tester.view.physicalSize = from;
  await tester.pumpAndSettle();
}

Future<void> _popAll(WidgetTester tester) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  navigator.popUntil((route) => route.isFirst);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadBundledFonts);

  for (final size in const [_portrait, _landscape]) {
    final name = size == _portrait ? 'portrait' : 'landscape';

    testWidgets('$name: High Detail (24 fps) beside the 24 segment loop '
        'buffer, rotate, then close, raises no framework error', (
      tester,
    ) async {
      await _openSettings(tester, size: size);
      await _pickHighDetail(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('24 fps'), findsOneWidget);

      await _rotate(tester, size);
      expect(tester.takeException(), isNull);

      await _popAll(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Settings'), findsNothing);
    });

    testWidgets('$name: the old bottom sheet, High Detail, rotate and close '
        'raise no framework error', (tester) async {
      await _openSettings(tester, size: size, bottomSheet: true);
      await _pickHighDetail(tester);
      await _rotate(tester, size);
      expect(tester.takeException(), isNull);

      await _popAll(tester);
      expect(tester.takeException(), isNull);
    });
  }

  // Every pair of fields that can hold the same number.
  final collidingPrefs = <String, Map<String, Object>>{
    'bitrate 12 and loop buffer 12': {
      'flutter.video_bitrate_mbps': 12,
      'flutter.dashcam_loop_segment_count': 12,
    },
    'bitrate 8 and storage budget 8': {
      'flutter.video_bitrate_mbps': 8,
      'flutter.recordings_storage_budget_gb': 8,
    },
    'fps 30 and clip length 30 s': {
      'flutter.recording_fps': 30,
      'flutter.dashcam_segment_duration_seconds': 30,
    },
    'speed refresh 300 ms and clip length 300 s': {
      'flutter.speed_refresh_ms': 300,
      'flutter.dashcam_segment_duration_seconds': 300,
    },
  };
  for (final entry in collidingPrefs.entries) {
    testWidgets('saved settings with ${entry.key}: every sub-page, rotate '
        'and close without a framework error', (tester) async {
      await _openSettings(tester, prefs: entry.value);
      for (final page in const ['Advanced', 'Storage', 'Safety']) {
        await _tapVisible(tester, find.text(page));
        await _rotate(tester, _portrait);
        expect(tester.takeException(), isNull);
        await tester.tap(find.bySemanticsLabel('Back'));
        await tester.pumpAndSettle();
      }
      await _popAll(tester);
      expect(tester.takeException(), isNull);
    });
  }
}
