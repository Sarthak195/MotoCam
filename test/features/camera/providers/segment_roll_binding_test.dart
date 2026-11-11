import 'package:camera_android_camerax/camera_android_camerax.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/features/camera/providers/segment_roll_binding.dart';

class _OtherCameraPlatform extends CameraPlatform {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sets the CameraX keep-bound flag for the next stop', () {
    final camera = AndroidCameraCameraX();
    expect(camera.keepVideoCaptureBoundOnNextStop, isFalse);

    expect(keepVideoStreamBoundForNextStop(camera), isTrue);

    expect(camera.keepVideoCaptureBoundOnNextStop, isTrue);
  });

  test('does nothing when the camera plugin is not the CameraX one', () {
    expect(keepVideoStreamBoundForNextStop(_OtherCameraPlatform()), isFalse);
  });

  test('clearKeepVideoStreamBound withdraws the request', () {
    final camera = AndroidCameraCameraX();
    keepVideoStreamBoundForNextStop(camera);

    clearKeepVideoStreamBound(camera);

    expect(camera.keepVideoCaptureBoundOnNextStop, isFalse);
  });

  test('freshVideoStreamForRetry is safe without a bound camera', () async {
    // No camera created yet: the plugin hook returns without touching CameraX.
    await freshVideoStreamForRetry(AndroidCameraCameraX());
    await freshVideoStreamForRetry(_OtherCameraPlatform());
  });
}
