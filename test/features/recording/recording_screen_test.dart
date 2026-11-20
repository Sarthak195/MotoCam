// Characterisation tests of the recording screen: they pin what the START,
// STOP, LOCK and Blackout controls do and what the Picture-in-Picture view
// shows, by the accessibility labels the phone harness reads, so the
// redesign can replace the widgets without changing the behaviour.

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motocam/core/providers/app_settings_provider.dart';
import 'package:motocam/core/theme/app_theme.dart';
import 'package:motocam/core/ui/big_numeral.dart';
import 'package:motocam/features/camera/providers/camera_provider.dart';
import 'package:motocam/features/recording/recording_screen.dart';
import 'package:motocam/features/recording/widgets/recording_settings_page.dart';
import 'package:motocam/features/recording/widgets/start_preflight_sheet.dart';
import 'package:motocam/features/telemetry/models/telemetry_data.dart';
import 'package:motocam/features/telemetry/providers/telemetry_provider.dart';

import '../../support/load_fonts.dart';

const _permissionChannel = MethodChannel(
  'flutter.baseflow.com/permissions/methods',
);
const _pipChannel = MethodChannel('com.example.motocam/pip');

const _mockedChannels = [
  _permissionChannel,
  MethodChannel('com.example.motocam/background_recording'),
  MethodChannel('com.example.motocam/device_status'),
  _pipChannel,
  // Telemetry start-up asks for location services once the camera is up.
  MethodChannel('flutter.baseflow.com/geolocator'),
  MethodChannel('flutter.baseflow.com/geolocator_service_updates'),
  MethodChannel('flutter.baseflow.com/geolocator_updates'),
  // The motion sensors incident detection listens to.
  MethodChannel('dev.fluttercommunity.plus/sensors/method'),
  MethodChannel('dev.fluttercommunity.plus/sensors/accelerometer'),
  MethodChannel('dev.fluttercommunity.plus/sensors/user_accel'),
  MethodChannel('dev.fluttercommunity.plus/sensors/gyroscope'),
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

/// A camera provider with an initialized controller whose recording state
/// the test sets, and which records the calls the controls make.
class _FakeCameraProvider extends CameraProvider {
  _FakeCameraProvider(this._fakeController, {this.recording = false});

  final CameraController _fakeController;
  bool recording;
  bool starting = false;
  bool stopping = false;
  bool segmentLocked = false;
  int startCalls = 0;
  int stopCalls = 0;
  final List<({int past, bool current, String reason})> incidents = [];

  // Never completes, so a stop stays in progress until the tree goes away.
  final Completer<String?> _stopResult = Completer<String?>();

  @override
  bool get isRecording => recording;

  @override
  bool get isStartingRecording => starting;

  @override
  bool get isStoppingRecording => stopping;

  @override
  bool get isRecordingSegmentLocked => segmentLocked;

  @override
  bool get isInitialized => true;

  /// What the storage poll reads.
  int? freeBytes;

  @override
  Future<int?> availableStorageBytes() async => freeBytes;

  @override
  CameraController? get controller => _fakeController;

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
  Future<bool> startRecording({
    DeviceOrientation captureOrientation = DeviceOrientation.portraitUp,
  }) async {
    startCalls++;
    return false;
  }

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
    incidents.add((
      past: protectPastSegments,
      current: protectCurrentSegment,
      reason: reason,
    ));
  }
}

/// A telemetry provider whose speed the test sets.
class _FakeTelemetryProvider extends TelemetryProvider {
  double _speed = 0;

  void setSpeed(double kmh) {
    _speed = kmh;
    notifyListeners();
  }

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
  // Permission method calls, and whether they hang (to hold a START flow at
  // its first step).
  final permissionCalls = <String>[];
  var holdPermissions = false;
  // What the 15 s device status poll returns.
  var deviceStatus = <String, Object?>{'batteryLevelPercent': 80};
  late _FakeTelemetryProvider telemetry;

  setUp(() {
    permissionCalls.clear();
    holdPermissions = false;
    deviceStatus = {'batteryLevelPercent': 80};
    SharedPreferences.setMockInitialValues({
      'recording_resolution_p': 720,
      'recording_fps': 30,
      'video_bitrate_mbps': 4,
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in _mockedChannels) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (channel == _permissionChannel) {
          permissionCalls.add(call.method);
          if (holdPermissions) {
            return Completer<Object?>().future;
          }
        }
        switch (call.method) {
          case 'checkPermissionStatus':
            return 1; // granted
          case 'requestPermissions':
            return {
              for (final value in (call.arguments as List).cast<int>())
                value: 1,
            };
          case 'isIgnoringBatteryOptimizations':
            return true;
          case 'getBatteryStatus':
            return deviceStatus;
          case 'isLocationServiceEnabled':
            return true;
          case 'checkPermission':
            return 3; // whileInUse
        }
        return null;
      });
    }

    originalPlatform = CameraPlatform.instance;
    CameraPlatform.instance = _FakeCameraPlatform();

    const description = CameraDescription(
      name: '0',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
    );
    controller = CameraController(description, ResolutionPreset.low);
    controller.value = controller.value.copyWith(
      isInitialized: true,
      previewSize: const Size(1280, 720),
      isPreviewPaused: false,
    );
  });

  tearDown(() {
    CameraPlatform.instance = originalPlatform;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in _mockedChannels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  Future<_FakeCameraProvider> pumpScreen(
    WidgetTester tester, {
    bool recording = false,
    Size size = const Size(390, 844),
    double textScale = 1,
    int? freeBytes,
    bool segmentLocked = false,
  }) async {
    // A phone screen in portrait, at device pixel ratio 1.
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = AppSettingsProvider();
    await tester.runAsync(settings.load);
    final camera = _FakeCameraProvider(controller, recording: recording)
      ..freeBytes = freeBytes
      ..segmentLocked = segmentLocked;
    telemetry = _FakeTelemetryProvider();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettingsProvider>.value(value: settings),
          ChangeNotifierProvider<CameraProvider>.value(value: camera),
          // Created here so the provider disposes it (and its timers).
          ChangeNotifierProvider<TelemetryProvider>(create: (_) => telemetry),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: MediaQuery.withClampedTextScaling(
            minScaleFactor: textScale,
            maxScaleFactor: textScale,
            // The portrait screen these characterisation tests were
            // written for, whatever the build's MOTOCAM_LANDSCAPE value
            // (on by default); the landscape screen has its own tests.
            child: const RecordingScreen(landscapeRecording: false),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    return camera;
  }

  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  }

  final blackoutOverlay = find.byWidgetPredicate(
    (widget) =>
        widget is Semantics &&
        widget.properties.label == 'Blackout mode. Recording continues.',
  );
  final preview = find.byKey(const ValueKey('fake-camera-texture'));

  // The harness reads a control's accessibility text, which comes from a
  // tooltip or a semantics label.
  Finder harnessLabel(String text) => find.byWidgetPredicate(
    (widget) =>
        (widget is Tooltip && widget.message == text) ||
        (widget is Semantics && widget.properties.label == text),
  );

  testWidgets('START runs the start flow (its permission check first) and '
      'marks the control busy while it runs', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpScreen(tester);

    expect(find.bySemanticsLabel('START RECORDING'), findsOneWidget);
    expect(find.bySemanticsLabel('STOP RECORDING'), findsNothing);

    holdPermissions = true;
    permissionCalls.clear();
    await tester.tap(find.bySemanticsLabel('START RECORDING'));
    await tester.pump();

    expect(permissionCalls, isNotEmpty);
    expect(find.bySemanticsLabel('START RECORDING'), findsNothing);
    expect(find.bySemanticsLabel('STARTING...'), findsOneWidget);

    await disposeTree(tester);
    semantics.dispose();
  });

  testWidgets('STOP runs the stop flow while recording', (tester) async {
    final semantics = tester.ensureSemantics();
    final camera = await pumpScreen(tester, recording: true);

    expect(find.bySemanticsLabel('STOP RECORDING'), findsOneWidget);
    expect(find.bySemanticsLabel('START RECORDING'), findsNothing);

    await tester.tap(find.bySemanticsLabel('STOP RECORDING'));
    await tester.pump();

    expect(camera.stopCalls, 1);
    expect(find.bySemanticsLabel('SAVING RECORDING...'), findsOneWidget);

    // A second press while the stop runs does nothing.
    await tester.tap(
      find.bySemanticsLabel('SAVING RECORDING...'),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(camera.stopCalls, 1);

    await disposeTree(tester);
    semantics.dispose();
  });

  testWidgets('STOP is ignored while the camera is stopping', (tester) async {
    final semantics = tester.ensureSemantics();
    final camera = await pumpScreen(tester, recording: true);
    camera
      ..stopping = true
      ..notifyListeners();
    await tester.pump();

    expect(find.bySemanticsLabel('STOP RECORDING'), findsNothing);
    await tester.tap(
      find.bySemanticsLabel('SAVING RECORDING...'),
      warnIfMissed: false,
    );
    await tester.pump();

    expect(camera.stopCalls, 0);
    expect(camera.startCalls, 0);

    await disposeTree(tester);
    semantics.dispose();
  });

  testWidgets('STOP is ignored while the camera is starting', (tester) async {
    final semantics = tester.ensureSemantics();
    final camera = await pumpScreen(tester, recording: true);
    camera
      ..starting = true
      ..notifyListeners();
    await tester.pump();

    expect(find.bySemanticsLabel('STOP RECORDING'), findsNothing);
    await tester.tap(find.bySemanticsLabel('STARTING...'), warnIfMissed: false);
    await tester.pump();

    expect(camera.stopCalls, 0);
    expect(camera.startCalls, 0);

    await disposeTree(tester);
    semantics.dispose();
  });

  testWidgets('LOCK protects the two previous clips and the current one and '
      'says so', (tester) async {
    final semantics = tester.ensureSemantics();
    final camera = await pumpScreen(tester, recording: true);

    await tester.tap(find.bySemanticsLabel('LOCK'));
    await tester.pump();

    expect(camera.incidents, [
      (past: 2, current: true, reason: 'manual-emergency'),
    ]);
    expect(find.text('Locked: current clip'), findsOneWidget);

    await disposeTree(tester);
    semantics.dispose();
  });

  testWidgets('LOCK does nothing while idle', (tester) async {
    final semantics = tester.ensureSemantics();
    final camera = await pumpScreen(tester);

    final lock = find.bySemanticsLabel('LOCK');
    if (lock.evaluate().isNotEmpty) {
      await tester.tap(lock, warnIfMissed: false);
      await tester.pump();
    }
    expect(camera.incidents, isEmpty);

    await disposeTree(tester);
    semantics.dispose();
  });

  testWidgets('Blackout cannot be entered while idle', (tester) async {
    await pumpScreen(tester);

    final enter = find.byTooltip('Enter blackout');
    if (enter.evaluate().isNotEmpty) {
      await tester.tap(enter, warnIfMissed: false);
      await tester.pump();
    }
    expect(blackoutOverlay, findsNothing);
    expect(preview, findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('Blackout while recording hides the preview', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpScreen(tester, recording: true);
    expect(preview, findsOneWidget);

    await tester.tap(find.byTooltip('Enter blackout'));
    await tester.pump();

    expect(blackoutOverlay, findsOneWidget);
    // The preview is not built under the overlay.
    expect(preview, findsNothing);

    await disposeTree(tester);
    semantics.dispose();
  });

  testWidgets('Settings stays reachable while recording', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpScreen(tester, recording: true);

    expect(harnessLabel('Settings'), findsWidgets);

    await disposeTree(tester);
    semantics.dispose();
  });

  testWidgets('HISTORY is offered while idle', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpScreen(tester);

    expect(find.bySemanticsLabel('HISTORY'), findsOneWidget);
    expect(harnessLabel('Settings'), findsWidgets);

    await disposeTree(tester);
    semantics.dispose();
  });

  testWidgets(
    'Settings pushes the Settings page; system back leaves the settings '
    'as they were',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpScreen(tester);

      final settings = Provider.of<AppSettingsProvider>(
        tester.element(find.byType(RecordingScreen)),
        listen: false,
      );
      final resolutionBefore = settings.recordingResolution;

      await tester.tap(find.bySemanticsLabel('Settings'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byType(RecordingSettingsPage), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.bySemanticsLabel('SAVE SETTINGS'), findsOneWidget);

      // The system back gesture.
      await tester.binding.handlePopRoute();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byType(RecordingSettingsPage), findsNothing);
      expect(settings.recordingResolution, resolutionBefore);
      expect(find.bySemanticsLabel('START RECORDING'), findsOneWidget);

      await disposeTree(tester);
      semantics.dispose();
    },
  );

  testWidgets('START with a blocking check open pushes the checklist page; '
      'Close returns without recording', (tester) async {
    final semantics = tester.ensureSemantics();
    // The fake camera has no recordings folder, so Media Write Access fails
    // and blocks START.
    final camera = await pumpScreen(tester);

    await tester.tap(find.bySemanticsLabel('START RECORDING'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(StartPreflightSheet), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.bySemanticsLabel('Ready To Record?'), findsOneWidget);
    expect(
      find.text('Unable to write to app recording storage'),
      findsOneWidget,
    );

    await tester.tap(find.bySemanticsLabel('Close'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(StartPreflightSheet), findsNothing);
    expect(camera.startCalls, 0);
    expect(find.bySemanticsLabel('START RECORDING'), findsOneWidget);

    await disposeTree(tester);
    semantics.dispose();
  });

  testWidgets('the Picture-in-Picture view shows the recording state and no '
      'controls', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpScreen(tester, recording: true);

    Future<void> reportPip(bool inPip) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        _pipChannel.name,
        _pipChannel.codec.encodeMethodCall(
          MethodCall('onPipModeChanged', inPip),
        ),
        (_) {},
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    await reportPip(true);

    expect(find.text('Return to app for controls'), findsOneWidget);
    expect(find.text('REC'), findsOneWidget);
    expect(find.bySemanticsLabel('STOP RECORDING'), findsNothing);
    expect(find.bySemanticsLabel('LOCK'), findsNothing);
    expect(preview, findsNothing);

    await reportPip(false);
    expect(find.text('Return to app for controls'), findsNothing);
    expect(find.bySemanticsLabel('STOP RECORDING'), findsOneWidget);

    await disposeTree(tester);
    semantics.dispose();
  });

  group('redesign A', () {
    testWidgets('Ready: READY band, Rides, Settings and START with the '
        'harness labels; no Dark, Pop-out or recording controls', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpScreen(tester);

      expect(find.text('READY'), findsOneWidget);
      expect(find.text('START'), findsOneWidget);
      expect(find.text('Rides'), findsOneWidget);
      expect(find.text('Live view'), findsOneWidget);
      expect(find.bySemanticsLabel('START RECORDING'), findsOneWidget);
      expect(find.bySemanticsLabel('HISTORY'), findsOneWidget);
      expect(find.bySemanticsLabel('Settings'), findsOneWidget);
      // Idle Dark and Pop-out do not exist.
      expect(find.byTooltip('Enter blackout'), findsNothing);
      expect(find.bySemanticsLabel('Enter blackout'), findsNothing);
      expect(find.bySemanticsLabel('Pop-out'), findsNothing);
      expect(find.text('STOP'), findsNothing);
      expect(find.bySemanticsLabel('LOCK'), findsNothing);

      await disposeTree(tester);
      semantics.dispose();
    });

    testWidgets('Live: REC band, single-tap STOP, the big LOCK and Blackout; '
        'reserved slots leave nothing behind', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpScreen(tester, recording: true);
      telemetry.setSpeed(62);
      await tester.pump();

      expect(find.text('REC'), findsOneWidget);
      expect(find.text('STOP'), findsOneWidget);
      expect(find.text('LOCK'), findsOneWidget);
      expect(find.text('62'), findsOneWidget);
      expect(find.text('km/h'), findsOneWidget);
      expect(find.bySemanticsLabel('STOP RECORDING'), findsOneWidget);
      expect(find.bySemanticsLabel('LOCK'), findsOneWidget);
      expect(find.bySemanticsLabel('Enter blackout'), findsOneWidget);
      expect(find.byTooltip('Enter blackout'), findsOneWidget);
      // kHoldToStop, kShowWriteAge, kShowStalled, kLockUndo, kLockTone and
      // kOrientationChip are all off.
      expect(find.textContaining('hold'), findsNothing);
      expect(find.textContaining('Writing'), findsNothing);
      expect(find.text('NOT WRITING'), findsNothing);
      expect(find.text('Undo'), findsNothing);
      expect(find.textContaining('Tone'), findsNothing);
      expect(find.textContaining('Taken at START'), findsNothing);
      expect(find.text('Rides'), findsNothing);

      await disposeTree(tester);
      semantics.dispose();
    });

    testWidgets('a locked clip shows the LOCKED band and button, still '
        'labelled LOCK for the harness', (tester) async {
      final semantics = tester.ensureSemantics();
      final camera = await pumpScreen(
        tester,
        recording: true,
        segmentLocked: true,
      );

      expect(find.text('LOCKED'), findsNWidgets(2));
      expect(find.bySemanticsLabel('LOCK'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Locked: the current clips are protected'),
        findsOneWidget,
      );

      // A tap on LOCKED locks again, as a tap on LOCK does.
      await tester.tap(find.bySemanticsLabel('LOCK'));
      await tester.pump();
      expect(camera.incidents, hasLength(1));

      await disposeTree(tester);
      semantics.dispose();
    });

    testWidgets('the details panel shows while parked (battery, distance, '
        'Settings) and leaves when riding, without rebuilding the preview', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final camera = await pumpScreen(tester);
      await tester.pump(const Duration(seconds: 1));

      // Idle: the panel is there and the preview fills the middle.
      expect(find.text('80%'), findsOneWidget);
      expect(find.text('Battery'), findsOneWidget);
      expect(find.text('Distance'), findsOneWidget);
      final idlePreview = tester.element(preview);

      // START: the same preview element becomes the thumbnail.
      camera
        ..recording = true
        ..notifyListeners();
      await tester.pump();
      expect(tester.element(preview), same(idlePreview));
      expect(find.text('80%'), findsOneWidget);
      expect(harnessLabel('Settings'), findsWidgets);
      expect(find.bySemanticsLabel('Pop-out'), findsOneWidget);

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

      await disposeTree(tester);
      semantics.dispose();
    });

    testWidgets('the chips read the polled temperature and storage', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      deviceStatus = {
        'batteryLevelPercent': 80,
        'batteryTemperatureC': 44.0,
        'thermalStatus': 'severe',
      };
      // 18 GB at the 20 Mbps floor (9 GB an hour).
      await pumpScreen(tester, recording: true, freeBytes: 18000000000);
      await tester.pump(const Duration(seconds: 1));

      expect(find.bySemanticsLabel('Phone temperature hot'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          RegExp(r'^Storage: up to 2\.0 hours left at 20 megabits'),
        ),
        findsOneWidget,
      );
      expect(find.text('up to'), findsOneWidget);
      expect(find.textContaining('Phone hot.'), findsOneWidget);

      await disposeTree(tester);
      semantics.dispose();
    });

    testWidgets('storage under an hour warns in the chip and the panel', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpScreen(tester, freeBytes: 3600000000);
      await tester.pump(const Duration(seconds: 1));

      expect(
        find.bySemanticsLabel(RegExp(r'^Storage low: up to 0\.4 hours')),
        findsOneWidget,
      );
      expect(find.textContaining('Storage low.'), findsOneWidget);

      await disposeTree(tester);
      semantics.dispose();
    });

    for (final size in const [Size(390, 844), Size(844, 390)]) {
      for (final textScale in const [1.0, 1.3]) {
        for (final recording in const [false, true]) {
          testWidgets(
            'no overflow at ${size.width.toInt()}x${size.height.toInt()}, '
            'text x$textScale, ${recording ? 'recording' : 'ready'}',
            (tester) async {
              await tester.runAsync(loadBundledFonts);
              deviceStatus = {
                'batteryLevelPercent': 80,
                'batteryTemperatureC': 44.0,
                'thermalStatus': 'severe',
              };
              await pumpScreen(
                tester,
                recording: recording,
                size: size,
                textScale: textScale,
                freeBytes: 300000000,
                segmentLocked: recording,
              );
              await tester.pump(const Duration(seconds: 1));
              expect(tester.takeException(), isNull);

              await disposeTree(tester);
            },
          );
        }
      }
    }

    // Shorter phones than the boards' 844 dp: START and LOCK give up
    // height first, so a locked ride at speed keeps a readable speed.
    for (final size in const [Size(360, 780), Size(360, 730), Size(360, 690)]) {
      testWidgets('a ${size.width.toInt()}x${size.height.toInt()} screen keeps '
          'the speed readable while locked and riding', (tester) async {
        await tester.runAsync(loadBundledFonts);
        await pumpScreen(
          tester,
          recording: true,
          size: size,
          segmentLocked: true,
        );
        telemetry.setSpeed(62);
        await tester.pump();
        expect(tester.takeException(), isNull);

        final speed = find.bySemanticsLabel('Speed 62 kilometres per hour');
        expect(speed, findsOneWidget);
        // About 114 dp at 690 dp high, 178 dp at 780 dp high.
        expect(
          tester.getSize(find.byType(BigNumeral)).height,
          greaterThanOrEqualTo(100),
        );

        await disposeTree(tester);
      });
    }

    for (final recording in const [false, true]) {
      testWidgets('tap targets meet the Android guideline '
          '(${recording ? 'recording' : 'ready'})', (tester) async {
        final semantics = tester.ensureSemantics();
        await tester.runAsync(loadBundledFonts);
        await pumpScreen(tester, recording: recording);
        await tester.pump(const Duration(seconds: 1));

        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));

        await disposeTree(tester);
        semantics.dispose();
      });
    }
  });
}
