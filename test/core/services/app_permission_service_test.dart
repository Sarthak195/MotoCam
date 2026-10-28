import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/services/app_permission_service.dart';
import 'package:permission_handler/permission_handler.dart';

const _permissionChannel = MethodChannel(
  'flutter.baseflow.com/permissions/methods',
);
const _deviceStatusChannel = MethodChannel('com.example.motocam/device_status');
const _backgroundChannel = MethodChannel(
  'com.example.motocam/background_recording',
);

// permission_handler's wire encoding of PermissionStatus.
const _denied = 0;
const _granted = 1;
const _permanentlyDenied = 4;

/// Fake permission_handler / native state for one test.
class _FakePlatform {
  final Map<int, int> statuses = {};
  final Map<int, int> requestResults = {};
  final List<int> checked = [];
  final List<int> requested = [];
  final List<String> backgroundCalls = [];
  int? sdkInt;
  bool ignoringBatteryOptimizations = true;

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_permissionChannel, (call) async {
      switch (call.method) {
        case 'checkPermissionStatus':
          final value = call.arguments as int;
          checked.add(value);
          return statuses[value] ?? _denied;
        case 'requestPermissions':
          final values = (call.arguments as List).cast<int>();
          requested.addAll(values);
          return {
            for (final value in values)
              value: requestResults[value] ?? statuses[value] ?? _denied,
          };
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_deviceStatusChannel, (call) async {
      return <String, Object?>{
        'batteryLevelPercent': 80,
        if (sdkInt != null) 'sdkInt': sdkInt,
      };
    });
    messenger.setMockMethodCallHandler(_backgroundChannel, (call) async {
      backgroundCalls.add(call.method);
      switch (call.method) {
        case 'isIgnoringBatteryOptimizations':
          return ignoringBatteryOptimizations;
        case 'requestIgnoreBatteryOptimizations':
          return true;
      }
      return null;
    });
  }

  void grantAll(Iterable<Permission> permissions) {
    for (final permission in permissions) {
      statuses[permission.value] = _granted;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlatform platform;
  const service = AppPermissionService();
  const requiredPermissions = [
    Permission.camera,
    Permission.microphone,
    Permission.locationWhenInUse,
  ];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    platform = _FakePlatform()..install();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_permissionChannel, null);
    messenger.setMockMethodCallHandler(_deviceStatusChannel, null);
    messenger.setMockMethodCallHandler(_backgroundChannel, null);
  });

  test('reports no issues and requests nothing when all are granted', () async {
    platform.grantAll([...requiredPermissions, Permission.notification]);

    final audit = await service.ensureRequiredPermissions(audioEnabled: true);

    expect(audit.hasAnyIssue, isFalse);
    expect(audit.hasPermanentlyDenied, isFalse);
    expect(platform.requested, isEmpty);
  });

  test(
    're-requests a permission whose status reads permanently denied',
    () async {
      // permission_handler_android 13.x reports a permission reset to
      // "Ask every time" as permanently denied.
      platform.grantAll([Permission.microphone, Permission.locationWhenInUse]);
      platform.statuses[Permission.camera.value] = _permanentlyDenied;
      platform.requestResults[Permission.camera.value] = _granted;

      final audit = await service.ensureRequiredPermissions(audioEnabled: true);

      expect(platform.requested, contains(Permission.camera.value));
      expect(audit.missingRequired, isEmpty);
      expect(audit.hasPermanentlyDenied, isFalse);
    },
  );

  test('derives permanent denial from the request result', () async {
    platform.grantAll([Permission.microphone, Permission.locationWhenInUse]);
    platform.requestResults[Permission.camera.value] = _permanentlyDenied;

    final audit = await service.ensureRequiredPermissions(audioEnabled: true);

    expect(audit.missingRequired, ['Camera']);
    expect(audit.permanentlyDeniedRequired, ['Camera']);
    expect(audit.hasPermanentlyDenied, isTrue);
    expect(audit.hasBlockingIssues, isTrue);
  });

  test('a permanently denied recommended permission does not flag the '
      'required ones as permanently denied', () async {
    platform.grantAll([Permission.microphone, Permission.locationWhenInUse]);
    platform.statuses[Permission.notification.value] = _permanentlyDenied;
    platform.requestResults[Permission.camera.value] = _denied;

    final audit = await service.ensureRequiredPermissions(audioEnabled: true);

    expect(audit.missingRequired, ['Camera']);
    expect(
      audit.missingRecommended,
      contains('Notifications (foreground recording status)'),
    );
    expect(audit.permanentlyDeniedRequired, isEmpty);
    expect(audit.hasPermanentlyDenied, isFalse);
  });

  test('never checks or requests background location', () async {
    platform.grantAll([...requiredPermissions, Permission.notification]);
    platform.statuses[Permission.locationAlways.value] = _denied;

    await service.ensureRequiredPermissions(audioEnabled: true);

    expect(platform.checked, isNot(contains(Permission.locationAlways.value)));
    expect(
      platform.requested,
      isNot(contains(Permission.locationAlways.value)),
    );
  });

  test('skips the microphone when audio is disabled', () async {
    platform.grantAll([Permission.camera, Permission.locationWhenInUse]);

    final audit = await service.ensureRequiredPermissions(audioEnabled: false);

    expect(platform.checked, isNot(contains(Permission.microphone.value)));
    expect(audit.missingRequired, isEmpty);
  });

  test('reports a missing battery exemption without requesting it', () async {
    platform.grantAll([...requiredPermissions, Permission.notification]);
    platform.ignoringBatteryOptimizations = false;

    final audit = await service.ensureRequiredPermissions(audioEnabled: true);

    expect(audit.missingRecommended, ['Ignore battery optimizations']);
    expect(audit.hasBlockingIssues, isFalse);
    expect(
      platform.backgroundCalls,
      isNot(contains('requestIgnoreBatteryOptimizations')),
    );
  });

  test(
    'requests legacy storage below Android 10 when gallery export is on',
    () async {
      platform.grantAll([...requiredPermissions, Permission.notification]);
      platform.sdkInt = 28;
      platform.requestResults[Permission.storage.value] = _denied;

      final audit = await service.ensureRequiredPermissions(
        audioEnabled: true,
        galleryExportEnabled: true,
      );

      expect(platform.requested, contains(Permission.storage.value));
      expect(
        audit.missingRecommended,
        contains('Storage (gallery copy of locked clips)'),
      );
    },
  );

  test('does not touch storage while gallery export is off', () async {
    platform.grantAll([...requiredPermissions, Permission.notification]);
    platform.sdkInt = 28;

    final audit = await service.ensureRequiredPermissions(audioEnabled: true);

    expect(audit.hasAnyIssue, isFalse);
    expect(platform.checked, isNot(contains(Permission.storage.value)));
    expect(platform.requested, isNot(contains(Permission.storage.value)));
  });

  test(
    'does not touch storage on Android 10+ or an unknown API level',
    () async {
      platform.grantAll([...requiredPermissions, Permission.notification]);

      for (final sdkInt in [null, 29, 36]) {
        platform.sdkInt = sdkInt;
        final audit = await service.ensureRequiredPermissions(
          audioEnabled: true,
          galleryExportEnabled: true,
        );
        expect(audit.hasAnyIssue, isFalse, reason: 'sdkInt=$sdkInt');
      }
      expect(platform.checked, isNot(contains(Permission.storage.value)));
    },
  );

  test('skips the Android-only checks on iOS', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    platform.grantAll(requiredPermissions);
    platform.ignoringBatteryOptimizations = false;
    platform.sdkInt = 28;

    final audit = await service.ensureRequiredPermissions(audioEnabled: true);

    expect(audit.hasAnyIssue, isFalse);
    expect(platform.checked, isNot(contains(Permission.notification.value)));
    expect(platform.backgroundCalls, isEmpty);
  });

  test('needsLegacyStoragePermission gates on API level 29', () {
    expect(AppPermissionService.needsLegacyStoragePermission(null), isFalse);
    expect(AppPermissionService.needsLegacyStoragePermission(24), isTrue);
    expect(AppPermissionService.needsLegacyStoragePermission(28), isTrue);
    expect(AppPermissionService.needsLegacyStoragePermission(29), isFalse);
  });

  test('isPermissionGranted accepts granted and limited only', () {
    expect(
      AppPermissionService.isPermissionGranted(PermissionStatus.granted),
      isTrue,
    );
    expect(
      AppPermissionService.isPermissionGranted(PermissionStatus.limited),
      isTrue,
    );
    for (final status in [
      PermissionStatus.denied,
      PermissionStatus.permanentlyDenied,
      PermissionStatus.restricted,
      PermissionStatus.provisional,
    ]) {
      expect(AppPermissionService.isPermissionGranted(status), isFalse);
    }
  });
}
