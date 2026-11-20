// Landscape recording engine on the recording screen: the switch off
// changes nothing; on, gravity pins the UI and the idle capture, and the
// landscape recording layout fits a landscape phone; a ride keeps the pin
// frozen from the START tap to the end of STOP.

import 'dart:async';
import 'dart:io';

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
import 'package:motocam/features/recording/widgets/recording_landscape.dart';
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

/// A camera that records a ride without a real camera: START and STOP each
/// wait on a gate, so the test can feed gravity while they are pending.
class _RideCameraProvider extends _IdleCameraProvider {
  _RideCameraProvider(super.controller, this.recordingsDir);

  final String recordingsDir;
  final List<DeviceOrientation> startOrientations = [];
  final Completer<void> startGate = Completer<void>();
  final Completer<void> stopGate = Completer<void>();
  bool _recording = false;
  bool _starting = false;
  bool _stopping = false;
  bool _hasSegment = false;
  DeviceOrientation _rideOrientation = DeviceOrientation.portraitUp;

  static const _segmentPath = 'ride_segment_0001.mp4';

  @override
  bool get isRecording => _recording;

  @override
  bool get isStartingRecording => _starting;

  @override
  bool get isStoppingRecording => _stopping;

  @override
  DeviceOrientation get rideCaptureOrientation => _rideOrientation;

  @override
  String? get recordingsDirectory => recordingsDir;

  @override
  DateTime? get recordingStartedAt => DateTime(2026, 11, 19, 8);

  @override
  Stream<Duration> get timerStream => const Stream<Duration>.empty();

  @override
  List<String> get lastSessionSegmentPaths =>
      _hasSegment ? const [_segmentPath] : const [];

  @override
  List<String> get lockedSegmentPaths => const [];

  @override
  List<Map<String, dynamic>> get lastSessionSegmentTimeline => const [];

  @override
  Future<bool> startRecording({
    DeviceOrientation captureOrientation = DeviceOrientation.portraitUp,
  }) async {
    startOrientations.add(captureOrientation);
    _starting = true;
    notifyListeners();
    await startGate.future;
    _rideOrientation = captureOrientation;
    _starting = false;
    _recording = true;
    _hasSegment = true;
    notifyListeners();
    return true;
  }

  @override
  Future<String?> stopRecording() async {
    _stopping = true;
    notifyListeners();
    await stopGate.future;
    _recording = false;
    _stopping = false;
    notifyListeners();
    return _segmentPath;
  }
}

/// Telemetry that keeps the injected idle gravity source (no tracking
/// streams) and saves the ride in memory; the save waits on a gate.
class _RideTelemetryProvider extends TelemetryProvider {
  _RideTelemetryProvider({required super.idleGravitySource});

  final Completer<void> persistGate = Completer<void>();
  Map<String, dynamic>? savedSettings;
  bool _rideActive = false;

  @override
  Future<void> initialize() async {}

  @override
  bool get isRideActive => _rideActive;

  @override
  void startRideSession({DateTime? startedAt}) {
    _rideActive = true;
  }

  @override
  void cancelRideSession() {
    _rideActive = false;
  }

  @override
  Future<String?> stopRideSessionAndPersist(
    String videoPath, {
    List<String>? segmentPaths,
    List<String>? lockedSegmentPaths,
    List<Map<String, dynamic>>? segmentTimeline,
    Map<String, dynamic>? recordingSettings,
  }) async {
    savedSettings = recordingSettings;
    await persistGate.future;
    _rideActive = false;
    return 'ride.json';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CameraPlatform originalPlatform;
  late CameraController controller;
  late StreamController<AccelerometerEvent> gravity;
  late List<Duration> gravityOpened;
  late List<List<String>> uiPins;
  late DateTime sensorClock;
  late Directory recordingsDir;

  setUp(() {
    recordingsDir = Directory.systemTemp.createTempSync('motocam_landscape_');
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
    try {
      recordingsDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Stream<AccelerometerEvent> idleGravity(Duration period) {
    gravityOpened.add(period);
    return gravity.stream;
  }

  Future<T> pumpScreen<T extends _IdleCameraProvider>(
    WidgetTester tester, {
    required bool landscapeRecording,
    T? camera,
    TelemetryProvider? telemetry,
  }) async {
    final settings = AppSettingsProvider();
    await tester.runAsync(settings.load);
    final screenCamera = camera ?? _IdleCameraProvider(controller) as T;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettingsProvider>.value(value: settings),
          ChangeNotifierProvider<CameraProvider>.value(value: screenCamera),
          ChangeNotifierProvider<TelemetryProvider>(
            create: (_) =>
                telemetry ?? TelemetryProvider(idleGravitySource: idleGravity),
          ),
        ],
        child: MaterialApp(
          home: RecordingScreen(landscapeRecording: landscapeRecording),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    return screenCamera;
  }

  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  }

  /// The phone held with gravity at ([x], [y]) in its own frame for
  /// [length], sampled at about 15 Hz.
  Future<void> hold(
    WidgetTester tester,
    double x,
    double y,
    Duration length,
  ) async {
    final end = sensorClock.add(length);
    while (sensorClock.isBefore(end)) {
      gravity.add(AccelerometerEvent(x, y, 0.0, sensorClock));
      sensorClock = sensorClock.add(const Duration(milliseconds: 66));
    }
    await tester.pump();
    await tester.pump();
  }

  /// The phone held right edge up (landscapeLeft) for [length].
  Future<void> holdLandscapeLeft(WidgetTester tester, Duration length) =>
      hold(tester, 9.81, 0.0, length);

  /// The phone held left edge up (landscapeRight) for [length].
  Future<void> holdLandscapeRight(WidgetTester tester, Duration length) =>
      hold(tester, -9.81, 0.0, length);

  /// Lets real I/O (the START preflight's storage probe) and fake time run
  /// until [done] holds.
  Future<void> settleUntil(
    WidgetTester tester,
    bool Function() done,
    String what,
  ) async {
    for (var i = 0; i < 400 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(done(), isTrue, reason: 'never reached: $what');
  }

  testWidgets('switch off: no sensor, no pin, portrait layout', (tester) async {
    final camera = await pumpScreen(tester, landscapeRecording: false);
    expect(gravityOpened, isEmpty);
    expect(gravity.hasListener, isFalse);
    await holdLandscapeLeft(tester, const Duration(seconds: 2));
    expect(uiPins, isEmpty);
    expect(camera.idleLocks, isEmpty);
    expect(find.bySemanticsLabel('HISTORY'), findsOneWidget);
    expect(find.byType(RecordingLandscapeRail), findsNothing);
    await disposeTree(tester);
  });

  testWidgets('switch on: gravity pins the UI and the idle capture, and the '
      'landscape layout fits a landscape phone', (tester) async {
    final camera = await pumpScreen(tester, landscapeRecording: true);
    expect(gravityOpened, [SensorInterval.uiInterval]);
    expect(find.bySemanticsLabel('HISTORY'), findsOneWidget);

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

    expect(find.byType(RecordingLandscapeRail), findsOneWidget);
    expect(find.byType(RecordingLandscapeThumbColumn), findsOneWidget);
    expect(find.bySemanticsLabel('START RECORDING'), findsOneWidget);
    // Ride History is reachable in landscape too, from the rail.
    expect(find.bySemanticsLabel('HISTORY'), findsOneWidget);
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

  testWidgets('switch on: the pin stays frozen from the START tap to the '
      'end of STOP, the ride keeps its orientation, and the classifier '
      'resumes after STOP', (tester) async {
    // START checks that location services are on (the fake telemetry does
    // not start tracking, so nothing else reaches the geolocator).
    const geolocator = MethodChannel('flutter.baseflow.com/geolocator');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      geolocator,
      (call) async => call.method == 'isLocationServiceEnabled' ? true : null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(geolocator, null));
    final telemetry = _RideTelemetryProvider(idleGravitySource: idleGravity);
    final camera = await pumpScreen(
      tester,
      landscapeRecording: true,
      camera: _RideCameraProvider(controller, recordingsDir.path),
      telemetry: telemetry,
    );
    expect(gravityOpened, [SensorInterval.uiInterval]);

    await holdLandscapeLeft(tester, const Duration(seconds: 2));
    const pinnedLeft = [
      ['DeviceOrientation.landscapeLeft'],
    ];
    expect(uiPins, pinnedLeft);
    expect(camera.idleLocks, [DeviceOrientation.landscapeLeft]);

    // Nothing moves while frozen: no new UI pin, no idle capture lock, and
    // the pinner does not even listen to gravity.
    Future<void> expectFrozen(String window) async {
      await holdLandscapeRight(tester, const Duration(seconds: 2));
      await hold(tester, 0.0, 9.81, const Duration(seconds: 2));
      expect(uiPins, pinnedLeft, reason: window);
      expect(camera.idleLocks, [
        DeviceOrientation.landscapeLeft,
      ], reason: window);
      expect(gravity.hasListener, isFalse, reason: window);
      expect(gravityOpened, hasLength(1), reason: window);
    }

    // START tapped: frozen before the flow reaches its first await.
    await tester.tap(find.bySemanticsLabel('START RECORDING'));
    await tester.pump();
    await expectFrozen('START tapped, preflight running');

    // The camera's start is pending.
    await settleUntil(
      tester,
      () => camera.startOrientations.isNotEmpty,
      'camera start',
    );
    expect(camera.startOrientations, [DeviceOrientation.landscapeLeft]);
    await expectFrozen('camera start pending');

    // Recording.
    camera.startGate.complete();
    await settleUntil(
      tester,
      () => find.bySemanticsLabel('STOP RECORDING').evaluate().isNotEmpty,
      'recording',
    );
    expect(camera.isRecording, isTrue);
    await expectFrozen('recording');
    expect(camera.rideCaptureOrientation, DeviceOrientation.landscapeLeft);

    // STOP tapped; then the camera's stop is pending.
    await tester.tap(find.bySemanticsLabel('STOP RECORDING'));
    await tester.pump();
    await expectFrozen('STOP tapped');
    await settleUntil(tester, () => camera.isStoppingRecording, 'camera stop');
    await expectFrozen('camera stop pending');

    // The camera stopped; the ride is still being saved.
    camera.stopGate.complete();
    await settleUntil(
      tester,
      () => telemetry.savedSettings != null,
      'ride save',
    );
    expect(camera.isRecording, isFalse);
    expect(camera.isStoppingRecording, isFalse);
    await expectFrozen('ride save pending');
    expect(
      telemetry.savedSettings!['appliedCaptureOrientation'],
      'landscapeLeft',
    );

    // STOP done: the classifier resumes, and only a held new orientation
    // pins again.
    telemetry.persistGate.complete();
    await settleUntil(
      tester,
      () => find.bySemanticsLabel('START RECORDING').evaluate().isNotEmpty,
      'stop done',
    );
    await tester.pump();
    expect(gravity.hasListener, isTrue);
    expect(gravityOpened, hasLength(2));
    expect(uiPins, pinnedLeft);

    await holdLandscapeRight(tester, const Duration(milliseconds: 600));
    expect(uiPins, pinnedLeft, reason: 'not held for 1 s yet');

    await holdLandscapeRight(tester, const Duration(seconds: 2));
    expect(uiPins, [
      ['DeviceOrientation.landscapeLeft'],
      ['DeviceOrientation.landscapeRight'],
    ]);
    expect(camera.idleLocks, [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    expect(camera.startOrientations, [DeviceOrientation.landscapeLeft]);
    expect(camera.rideCaptureOrientation, DeviceOrientation.landscapeLeft);
    expect(tester.takeException(), isNull);
    await disposeTree(tester);
  });
}
