import 'package:camera_android_camerax/camera_android_camerax.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';

/// Asks the Android camera plugin to keep its video stream bound across the
/// next stop, so a timed segment roll does not rebuild the camera session.
///
/// The flag lives in MotoCam's vendored camera_android_camerax
/// (third_party/camera_android_camerax/MOTOCAM_PATCHES.md) and covers exactly
/// one stop. Without it every roll unbinds and rebinds CameraX's VideoCapture,
/// which rebuilds the capture session and the video encoder; on the test phone
/// (2026-11-11) a roll lost about 1.5 s of video, about 1 s of it in that
/// rebuild.
///
/// Returns whether the request was made: false where the camera plugin is not
/// the CameraX one (other platforms, tests with a fake platform).
bool keepVideoStreamBoundForNextStop([CameraPlatform? platform]) {
  final target = platform ?? CameraPlatform.instance;
  if (target is AndroidCameraCameraX) {
    target.keepVideoCaptureBoundOnNextStop = true;
    return true;
  }
  return false;
}

/// Withdraws a [keepVideoStreamBoundForNextStop] request. The plugin clears it
/// itself when the stop reaches it; this covers a stop that failed before.
void clearKeepVideoStreamBound([CameraPlatform? platform]) {
  final target = platform ?? CameraPlatform.instance;
  if (target is AndroidCameraCameraX) {
    target.keepVideoCaptureBoundOnNextStop = false;
  }
}

/// Before retrying a failed segment restart: unbinds the idle video stream so
/// the retry starts on a fresh camera session and encoder, as upstream did.
Future<void> freshVideoStreamForRetry([CameraPlatform? platform]) async {
  final target = platform ?? CameraPlatform.instance;
  if (target is AndroidCameraCameraX) {
    await target.unbindIdleVideoCapture();
  }
}
