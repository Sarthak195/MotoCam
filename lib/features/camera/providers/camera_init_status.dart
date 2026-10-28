import 'package:permission_handler/permission_handler.dart';

import '../../../core/services/app_permission_service.dart';

/// Phase of the camera initialization, as exposed by `CameraProvider`.
enum CameraInitState {
  /// No initialization has run, or the camera was released while idle.
  idle,

  /// An initialization is in progress.
  initializing,

  /// The camera is initialized and ready to preview and record.
  ready,

  /// The last initialization failed; see [CameraInitFailure].
  failed,
}

/// Why the last camera initialization failed.
enum CameraInitFailureReason {
  /// Camera permission was denied (it can be asked for again).
  cameraPermissionDenied,

  /// Camera permission is blocked; only the system settings can grant it.
  cameraPermissionPermanentlyDenied,

  /// Microphone permission was denied while audio recording is on.
  microphonePermissionDenied,

  /// Microphone permission is blocked while audio recording is on.
  microphonePermissionPermanentlyDenied,

  /// Camera and microphone are granted but another required permission
  /// (location) is missing, so setup stopped before the camera was opened.
  locationPermissionDenied,

  /// The device reported no cameras.
  noCamera,

  /// No resolution preset could be opened: the camera is in use by another
  /// app or otherwise unavailable.
  cameraUnavailable,

  /// The recordings directory could not be created or resolved.
  storageUnavailable,

  /// Any other error; [CameraInitFailure.detail] holds its text.
  unknown,
}

/// The reason for a failed camera initialization.
class CameraInitFailure {
  /// Creates a failure; [detail] is the underlying error text, if any.
  const CameraInitFailure(this.reason, {this.detail});

  /// What went wrong.
  final CameraInitFailureReason reason;

  /// Error text for [CameraInitFailureReason.unknown], otherwise `null`.
  final String? detail;

  /// Whether only the system settings screen can fix this.
  bool get needsSystemSettings =>
      reason == CameraInitFailureReason.cameraPermissionPermanentlyDenied ||
      reason == CameraInitFailureReason.microphonePermissionPermanentlyDenied;

  @override
  bool operator ==(Object other) =>
      other is CameraInitFailure &&
      other.reason == reason &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(reason, detail);

  @override
  String toString() => 'CameraInitFailure($reason, $detail)';
}

/// Maps the camera and microphone permission statuses to the failure that
/// blocks initialization, or `null` when both are usable.
///
/// The microphone only counts when [audioEnabled] is true. The camera is
/// checked first, so a missing camera permission is reported even when the
/// microphone is missing too.
CameraInitFailure? cameraInitFailureForPermissions({
  required PermissionStatus camera,
  required PermissionStatus microphone,
  required bool audioEnabled,
}) {
  if (!AppPermissionService.isPermissionGranted(camera)) {
    return CameraInitFailure(
      camera.isPermanentlyDenied
          ? CameraInitFailureReason.cameraPermissionPermanentlyDenied
          : CameraInitFailureReason.cameraPermissionDenied,
    );
  }
  if (audioEnabled && !AppPermissionService.isPermissionGranted(microphone)) {
    return CameraInitFailure(
      microphone.isPermanentlyDenied
          ? CameraInitFailureReason.microphonePermissionPermanentlyDenied
          : CameraInitFailureReason.microphonePermissionDenied,
    );
  }
  return null;
}

/// Maps the code of a `CameraException` thrown while opening the camera to
/// the permission failure it names, or `null` for any other code.
///
/// Covers the plugin's `CameraAccessDenied`, `AudioAccessDenied` and their
/// `*WithoutPrompt` and `*Restricted` variants. The latter two cannot be asked
/// for again, so they map to the permanently denied reasons. This catches a
/// permission revoked between the status check and the controller opening.
CameraInitFailure? cameraInitFailureForCameraExceptionCode(String code) {
  switch (code) {
    case 'CameraAccessDenied':
      return const CameraInitFailure(
        CameraInitFailureReason.cameraPermissionDenied,
      );
    case 'CameraAccessDeniedWithoutPrompt':
    case 'CameraAccessRestricted':
      return const CameraInitFailure(
        CameraInitFailureReason.cameraPermissionPermanentlyDenied,
      );
    case 'AudioAccessDenied':
      return const CameraInitFailure(
        CameraInitFailureReason.microphonePermissionDenied,
      );
    case 'AudioAccessDeniedWithoutPrompt':
    case 'AudioAccessRestricted':
      return const CameraInitFailure(
        CameraInitFailureReason.microphonePermissionPermanentlyDenied,
      );
  }
  return null;
}
