// Landscape recording engine on the recording screen: the switch off
// changes nothing; on, gravity pins the UI and the idle capture, and the
// landscape bench layout fits a landscape phone.

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
import 'package:motocam/features/camera/providers/camera_provider.dart';
import 'package:motocam/features/recording/recording_screen.dart';
import 'package:motocam/features/telemetry/providers/telemetry_provider.dart';

const _mockedChannels = [
  MethodChannel('flutter.baseflow.com/permissions/methods'),
  MethodChannel('com.example.motocam/background_recording'),
  MethodChannel('com.example.motocam/device_status'),
  MethodChannel('com.example.motocam/pip'),
];

class _PreviewPlatform extends CameraPlatform {
  @override
  Widget buildPreview(int cameraId) =>
      const SizedBox(key: ValueKey('fake-camera-texture'));
}

/// An idle camera with an initialized controller; records idle locks.
class _IdleCameraProvider extends CameraProvider {
  _IdleCameraProvider(this._fakeController);

  final CameraController _fakeController;
  final List<DeviceOrientation> idleLocks = [];

  @override
  bool get isInitialized => true;

  @override
  CameraController? get controller => _fakeController;

  @override
  Future<void> setIdleCaptureOrientation(DeviceOrientation orientation) async {
    idleLocks.add(orientation);
  }

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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CameraPlatform originalPlatform;
  late CameraController controller;
  late StreamController<AccelerometerEvent> gravity;
  late List<Duration> gravityOpened;
  late List<List<String>> uiPins;
  late DateTime sensorClock;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'recording_resolution_p': 720,
      'recording_fps': 30,
      'video_bitrate_mbps': 4,
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in _mockedChannels) {
      messenger.setMockMethodCallHandler(channel, (call) async {
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
            return {'batteryLevelPercent': 80};
        }
        return null;
      });
    }
    uiPins = [];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        uiPins.add((call.arguments as List).cast<String>());
      }
      return null;
    });

    originalPlatform = CameraPlatform.instance;
    CameraPlatform.instance = _PreviewPlatform();
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
    );
    gravity = StreamController<AccelerometerEvent>.broadcast();
    gravityOpened = [];
    sensorClock = DateTime(2026, 11, 19, 8);
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

  Future<_IdleCameraProvider> pumpScreen(
    WidgetTester tester, {
    required bool landscapeRecording,
  }) async {
    final settings = AppSettingsProvider();
    await tester.runAsync(settings.load);
    final camera = _IdleCameraProvider(controller);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettingsProvider>.value(value: settings),
          ChangeNotifierProvider<CameraProvider>.value(value: camera),
          ChangeNotifierProvider(
            create: (_) => TelemetryProvider(
              idleGravitySource: (period) {
                gravityOpened.add(period);
                return gravity.stream;
              },
            ),
          ),
        ],
        child: MaterialApp(
          home: RecordingScreen(landscapeRecording: landscapeRecording),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    return camera;
  }

  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  }

  /// The phone held right edge up (landscapeLeft) for [length].
  Future<void> holdLandscapeLeft(WidgetTester tester, Duration length) async {
    final end = sensorClock.add(length);
    while (sensorClock.isBefore(end)) {
      gravity.add(AccelerometerEvent(9.81, 0.0, 0.0, sensorClock));
      sensorClock = sensorClock.add(const Duration(milliseconds: 66));
    }
    await tester.pump();
    await tester.pump();
  }

  testWidgets('switch off: no sensor, no pin, portrait layout', (tester) async {
    final camera = await pumpScreen(tester, landscapeRecording: false);
    expect(gravityOpened, isEmpty);
    expect(gravity.hasListener, isFalse);
    await holdLandscapeLeft(tester, const Duration(seconds: 2));
    expect(uiPins, isEmpty);
    expect(camera.idleLocks, isEmpty);
    expect(find.text('HISTORY'), findsOneWidget);
    expect(find.text('LANDSCAPE BENCH LAYOUT'), findsNothing);
    await disposeTree(tester);
  });

  testWidgets('switch on: gravity pins the UI and the idle capture, and the '
      'bench layout fits a landscape phone', (tester) async {
    final camera = await pumpScreen(tester, landscapeRecording: true);
    expect(gravityOpened, [SensorInterval.uiInterval]);
    expect(find.text('HISTORY'), findsOneWidget);

    await holdLandscapeLeft(tester, const Duration(milliseconds: 600));
    expect(uiPins, isEmpty, reason: 'not held for 1 s yet');

    await holdLandscapeLeft(tester, const Duration(seconds: 2));
    expect(uiPins, [
      ['DeviceOrientation.landscapeLeft'],
    ]);
    expect(camera.idleLocks, [DeviceOrientation.landscapeLeft]);

    // The phone's window turns (800 x 360 dp, a landscape phone).
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 360);
    addTearDown(tester.view.reset);
    await tester.pump();

    expect(find.text('LANDSCAPE BENCH LAYOUT'), findsOneWidget);
    expect(find.text('START RECORDING'), findsOneWidget);
    expect(find.text('LOCK'), findsOneWidget);
    expect(find.text('HISTORY'), findsNothing);
    expect(find.byKey(const ValueKey('fake-camera-texture')), findsOneWidget);
    // The preview takes the landscape ratio on this path.
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
  });
}
