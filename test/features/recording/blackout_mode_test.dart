// Blackout mode: a Flutter-only black overlay that never changes the
// camera's bound use cases (pausing the preview unbinds CameraX's Preview,
// which cost video at every toggle and every segment roll on the phone).

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
import 'package:motocam/features/recording/recording_screen_logic.dart';
import 'package:motocam/features/telemetry/providers/telemetry_provider.dart';

const _mockedChannels = [
  MethodChannel('flutter.baseflow.com/permissions/methods'),
  MethodChannel('com.example.motocam/background_recording'),
  MethodChannel('com.example.motocam/device_status'),
  MethodChannel('com.example.motocam/pip'),
];

/// Records the preview calls that would unbind or rebind CameraX's Preview.
class _RecordingCameraPlatform extends CameraPlatform {
  final List<String> previewCalls = [];

  @override
  Future<void> pausePreview(int cameraId) async {
    previewCalls.add('pausePreview');
  }

  @override
  Future<void> resumePreview(int cameraId) async {
    previewCalls.add('resumePreview');
  }

  @override
  Widget buildPreview(int cameraId) =>
      const SizedBox(key: ValueKey('fake-camera-texture'));
}

/// A camera provider that reports a recording in progress with an
/// initialized controller, without touching a real camera.
class _RecordingCameraProvider extends CameraProvider {
  _RecordingCameraProvider(this._fakeController);

  final CameraController _fakeController;

  @override
  bool get isRecording => true;

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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('leavesBlackoutOnLifecycle', () {
    test('inactive (shade, power press start, PiP) and resumed keep '
        'blackout', () {
      expect(leavesBlackoutOnLifecycle(AppLifecycleState.inactive), isFalse);
      expect(leavesBlackoutOnLifecycle(AppLifecycleState.resumed), isFalse);
    });

    test('hidden and paused (screen off, app in the background) end '
        'blackout', () {
      expect(leavesBlackoutOnLifecycle(AppLifecycleState.hidden), isTrue);
      expect(leavesBlackoutOnLifecycle(AppLifecycleState.paused), isTrue);
    });
  });

  late CameraPlatform originalPlatform;
  late _RecordingCameraPlatform platform;
  late CameraController controller;

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
        }
        return null;
      });
    }

    originalPlatform = CameraPlatform.instance;
    platform = _RecordingCameraPlatform();
    CameraPlatform.instance = platform;

    const description = CameraDescription(
      name: '0',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
    );
    controller = CameraController(description, ResolutionPreset.low);
    // Initialized with a live (not paused) preview, so a pausePreview call
    // would reach the platform instead of returning early.
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

  Future<void> pumpRecordingScreen(WidgetTester tester) async {
    final settings = AppSettingsProvider();
    await tester.runAsync(settings.load);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettingsProvider>.value(value: settings),
          ChangeNotifierProvider<CameraProvider>(
            create: (_) => _RecordingCameraProvider(controller),
          ),
          ChangeNotifierProvider(create: (_) => TelemetryProvider()),
        ],
        child: const MaterialApp(home: RecordingScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> disposeTree(WidgetTester tester) async {
    // Releases periodic timers and subscriptions.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  }

  final overlay = find.byWidgetPredicate(
    (widget) =>
        widget is Semantics &&
        widget.properties.label == 'Blackout mode. Recording continues.',
  );
  final preview = find.byKey(const ValueKey('fake-camera-texture'));

  Future<void> holdToExit(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(Scaffold).first),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pump();
  }

  testWidgets('entering and leaving blackout during a recording neither '
      'pauses nor resumes the camera preview', (tester) async {
    await pumpRecordingScreen(tester);
    expect(preview, findsOneWidget);
    expect(overlay, findsNothing);

    await tester.tap(find.byTooltip('Enter blackout'));
    await tester.pump();

    expect(overlay, findsOneWidget);
    expect(find.text('Blackout on. Hold 2s anywhere to exit.'), findsOneWidget);
    // The preview widget is not built under the overlay; the camera keeps
    // its Preview use case bound.
    expect(preview, findsNothing);
    expect(platform.previewCalls, isEmpty);

    await holdToExit(tester);

    expect(overlay, findsNothing);
    expect(find.text('Blackout off'), findsOneWidget);
    // The overlay's gesture is cancelled as it unmounts; that must not
    // replace "Blackout off" with a stale hold hint.
    expect(find.text('Hold for 2 seconds to exit blackout'), findsNothing);
    expect(preview, findsOneWidget);
    expect(platform.previewCalls, isEmpty);
    expect(controller.value.isPreviewPaused, isFalse);

    await disposeTree(tester);
  });

  testWidgets('a short tap on the overlay keeps blackout and says how to '
      'exit', (tester) async {
    await pumpRecordingScreen(tester);
    await tester.tap(find.byTooltip('Enter blackout'));
    await tester.pump();

    await tester.tap(find.byType(Scaffold).first);
    await tester.pump();

    expect(overlay, findsOneWidget);
    expect(find.text('Hold for 2 seconds to exit blackout'), findsOneWidget);
    expect(platform.previewCalls, isEmpty);

    await disposeTree(tester);
  });

  testWidgets('an inactive app (notification shade, start of a power press) '
      'keeps blackout on', (tester) async {
    await pumpRecordingScreen(tester);
    await tester.tap(find.byTooltip('Enter blackout'));
    await tester.pump();
    expect(overlay, findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(overlay, findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(overlay, findsOneWidget);
    expect(platform.previewCalls, isEmpty);

    await disposeTree(tester);
  });
}
