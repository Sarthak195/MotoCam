// The ride capture lock at START (landscape recording): strict for
// landscape, tolerant for portrait, no extra call when already locked.

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/features/camera/providers/camera_provider.dart';

class _LockPlatform extends CameraPlatform {
  bool fail = false;
  final List<DeviceOrientation> locks = [];

  @override
  Future<void> lockCaptureOrientation(
    int cameraId,
    DeviceOrientation orientation,
  ) async {
    if (fail) {
      throw PlatformException(code: 'lockFailed', message: 'refused');
    }
    locks.add(orientation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CameraPlatform original;
  late _LockPlatform platform;
  late CameraController controller;
  late List<String> logs;

  setUp(() {
    original = CameraPlatform.instance;
    platform = _LockPlatform();
    CameraPlatform.instance = platform;
    controller = CameraController(
      const CameraDescription(
        name: '0',
        lensDirection: CameraLensDirection.back,
        sensorOrientation: 90,
      ),
      ResolutionPreset.low,
    );
    logs = [];
  });

  tearDown(() {
    CameraPlatform.instance = original;
  });

  Future<bool> lock(DeviceOrientation orientation) =>
      CameraProvider.lockCaptureForRide(controller, orientation, log: logs.add);

  test('a landscape ride locks the capture before its first segment', () async {
    expect(await lock(DeviceOrientation.landscapeLeft), isTrue);
    expect(platform.locks, [DeviceOrientation.landscapeLeft]);
    expect(
      controller.value.lockedCaptureOrientation,
      DeviceOrientation.landscapeLeft,
    );
  });

  test('a controller already locked to the ride orientation is left '
      'alone', () async {
    await controller.lockCaptureOrientation(DeviceOrientation.landscapeRight);
    platform.locks.clear();
    expect(await lock(DeviceOrientation.landscapeRight), isTrue);
    expect(platform.locks, isEmpty);
  });

  test('a failed landscape lock refuses the ride', () async {
    platform.fail = true;
    expect(await lock(DeviceOrientation.landscapeLeft), isFalse);
    expect(logs.single, contains('landscapeLeft'));
  });

  test('portrait keeps the tolerant path: no retry when the init lock '
      'failed, the ride starts', () async {
    platform.fail = true;
    expect(await lock(DeviceOrientation.portraitUp), isTrue);
    expect(platform.locks, isEmpty);
    expect(logs, isEmpty);
  });

  test('portrait on a controller locked to landscape relocks, and refuses '
      'only if that fails', () async {
    await controller.lockCaptureOrientation(DeviceOrientation.landscapeLeft);
    expect(await lock(DeviceOrientation.portraitUp), isTrue);
    expect(platform.locks.last, DeviceOrientation.portraitUp);

    await controller.lockCaptureOrientation(DeviceOrientation.landscapeLeft);
    platform.fail = true;
    expect(await lock(DeviceOrientation.portraitUp), isFalse);
  });

  test('the provider starts with portrait for the ride and idle capture', () {
    final provider = CameraProvider();
    expect(provider.rideCaptureOrientation, DeviceOrientation.portraitUp);
    expect(provider.idleCaptureOrientation, DeviceOrientation.portraitUp);
    provider.dispose();
  });

  test('the idle lock is ignored for portraitDown and remembered for the '
      'next initialization otherwise', () async {
    final provider = CameraProvider();
    await provider.setIdleCaptureOrientation(DeviceOrientation.portraitDown);
    expect(provider.idleCaptureOrientation, DeviceOrientation.portraitUp);
    await provider.setIdleCaptureOrientation(DeviceOrientation.landscapeLeft);
    expect(provider.idleCaptureOrientation, DeviceOrientation.landscapeLeft);
    // No controller yet: nothing to lock.
    expect(platform.locks, isEmpty);
    provider.dispose();
  });
}
