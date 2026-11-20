// Widget tests for the Settings page (board A-Settings) and its sub-pages:
// the SAVE result keeps its fields and meaning, sub-page choices reach it,
// requested and applied values, hidden reserved rows, and no overflow at
// 390x844 and 844x390.

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motocam/core/providers/app_settings_provider.dart';
import 'package:motocam/core/theme/app_theme.dart';
import 'package:motocam/features/camera/providers/camera_provider.dart';
import 'package:motocam/features/recording/widgets/recording_settings_form.dart';
import 'package:motocam/features/recording/widgets/recording_settings_sheet.dart';

import '../../../support/load_fonts.dart';

class _FakeCamera extends CameraProvider {
  bool initialized = false;
  bool recording = false;
  ResolutionPreset preset = ResolutionPreset.veryHigh;
  int fps = 30;
  int mbps = 8;
  int segmentSeconds = 300;
  bool audio = true;

  @override
  bool get isInitialized => initialized;

  @override
  bool get isRecording => recording;

  @override
  ResolutionPreset get resolutionPreset => preset;

  @override
  int get recordingFps => fps;

  @override
  int get appliedVideoBitrateMbps => mbps;

  @override
  int get segmentDurationSeconds => segmentSeconds;

  @override
  bool get audioEnabled => audio;
}

class _Harness {
  RecordingSettingsFormResult? result;
  bool closed = false;
}

Future<_Harness> _openSettings(
  WidgetTester tester, {
  _FakeCamera? camera,
  List<int> fpsOptions = const [30],
  Set<ResolutionPreset> unsupported = const {},
  bool settingsPending = false,
  Map<String, Object> prefs = const {},
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final settings = AppSettingsProvider();
  await settings.load();
  final cam = camera ?? _FakeCamera();
  addTearDown(cam.dispose);
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final harness = _Harness();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppSettingsProvider>.value(value: settings),
        ChangeNotifierProvider<CameraProvider>.value(value: cam),
      ],
      child: MaterialApp(
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
                  harness.result = await showRecordingSettingsPage(
                    context,
                    initialFpsOptions: fpsOptions,
                    initialCameraOptions: const [],
                    initialUnsupportedPresets: unsupported,
                    settingsPending: settingsPending,
                  );
                  harness.closed = true;
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
  return harness;
}

/// Scrolls the top page's list until [finder] is built and on screen.
Future<void> reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    // Back to the top, then down until it is built.
    await tester.drag(find.byType(Scrollable).last, const Offset(0, 3000));
    await tester.pumpAndSettle();
  }
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      120,
      scrollable: find.byType(Scrollable).last,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await reveal(tester, finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> save(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('SAVE SETTINGS'));
  await tester.pumpAndSettle();
}

Future<void> back(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Back'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadBundledFonts);

  group('SAVE result', () {
    testWidgets('unchanged settings come back as saved', (tester) async {
      final harness = await _openSettings(tester);
      await save(tester);
      final result = harness.result!;
      expect(result.resolution, 1080);
      expect(result.fps, 30);
      expect(result.bitrateMbps, 8);
      expect(result.audioEnabled, isTrue);
      expect(result.speedRefreshMs, 100);
      expect(result.cameraName, '');
      expect(result.segmentDurationSeconds, 300);
      expect(result.loopSegmentCount, 24);
      expect(result.incidentSensitivity, IncidentSensitivity.medium);
      expect(result.exportLockedClipsToGallery, isFalse);
      expect(result.keepScreenOnWhileRecording, isTrue);
      expect(result.recordingsStorageBudgetGb, 0);
    });

    testWidgets('choices on the main page and every sub-page reach SAVE', (
      tester,
    ) async {
      final harness = await _openSettings(tester, fpsOptions: [24, 30]);

      await tapVisible(tester, find.text('720p'));
      await tapVisible(tester, find.text('12 Mbps'));
      await tapVisible(tester, find.text('2 min'));
      await tapVisible(tester, find.text('Record audio'));

      await tapVisible(tester, find.text('Safety'));
      await tapVisible(tester, find.text('High'));
      await tapVisible(tester, find.text('Keep screen on while recording'));
      await back(tester);

      await tapVisible(tester, find.text('Storage'));
      await tapVisible(tester, find.text('16'));
      await tapVisible(tester, find.text('Copy locked clips to gallery'));
      await back(tester);

      await tapVisible(tester, find.text('Advanced'));
      await tapVisible(tester, find.text('24 fps'));
      await tapVisible(tester, find.text('48'));
      await tapVisible(tester, find.text('200 ms'));
      await back(tester);

      expect(find.text('Settings'), findsOneWidget);
      await save(tester);
      final result = harness.result!;
      expect(result.resolution, 720);
      expect(result.fps, 24);
      expect(result.bitrateMbps, 12);
      expect(result.segmentDurationSeconds, 120);
      expect(result.audioEnabled, isFalse);
      expect(result.incidentSensitivity, IncidentSensitivity.high);
      expect(result.keepScreenOnWhileRecording, isFalse);
      expect(result.recordingsStorageBudgetGb, 16);
      expect(result.exportLockedClipsToGallery, isTrue);
      expect(result.loopSegmentCount, 48);
      expect(result.speedRefreshMs, 200);
    });

    testWidgets('Privacy and data shares the audio choice', (tester) async {
      final harness = await _openSettings(tester);
      await tapVisible(tester, find.text('Privacy and data'));
      await tapVisible(tester, find.text('Record audio'));
      await back(tester);
      expect(find.text('Audio off'), findsOneWidget);
      await save(tester);
      expect(harness.result!.audioEnabled, isFalse);
    });

    testWidgets('back without SAVE returns null', (tester) async {
      final harness = await _openSettings(tester);
      await tapVisible(tester, find.text('720p'));
      await back(tester);
      expect(harness.closed, isTrue);
      expect(harness.result, isNull);
    });

    testWidgets('the old sheet still pops the result from a bottom sheet', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final settings = AppSettingsProvider();
      await settings.load();
      final camera = _FakeCamera();
      addTearDown(camera.dispose);
      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      RecordingSettingsFormResult? result;
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
                    onPressed: () async {
                      result =
                          await showModalBottomSheet<
                            RecordingSettingsFormResult
                          >(
                            context: context,
                            isScrollControlled: true,
                            builder: (_) => const RecordingSettingsSheet(
                              initialFpsOptions: [30],
                              initialCameraOptions: [],
                              initialUnsupportedPresets: {},
                            ),
                          );
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
      await tapVisible(tester, find.text('4K'));
      await save(tester);
      expect(result!.resolution, 2160);
    });
  });

  group('main page', () {
    testWidgets('board values on the main page, saved values always shown', (
      tester,
    ) async {
      await _openSettings(
        tester,
        prefs: {'recording_resolution_p': 480, 'video_bitrate_mbps': 4},
      );
      // 480p and 4 Mbps live on Advanced but show while selected; the
      // default 5 min clip shows next to 1, 2 and 3 min.
      for (final label in const [
        '480p',
        '720p',
        '1080p',
        '4K',
        '4 Mbps',
        '8 Mbps',
        '12 Mbps',
        '16 Mbps',
        '1 min',
        '2 min',
        '3 min',
        '5 min',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('20 Mbps'), findsNothing);
      expect(find.text('10 min'), findsNothing);
    });

    testWidgets('meets the Android tap target guideline', (tester) async {
      final handle = tester.ensureSemantics();
      await _openSettings(tester);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('frame rate: fixed when the camera offers one rate', (
      tester,
    ) async {
      await _openSettings(tester);
      expect(find.textContaining('Fixed at 30 fps'), findsOneWidget);
    });

    testWidgets('frame rate: no picker and no 60 fps on the main page', (
      tester,
    ) async {
      await _openSettings(tester, fpsOptions: [24, 30, 60]);
      expect(find.textContaining('Fixed at'), findsNothing);
      expect(find.textContaining('30 fps. More in Advanced'), findsOneWidget);
      expect(find.textContaining('60'), findsNothing);
    });

    testWidgets('reserved Controls and Backup rows are not in the tree', (
      tester,
    ) async {
      await _openSettings(tester);
      expect(find.text('Controls'), findsNothing);
      expect(find.text('Backup'), findsNothing);
      for (final row in const [
        'Advanced',
        'Storage',
        'Safety',
        'Privacy and data',
        'About and licences',
      ]) {
        await reveal(tester, find.text(row));
        expect(find.text(row), findsOneWidget, reason: row);
      }
    });

    testWidgets('a known unsupported resolution is struck and disabled', (
      tester,
    ) async {
      final harness = await _openSettings(
        tester,
        unsupported: {ResolutionPreset.ultraHigh},
      );
      expect(
        find.text('Known unsupported on this device: 4K (2160p)'),
        findsOneWidget,
      );
      await tapVisible(tester, find.text('4K'));
      await save(tester);
      expect(harness.result!.resolution, 1080);
    });

    testWidgets('no applied values before the camera is initialized', (
      tester,
    ) async {
      await _openSettings(tester);
      expect(find.textContaining('Applied'), findsNothing);
      expect(
        find.text('Recording settings apply to the next recording.'),
        findsOneWidget,
      );
    });

    testWidgets('requested and applied side by side', (tester) async {
      final camera = _FakeCamera()
        ..initialized = true
        ..preset = ResolutionPreset.high;
      await _openSettings(tester, camera: camera);
      expect(find.text('Applied 720p. 1080p could not apply'), findsOneWidget);
      expect(find.textContaining('30 fps, applied'), findsOneWidget);
      expect(find.text('Applied 8 Mbps'), findsOneWidget);
      expect(find.text('Applied 5 min'), findsOneWidget);
      expect(find.text('Applied on'), findsOneWidget);

      await tapVisible(tester, find.text('2 min'));
      expect(find.text('Applied 5 min, 2 min when you save'), findsOneWidget);
    });

    testWidgets('while recording, changes are said to apply next time', (
      tester,
    ) async {
      final camera = _FakeCamera()
        ..initialized = true
        ..recording = true;
      await _openSettings(tester, camera: camera);
      expect(
        find.text(
          'A ride is recording. Resolution, frame rate, bitrate, clip '
          'length, lens and audio apply to the next recording.',
        ),
        findsOneWidget,
      );
      await tapVisible(tester, find.text('3 min'));
      expect(
        find.text('Applied 5 min, 3 min from next recording'),
        findsOneWidget,
      );
    });

    testWidgets('settings saved during a ride apply from the next START', (
      tester,
    ) async {
      // Stopped after a mid-ride save: the camera still runs the old values.
      final camera = _FakeCamera()
        ..initialized = true
        ..mbps = 12
        ..segmentSeconds = 120
        ..audio = false;
      await _openSettings(tester, camera: camera, settingsPending: true);
      expect(find.textContaining('could not apply'), findsNothing);
      expect(
        find.text('Applied 2 min, 5 min from next recording'),
        findsOneWidget,
      );
      expect(
        find.text('Applied 12 Mbps, 8 Mbps from next recording'),
        findsOneWidget,
      );
      expect(find.text('Applied off, on from next recording'), findsOneWidget);
    });

    testWidgets('the storage row sums up budget and gallery copies', (
      tester,
    ) async {
      await _openSettings(
        tester,
        prefs: {'recordings_storage_budget_gb': 64, 'video_bitrate_mbps': 16},
      );
      await reveal(tester, find.text('Storage'));
      expect(
        find.text('Budget 64 GB, about 9.5 h at 16 Mbps. Gallery copies off'),
        findsOneWidget,
      );
    });
  });

  group('no overflow', () {
    for (final size in const [Size(390, 844), Size(844, 390)]) {
      for (final textScale in const [1.0, 1.3]) {
        final name =
            '${size.width.toInt()}x${size.height.toInt()} text x$textScale';
        testWidgets('main page and every sub-page at $name', (tester) async {
          final camera = _FakeCamera()
            ..initialized = true
            ..recording = true
            ..preset = ResolutionPreset.high;
          await _openSettings(
            tester,
            camera: camera,
            fpsOptions: [24, 30, 60],
            unsupported: {ResolutionPreset.ultraHigh},
            size: size,
            textScale: textScale,
          );
          expect(tester.takeException(), isNull);
          await reveal(tester, find.text('About and licences'));
          expect(tester.takeException(), isNull);
          for (final page in const [
            'Advanced',
            'Storage',
            'Safety',
            'Privacy and data',
          ]) {
            await tapVisible(tester, find.text(page));
            expect(tester.takeException(), isNull, reason: page);
            final list = find.byType(Scrollable).last;
            await tester.drag(list, const Offset(0, -2000));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: page);
            await back(tester);
          }
        });
      }
    }
  });

  group('helpers', () {
    test('short labels', () {
      expect(shortResolutionLabel(2160), '4K');
      expect(shortResolutionLabel(480), '480p');
      expect(shortClipLengthLabel(30), '30 s');
      expect(shortClipLengthLabel(180), '3 min');
      expect(shortClipLengthLabel(90), '1 min 30 s');
    });

    test('main page options add a less common saved value', () {
      expect(mainPageOptions(const [60, 120, 180], 120), [60, 120, 180]);
      expect(mainPageOptions(const [60, 120, 180], 600), [60, 120, 180, 600]);
      expect(mainPageOptions(const [720, 1080, 2160], 480), [
        480,
        720,
        1080,
        2160,
      ]);
    });

    test('applied status text', () {
      String status(
        String applied,
        String requested,
        String saved,
        bool rec, {
        bool pending = false,
      }) => appliedStatusText(
        applied: applied,
        requested: requested,
        saved: saved,
        recording: rec,
        pending: pending,
      );
      expect(status('2 min', '2 min', '2 min', false), 'Applied 2 min');
      expect(
        status('2 min', '3 min', '2 min', true),
        'Applied 2 min, 3 min from next recording',
      );
      expect(
        status('2 min', '3 min', '3 min', true, pending: true),
        'Applied 2 min, 3 min from next recording',
      );
      expect(
        status('2 min', '3 min', '3 min', false, pending: true),
        'Applied 2 min, 3 min from next recording',
      );
      // Negotiated down at START and nothing pending: START will not fix it.
      expect(
        status('1080p', '4K', '4K', true),
        'Applied 1080p. 4K could not apply',
      );
      expect(
        status('2 min', '3 min', '2 min', false),
        'Applied 2 min, 3 min when you save',
      );
      expect(
        status('720p', '1080p', '1080p', false),
        'Applied 720p. 1080p could not apply',
      );
    });

    test('storage budget hours', () {
      expect(storageBudgetHours(0, 8), 0);
      expect(storageBudgetHours(64, 20).toStringAsFixed(1), '7.6');
    });
  });
}
