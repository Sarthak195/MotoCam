import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

import 'background_recording_service.dart';

class PermissionAuditResult {
  const PermissionAuditResult({
    required this.missingRequired,
    required this.missingRecommended,
    required this.hasPermanentlyDenied,
  });

  final List<String> missingRequired;
  final List<String> missingRecommended;
  final bool hasPermanentlyDenied;

  bool get hasBlockingIssues => missingRequired.isNotEmpty;
  bool get hasAnyIssue =>
      missingRequired.isNotEmpty || missingRecommended.isNotEmpty;
}

class AppPermissionService {
  const AppPermissionService();

  Future<PermissionAuditResult> ensureRequiredPermissions({
    required bool audioEnabled,
  }) async {
    final missingRequired = <String>[];
    final missingRecommended = <String>[];
    var hasPermanentlyDenied = false;

    Future<bool> ensure(
      Permission permission,
      String label, {
      required bool required,
    }) async {
      var status = await permission.status;
      if (status.isGranted || status.isLimited) {
        return true;
      }

      if (status.isDenied || status.isRestricted || status.isLimited) {
        status = await permission.request();
      }

      final granted = status.isGranted || status.isLimited;
      if (granted) {
        return true;
      }

      if (status.isPermanentlyDenied) {
        hasPermanentlyDenied = true;
      }

      if (required) {
        missingRequired.add(label);
      } else {
        missingRecommended.add(label);
      }
      return false;
    }

    await ensure(Permission.camera, 'Camera', required: true);

    if (audioEnabled) {
      await ensure(Permission.microphone, 'Microphone', required: true);
    }

    final hasLocationWhenInUse = await ensure(
      Permission.locationWhenInUse,
      'Location',
      required: true,
    );

    if (Platform.isAndroid) {
      await ensure(
        Permission.notification,
        'Notifications (foreground recording status)',
        required: false,
      );

      if (hasLocationWhenInUse) {
        await ensure(
          Permission.locationAlways,
          'Background location (screen-off tracking)',
          required: false,
        );
      }

      final storagePermission = Platform.isAndroid
          ? Permission.videos
          : Permission.storage;
      await ensure(
        storagePermission,
        'Media access (gallery export)',
        required: false,
      );

      final backgroundService = BackgroundRecordingService.instance;
      final isIgnoringBatteryOptimizations =
          await backgroundService.isIgnoringBatteryOptimizations();
      if (!isIgnoringBatteryOptimizations) {
        await backgroundService.requestIgnoreBatteryOptimizations();
        final stillNotIgnoring =
            !(await backgroundService.isIgnoringBatteryOptimizations());
        if (stillNotIgnoring) {
          missingRecommended.add('Ignore battery optimizations');
        }
      }
    }

    return PermissionAuditResult(
      missingRequired: List<String>.unmodifiable(missingRequired),
      missingRecommended: List<String>.unmodifiable(missingRecommended),
      hasPermanentlyDenied: hasPermanentlyDenied,
    );
  }
}
