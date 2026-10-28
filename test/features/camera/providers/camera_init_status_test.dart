import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/features/camera/providers/camera_init_status.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  group('cameraInitFailureForPermissions', () {
    CameraInitFailureReason? reasonFor({
      PermissionStatus camera = PermissionStatus.granted,
      PermissionStatus microphone = PermissionStatus.granted,
      bool audioEnabled = true,
    }) {
      return cameraInitFailureForPermissions(
        camera: camera,
        microphone: microphone,
        audioEnabled: audioEnabled,
      )?.reason;
    }

    test('returns null when everything needed is granted', () {
      expect(reasonFor(), isNull);
    });

    test('treats limited access as granted', () {
      expect(
        reasonFor(
          camera: PermissionStatus.limited,
          microphone: PermissionStatus.limited,
        ),
        isNull,
      );
    });

    test('maps a denied camera', () {
      expect(
        reasonFor(camera: PermissionStatus.denied),
        CameraInitFailureReason.cameraPermissionDenied,
      );
    });

    test('maps a permanently denied camera', () {
      final failure = cameraInitFailureForPermissions(
        camera: PermissionStatus.permanentlyDenied,
        microphone: PermissionStatus.granted,
        audioEnabled: true,
      );
      expect(
        failure?.reason,
        CameraInitFailureReason.cameraPermissionPermanentlyDenied,
      );
      expect(failure?.needsSystemSettings, isTrue);
    });

    test('maps a denied and a permanently denied microphone', () {
      expect(
        reasonFor(microphone: PermissionStatus.denied),
        CameraInitFailureReason.microphonePermissionDenied,
      );
      expect(
        reasonFor(microphone: PermissionStatus.permanentlyDenied),
        CameraInitFailureReason.microphonePermissionPermanentlyDenied,
      );
    });

    test('ignores the microphone while audio is off', () {
      expect(
        reasonFor(microphone: PermissionStatus.denied, audioEnabled: false),
        isNull,
      );
    });

    test('reports the camera first when both are missing', () {
      expect(
        reasonFor(
          camera: PermissionStatus.denied,
          microphone: PermissionStatus.denied,
        ),
        CameraInitFailureReason.cameraPermissionDenied,
      );
    });
  });

  group('CameraInitFailure', () {
    test('compares by reason and detail', () {
      expect(
        const CameraInitFailure(CameraInitFailureReason.unknown, detail: 'x'),
        const CameraInitFailure(CameraInitFailureReason.unknown, detail: 'x'),
      );
      expect(
        const CameraInitFailure(CameraInitFailureReason.unknown, detail: 'x'),
        isNot(
          const CameraInitFailure(CameraInitFailureReason.unknown, detail: 'y'),
        ),
      );
    });

    test('only permanent denials need the system settings', () {
      expect(
        const CameraInitFailure(
          CameraInitFailureReason.cameraPermissionDenied,
        ).needsSystemSettings,
        isFalse,
      );
      expect(
        const CameraInitFailure(
          CameraInitFailureReason.microphonePermissionPermanentlyDenied,
        ).needsSystemSettings,
        isTrue,
      );
    });
  });
}
