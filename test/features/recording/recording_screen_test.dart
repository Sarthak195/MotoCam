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
import 'package:motocam/features/camera/providers/camera_provider.dart';
import 'package:motocam/features/recording/recording_screen.dart';
import 'package:motocam/features/telemetry/providers/telemetry_provider.dart';

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
  Future<bool> startRecording() async {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CameraPlatform originalPlatform;
  late CameraController controller;
  // Permission method calls, and whether they hang (to hold a START flow at
  // its first step).
  final permissionCalls = <String>[];
  var holdPermissions = false;

  setUp(() {
    permissionCalls.clear();
    holdPermissions = false;
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
            return {'batteryLevelPercent': 80};
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
  }) async {
    final settings = AppSettingsProvider();
    await tester.runAsync(settings.load);
    final camera = _FakeCameraProvider(controller, recording: recording);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettingsProvider>.value(value: settings),
          ChangeNotifierProvider<CameraProvider>.value(value: camera),
          ChangeNotifierProvider(create: (_) => TelemetryProvider()),
        ],
        child: const MaterialApp(home: RecordingScreen()),
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
}
