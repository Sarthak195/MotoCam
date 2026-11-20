// The landscape recording screen of redesign A (boards A-Land-Record-Ready
// and A-Land-Record-Live): with the landscape switch on and the UI pinned
// to landscape by gravity, the screen is a Row of the rail, the middle
// column and the thumb column. It fits 844 x 390 and 800 x 360 at text
// scale 1 and 1.3 in every state, keeps the harness labels and the tap
// targets, reaches Blackout and Picture-in-Picture, and keeps one preview
// element across START and parking. A portrait window, or the UI pinned
// to portrait, keeps the portrait layout.

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motocam/core/providers/app_settings_provider.dart';
import 'package:motocam/core/theme/app_theme.dart';
import 'package:motocam/core/ui/big_numeral.dart';
import 'package:motocam/features/camera/providers/camera_provider.dart';
import 'package:motocam/features/recording/recording_screen.dart';
import 'package:motocam/features/recording/widgets/recording_landscape.dart';
import 'package:motocam/features/telemetry/models/telemetry_data.dart';
import 'package:motocam/features/telemetry/providers/telemetry_provider.dart';

import '../../support/load_fonts.dart';

const _pipChannel = MethodChannel('com.example.motocam/pip');

const _mockedChannels = [
  MethodChannel('flutter.baseflow.com/permissions/methods'),
  MethodChannel('com.example.motocam/background_recording'),
  MethodChannel('com.example.motocam/device_status'),
  _pipChannel,
];

class _FakeCameraPlatform extends CameraPlatform {
  @override
  Future<void> pausePreview(int cameraId) async {}

  @override
  Future<void> resumePreview(int cameraId) async {}

  @override
  Widget buildPreview(int cameraId) =>
      const SizedBox(key: ValueKey('fake-camera-texture'));
}

/// A camera with an initialized controller whose recording state the test
/// sets, and which records the calls the controls make.
class _FakeCameraProvider extends CameraProvider {
  _FakeCameraProvider(this._fakeController);

  final CameraController _fakeController;
  bool recording = false;
  bool segmentLocked = false;
  int? freeBytes;
  int stopCalls = 0;
  final List<String> incidents = [];
  final Completer<String?> _stopResult = Completer<String?>();

  @override
  bool get isRecording => recording;

  @override
  bool get isRecordingSegmentLocked => segmentLocked;

  @override
  bool get isInitialized => true;

  @override
  CameraController? get controller => _fakeController;

  @override
  Future<int?> availableStorageBytes() async => freeBytes;

  @override
  Future<void> setIdleCaptureOrientation(DeviceOrientation orientation) async {}

  @override
  Future<void> initializeCamera({
    ResolutionPreset? resolutionPreset,
    int? recordingFps,
    int? videoBitrateBps,
    bool? audioEnabled,
    String? preferredCameraName,
    int? segmentDurationSeconds,
    int? maxRollingSegments,
  }) async {}

  @override
  Future<String?> stopRecording() {
    stopCalls++;
    return _stopResult.future;
  }

  @override
  void markIncident({
    int protectPastSegments = 2,
    bool protectCurrentSegment = true,
    String reason = 'manual',
  }) {
    incidents.add(reason);
  }
}

/// Telemetry that keeps the injected idle gravity source (no tracking
/// streams) and whose speed the test sets.
class _FakeTelemetryProvider extends TelemetryProvider {
  _FakeTelemetryProvider({required super.idleGravitySource});

  double _speed = 0;

  void setSpeed(double kmh) {
    _speed = kmh;
    notifyListeners();
  }

  @override
  Future<void> initialize() async {}

  @override
  TelemetryData get currentData => TelemetryData(
    latitude: 0,
    longitude: 0,
    speed: _speed,
    bearing: 0,
    accelerationG: 0,
    elapsedMs: 0,
    distanceKm: 0,
    timestamp: DateTime(2026, 11, 20),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CameraPlatform originalPlatform;
  late CameraController controller;
  late StreamController<AccelerometerEvent> gravity;
  late DateTime sensorClock;
  late List<String> pipCalls;
  late Map<String, Object?> deviceStatus;
  late _FakeTelemetryProvider telemetry;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'recording_resolution_p': 720,
      'recording_fps': 30,
      'video_bitrate_mbps': 4,
    });
    pipCalls = [];
    deviceStatus = {'batteryLevelPercent': 80};
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in _mockedChannels) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (channel == _pipChannel) {
          pipCalls.add(call.method);
        }
        switch (call.method) {
          case 'checkPermissionStatus':
            return 1;
          case 'requestPermissions':
            return {
              for (final value in (call.arguments as List).cast<int>())
                value: 1,
            };
          case 'isIgnoringBatteryOptimizations':
            return true;
          case 'getBatteryStatus':
            return deviceStatus;
          case 'enterPipMode':
            return false;
        }
        return null;
      });
    }
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );

    originalPlatform = CameraPlatform.instance;
    CameraPlatform.instance = _FakeCameraPlatform();
    controller = CameraController(
      const CameraDescription(
        name: '0',
        lensDirection: CameraLensDirection.back,
        sensorOrientation: 90,
      ),
      ResolutionPreset.low,
    );
    controller.value = controller.value.copyWith(
      isInitialized: true,
      previewSize: const Size(1280, 720),
      isPreviewPaused: false,
    );
    gravity = StreamController<AccelerometerEvent>.broadcast();
    sensorClock = DateTime(2026, 11, 20, 8);
  });

  tearDown(() async {
    CameraPlatform.instance = originalPlatform;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in _mockedChannels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    await gravity.close();
  });

  /// The phone held right edge up (landscapeLeft) long enough for the
  /// classifier to pin it.
  Future<void> holdLandscape(WidgetTester tester) async {
    final end = sensorClock.add(const Duration(seconds: 2));
    while (sensorClock.isBefore(end)) {
      gravity.add(AccelerometerEvent(9.81, 0.0, 0.0, sensorClock));
      sensorClock = sensorClock.add(const Duration(milliseconds: 66));
    }
    await tester.pump();
    await tester.pump();
  }

  /// Pumps the screen with the landscape switch on in a [size] window. With
  /// [pinLandscape] the phone is first held sideways until the UI pins to
  /// landscape; [recording] then starts (as the provider reports it).
  Future<_FakeCameraProvider> pumpScreen(
    WidgetTester tester, {
    Size size = const Size(844, 390),
    double textScale = 1,
    bool pinLandscape = true,
    bool recording = false,
    bool segmentLocked = false,
    int? freeBytes,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = AppSettingsProvider();
    await tester.runAsync(settings.load);
    final camera = _FakeCameraProvider(controller)
      ..freeBytes = freeBytes
      ..segmentLocked = segmentLocked;
    telemetry = _FakeTelemetryProvider(
      idleGravitySource: (_) => gravity.stream,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettingsProvider>.value(value: settings),
          ChangeNotifierProvider<CameraProvider>.value(value: camera),
          ChangeNotifierProvider<TelemetryProvider>(create: (_) => telemetry),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: MediaQuery.withClampedTextScaling(
            minScaleFactor: textScale,
            maxScaleFactor: textScale,
            child: const RecordingScreen(landscapeRecording: true),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (pinLandscape) {
      await holdLandscape(tester);
    }
    if (recording) {
      camera
        ..recording = true
        ..notifyListeners();
    }
    await tester.pump(const Duration(seconds: 1));
    return camera;
  }

  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  }

  final rail = find.byType(RecordingLandscapeRail);
  final thumbColumn = find.byType(RecordingLandscapeThumbColumn);
  final preview = find.byKey(const ValueKey('fake-camera-texture'));
  final blackoutOverlay = find.byWidgetPredicate(
    (widget) =>
        widget is Semantics &&
        widget.properties.label == 'Blackout mode. Recording continues.',
  );

  testWidgets('Ready: the rail has Rides and Settings, the thumb column the '
      'READY band above START, at the board sizes, with the harness labels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.runAsync(loadBundledFonts);
    await pumpScreen(tester);

    expect(rail, findsOneWidget);
    expect(thumbColumn, findsOneWidget);
    expect(find.text('READY'), findsOneWidget);
    expect(find.text('START'), findsOneWidget);
    expect(find.text('Rides'), findsOneWidget);
    expect(find.text('Live view'), findsOneWidget);
    expect(find.bySemanticsLabel('START RECORDING'), findsOneWidget);
    expect(find.bySemanticsLabel('HISTORY'), findsOneWidget);
    expect(find.bySemanticsLabel('Settings'), findsOneWidget);
    // Idle Dark and Pop-out do not exist; neither do STOP and LOCK.
    expect(find.bySemanticsLabel('Enter blackout'), findsNothing);
    expect(find.byTooltip('Enter blackout'), findsNothing);
    expect(find.bySemanticsLabel('Pop-out'), findsNothing);
    expect(find.text('STOP'), findsNothing);
    expect(find.bySemanticsLabel('LOCK'), findsNothing);
    // The parked details panel is there.
    expect(find.text('Battery'), findsOneWidget);
    expect(preview, findsOneWidget);

    // The boards' 64 dp rail and 260 dp thumb column; START fills the
    // column under the band.
    expect(tester.getSize(rail).width, 64);
    expect(tester.getSize(thumbColumn).width, 260);
    final start = tester.getSize(find.bySemanticsLabel('START RECORDING'));
    expect(start.width, 260);
    expect(start.height, greaterThan(250));
    // The live view fills the middle, in the landscape ratio.
    final ratio = tester.widget<AspectRatio>(
      find
          .ancestor(
            of: find.byType(CameraPreview),
            matching: find.byType(AspectRatio),
          )
          .first,
    );
    expect(ratio.aspectRatio, greaterThan(1));
    expect(tester.takeException(), isNull);

    await disposeTree(tester);
    semantics.dispose();
  });

  testWidgets('Live: the REC band, single-tap STOP above the big LOCK, the '
      'speed beside the thumbnail, Dark and Pop-out in the rail; flagged '
      'slots stay out', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.runAsync(loadBundledFonts);
    final camera = await pumpScreen(tester, recording: true);
    telemetry.setSpeed(62);
    await tester.pump();

    expect(rail, findsOneWidget);
    expect(find.text('REC'), findsOneWidget);
    expect(find.text('STOP'), findsOneWidget);
    expect(find.text('LOCK'), findsOneWidget);
    expect(find.text('62'), findsOneWidget);
    expect(find.bySemanticsLabel('STOP RECORDING'), findsOneWidget);
    expect(find.bySemanticsLabel('LOCK'), findsOneWidget);
    // One node per harness label: the rail carries Dark and Pop-out, so
    // the chip row and the details panel do not.
    expect(find.bySemanticsLabel('Enter blackout'), findsOneWidget);
    expect(find.byTooltip('Enter blackout'), findsOneWidget);
    expect(find.bySemanticsLabel('Pop-out'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('Pop-out'), findsOneWidget);
    // Rides is idle only; Settings is in the parked panel only.
    expect(find.text('Rides'), findsNothing);
    expect(find.bySemanticsLabel('HISTORY'), findsNothing);
    expect(find.bySemanticsLabel('Settings'), findsNothing);
    // kHoldToStop, kShowWriteAge, kShowStalled, kLockUndo, kLockTone and
    // kOrientationChip are all off.
    expect(find.textContaining('hold'), findsNothing);
    expect(find.textContaining('Writing'), findsNothing);
    expect(find.text('NOT WRITING'), findsNothing);
    expect(find.text('Undo'), findsNothing);
    expect(find.textContaining('Taken at START'), findsNothing);
    expect(find.textContaining('Locked for this ride'), findsNothing);

    // STOP at the board's 72 dp, LOCK filling the rest of the column.
    final stop = tester.getSize(find.bySemanticsLabel('STOP RECORDING'));
    expect(stop.height, 72);
    final lock = tester.getSize(find.bySemanticsLabel('LOCK'));
    expect(lock.width, 260);
    expect(lock.height, greaterThan(250));
    // The board's 196 x 110 thumbnail at the middle's top right, and a
    // speed readable at a glance.
    expect(tester.getSize(preview.first), isNot(Size.zero));
    expect(
      tester.getSize(find.byType(BigNumeral)).height,
      greaterThanOrEqualTo(120),
    );

    // STOP and LOCK run the same flows as in portrait.
    await tester.tap(find.bySemanticsLabel('LOCK'));
    await tester.pump();
    expect(camera.incidents, ['manual-emergency']);
    await tester.tap(find.bySemanticsLabel('STOP RECORDING'));
    await tester.pump();
    expect(camera.stopCalls, 1);

    await disposeTree(tester);
    semantics.dispose();
  });

  testWidgets('a locked clip turns LOCK into LOCKED, still labelled LOCK, '
      'and a tap locks again', (tester) async {
    final semantics = tester.ensureSemantics();
    final camera = await pumpScreen(
      tester,
      recording: true,
      segmentLocked: true,
    );
    telemetry.setSpeed(62);
    await tester.pump();

    expect(find.text('LOCKED'), findsOneWidget);
    expect(find.bySemanticsLabel('LOCK'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('LOCK'));
    await tester.pump();
    expect(camera.incidents, hasLength(1));
    expect(tester.takeException(), isNull);

    await disposeTree(tester);
    semantics.dispose();
  });

  testWidgets('Blackout is reachable from the rail while recording and '
      'hides the preview', (tester) async {
    await pumpScreen(tester, recording: true);
    expect(preview, findsOneWidget);

    await tester.tap(find.byTooltip('Enter blackout'));
    await tester.pump();

    expect(blackoutOverlay, findsOneWidget);
    expect(preview, findsNothing);

    await disposeTree(tester);
  });

  testWidgets('Pop-out in the rail asks for Picture-in-Picture while '
      'recording', (tester) async {
    await pumpScreen(tester, recording: true);
    pipCalls.clear();

    await tester.tap(find.text('Pop-out'));
    await tester.pump();

    expect(pipCalls, contains('enterPipMode'));

    await disposeTree(tester);
  });

  testWidgets('the details panel shows while parked and leaves when riding, '
      'and START and parking keep the same preview element', (tester) async {
    final semantics = tester.ensureSemantics();
    final camera = await pumpScreen(tester);

    expect(find.text('80%'), findsOneWidget);
    final idlePreview = tester.element(preview);

    camera
      ..recording = true
      ..notifyListeners();
    await tester.pump();
    expect(tester.element(preview), same(idlePreview));
    // Parked: the panel with Settings (it applies to the next START).
    expect(find.text('80%'), findsOneWidget);
    expect(find.bySemanticsLabel('Settings'), findsOneWidget);

    telemetry.setSpeed(40);
    await tester.pump();
    expect(find.text('80%'), findsNothing);
    expect(find.bySemanticsLabel('Settings'), findsNothing);
    expect(find.text('40'), findsOneWidget);
    expect(tester.element(preview), same(idlePreview));

    telemetry.setSpeed(2);
    await tester.pump();
    expect(find.text('80%'), findsOneWidget);
    expect(tester.element(preview), same(idlePreview));
    expect(tester.takeException(), isNull);

    await disposeTree(tester);
    semantics.dispose();
  });

  // Every state at both landscape sizes and both text scales, with the
  // hot chip, low storage and the warnings in the panel.
  for (final size in const [Size(844, 390), Size(800, 360)]) {
    for (final textScale in const [1.0, 1.3]) {
      for (final state in const [
        'ready',
        'riding',
        'parked',
        'riding locked',
        'parked locked',
      ]) {
        testWidgets(
          'no overflow at ${size.width.toInt()}x${size.height.toInt()}, '
          'text x$textScale, $state',
          (tester) async {
            await tester.runAsync(loadBundledFonts);
            deviceStatus = {
              'batteryLevelPercent': 80,
              'batteryTemperatureC': 44.0,
              'thermalStatus': 'severe',
            };
            await pumpScreen(
              tester,
              size: size,
              textScale: textScale,
              recording: state != 'ready',
              segmentLocked: state.endsWith('locked'),
              freeBytes: 300000000,
            );
            if (state.startsWith('riding')) {
              telemetry.setSpeed(62);
            }
            await tester.pump();
            expect(rail, findsOneWidget);
            expect(tester.takeException(), isNull);

            await disposeTree(tester);
          },
        );
      }
    }
  }

  // A portrait window keeps the portrait layout whatever the pin: the
  // window turns a frame after the pin, and the switch on with the phone
  // upright is the portrait screen.
  for (final pinLandscape in const [false, true]) {
    for (final textScale in const [1.0, 1.3]) {
      testWidgets('390x844, text x$textScale, UI pinned '
          '${pinLandscape ? 'landscape' : 'portrait'}: the portrait layout '
          'without overflow', (tester) async {
        await tester.runAsync(loadBundledFonts);
        await pumpScreen(
          tester,
          size: const Size(390, 844),
          textScale: textScale,
          pinLandscape: pinLandscape,
        );
        expect(rail, findsNothing);
        expect(thumbColumn, findsNothing);
        expect(find.bySemanticsLabel('START RECORDING'), findsOneWidget);
        expect(find.bySemanticsLabel('HISTORY'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await disposeTree(tester);
      });
    }
  }

  testWidgets('844x390 with the UI still pinned to portrait keeps the '
      'portrait layout', (tester) async {
    await pumpScreen(tester, pinLandscape: false);
    expect(rail, findsNothing);
    expect(find.bySemanticsLabel('START RECORDING'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await disposeTree(tester);
  });

  for (final recording in const [false, true]) {
    testWidgets('tap targets meet the Android guideline at 844x390 '
        '(${recording ? 'recording' : 'ready'})', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.runAsync(loadBundledFonts);
      await pumpScreen(tester, recording: recording);

      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));

      await disposeTree(tester);
      semantics.dispose();
    });
  }
}
