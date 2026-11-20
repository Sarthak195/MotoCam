// The ride capture lock at START (landscape recording): strict for
// landscape, tolerant for portrait, no extra call when already locked.

import 'dart:io';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/diagnostics/diagnostic_log.dart';
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

  test('a ride refused at START writes the lock failure to the diagnostic '
      'log', () async {
    final temp = await Directory.systemTemp.createTemp('motocam_lock_');
    addTearDown(() => temp.delete(recursive: true));
    final previous = DiagnosticLog.instance;
    final log = DiagnosticLog(resolveDirectory: () async => temp);
    DiagnosticLog.instance = log;
    addTearDown(() => DiagnosticLog.instance = previous);
    final provider = CameraProvider();
    addTearDown(provider.dispose);

    // The ride orientation is portrait; a landscape-locked controller must
    // relock, and that relock fails.
    await controller.lockCaptureOrientation(DeviceOrientation.landscapeLeft);
    platform.fail = true;
    expect(await provider.lockRideCapture(controller), isFalse);
    await log.flush();
    final file = File(
      '${temp.path}${Platform.pathSeparator}${DiagnosticLog.directoryName}'
      '${Platform.pathSeparator}${DiagnosticLog.fileName}',
    );
    final text = await file.exists() ? await file.readAsString() : '';
    expect(text, contains('ERROR [camera] Capture orientation lock to '));
    expect(text, contains('refused'));
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
