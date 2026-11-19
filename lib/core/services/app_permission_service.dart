import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import 'background_recording_service.dart';
import 'device_status_service.dart';

/// The result of [AppPermissionService.ensureRequiredPermissions].
///
/// Separates missing permissions into [missingRequired] (camera, mic,
/// location) and [missingRecommended] (notifications, legacy storage,
/// battery optimisation). [permanentlyDeniedRequired] lists the required
/// permissions the OS reports as permanently denied, which only the system
/// settings screen can grant.
class PermissionAuditResult {
  /// Creates an audit result. The lists are expected to be unmodifiable.
  const PermissionAuditResult({
    required this.missingRequired,
    required this.missingRecommended,
    this.permanentlyDeniedRequired = const <String>[],
  });

  /// Labels of required permissions that are not granted; recording is
  /// blocked while this is non-empty.
  final List<String> missingRequired;

  /// Labels of recommended permissions or settings that are not granted.
  final List<String> missingRecommended;

  /// Labels of required permissions that are permanently denied (a subset of
  /// [missingRequired]).
  final List<String> permanentlyDeniedRequired;

  /// Whether at least one *required* permission is permanently denied.
  ///
  /// Recommended permissions never set this, so a note derived from it only
  /// refers to the permissions that actually block recording.
  bool get hasPermanentlyDenied => permanentlyDeniedRequired.isNotEmpty;

  /// Whether a required permission is missing.
  bool get hasBlockingIssues => missingRequired.isNotEmpty;

  /// Whether any required or recommended permission is missing.
  bool get hasAnyIssue =>
      missingRequired.isNotEmpty || missingRecommended.isNotEmpty;
}

/// Requests and audits all runtime permissions needed by the app.
///
/// Call [ensureRequiredPermissions] at startup. Missing required permissions
/// block recording; missing recommended ones generate advisory warnings.
///
/// The audit never launches the battery-optimisation exemption request; it
/// only reports whether the app is exempt. See
/// [BackgroundRecordingService.hasOfferedBatteryOptimizationExemption].
class AppPermissionService {
  /// Creates the service. [deviceStatusService] is only replaceable for tests.
  const AppPermissionService({
    DeviceStatusService deviceStatusService = const DeviceStatusService(),
  }) : _deviceStatusService = deviceStatusService;

  final DeviceStatusService _deviceStatusService;

  /// First Android API level (Q) whose MediaStore export needs no storage
  /// permission. Below it the gallery export of locked clips writes the
  /// public Movies directory and needs WRITE_EXTERNAL_STORAGE.
  static const int scopedStorageSdkInt = 29;

  /// The app-wide "permission is usable" predicate: granted, or limited
  /// (partial access).
  static bool isPermissionGranted(PermissionStatus status) {
    return status.isGranted || status.isLimited;
  }

  /// Requests every permission the app needs and reports what is missing.
  ///
  /// The microphone is only required when [audioEnabled] is true. Legacy
  /// storage (Android 9 and lower) is only requested when
  /// [galleryExportEnabled] is true, because only the opt-in gallery copy of
  /// locked clips needs it. Every permission that is not granted is
  /// requested, including ones the plugin reports as permanently denied: the
  /// OS answers immediately without a dialog when a permission really is
  /// blocked, while a permission the user reset to "Ask every time" (which
  /// permission_handler_android 13.x still reports as permanently denied)
  /// gets a real prompt.
  Future<PermissionAuditResult> ensureRequiredPermissions({
    required bool audioEnabled,
    bool galleryExportEnabled = false,
  }) async {
    final missingRequired = <String>[];
    final missingRecommended = <String>[];
    final permanentlyDeniedRequired = <String>[];

    Future<bool> ensure(
      Permission permission,
      String label, {
      required bool required,
    }) async {
      var status = await permission.status;
      if (isPermissionGranted(status)) {
        return true;
      }

      status = await permission.request();
      if (isPermissionGranted(status)) {
        return true;
      }

      if (required) {
        missingRequired.add(label);
        if (status.isPermanentlyDenied) {
          permanentlyDeniedRequired.add(label);
        }
      } else {
        missingRecommended.add(label);
      }
      return false;
    }

    await ensure(Permission.camera, 'Camera', required: true);

    if (audioEnabled) {
      await ensure(Permission.microphone, 'Microphone', required: true);
    }

    // While-in-use location is enough: during recording the location-typed
    // foreground service, started while the app is visible, keeps GPS
    // working with the screen off.
    await ensure(Permission.locationWhenInUse, 'Location', required: true);

    if (defaultTargetPlatform == TargetPlatform.android) {
      await ensure(
        Permission.notification,
        'Notifications (foreground recording status)',
        required: false,
      );

      if (galleryExportEnabled) {
        final deviceStatus = await _deviceStatusService
            .getBatteryAndThermalStatus();
        if (needsLegacyStoragePermission(deviceStatus.androidSdkInt)) {
          await ensure(
            Permission.storage,
            'Storage (gallery copy of locked clips)',
            required: false,
          );
        }
      }

      final isIgnoringBatteryOptimizations = await BackgroundRecordingService
          .instance
          .isIgnoringBatteryOptimizations();
      if (!isIgnoringBatteryOptimizations) {
        missingRecommended.add('Ignore battery optimizations');
      }
    }

    return PermissionAuditResult(
      missingRequired: List<String>.unmodifiable(missingRequired),
      missingRecommended: List<String>.unmodifiable(missingRecommended),
      permanentlyDeniedRequired: List<String>.unmodifiable(
        permanentlyDeniedRequired,
      ),
    );
  }

  /// Whether the legacy WRITE_EXTERNAL_STORAGE permission must be requested
  /// for the gallery export, given the Android API level [sdkInt].
  ///
  /// Returns false when the level is unknown (null): on API 29+ the plugin
  /// reports storage as denied without ever showing a dialog, so asking
  /// blindly would report a permission that can never be granted.
  static bool needsLegacyStoragePermission(int? sdkInt) {
    return sdkInt != null && sdkInt < scopedStorageSdkInt;
  }
}
