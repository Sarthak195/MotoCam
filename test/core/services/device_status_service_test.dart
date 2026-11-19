import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/services/device_status_service.dart';

const _channel = MethodChannel('com.example.motocam/device_status');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger().setMockMethodCallHandler(_channel, null);
  });

  group('DeviceStatusSnapshot.fromMap', () {
    test('parses every field', () {
      final snapshot = DeviceStatusSnapshot.fromMap({
        'batteryLevelPercent': 57.0,
        'batteryTemperatureC': 31,
        'thermalStatus': 'light',
        'sdkInt': 28,
      });

      expect(snapshot.batteryLevelPercent, 57);
      expect(snapshot.batteryTemperatureC, 31.0);
      expect(snapshot.thermalStatus, 'light');
      expect(snapshot.androidSdkInt, 28);
    });

    test('maps missing or mistyped entries to null', () {
      final snapshot = DeviceStatusSnapshot.fromMap({
        'batteryLevelPercent': 'full',
        'thermalStatus': 3,
      });

      expect(snapshot, DeviceStatusSnapshot.empty);
      expect(snapshot.androidSdkInt, isNull);
    });

    test('equality includes the API level', () {
      expect(
        const DeviceStatusSnapshot(androidSdkInt: 28),
        isNot(const DeviceStatusSnapshot(androidSdkInt: 29)),
      );
      expect(
        const DeviceStatusSnapshot(androidSdkInt: 28).hashCode,
        const DeviceStatusSnapshot(androidSdkInt: 28).hashCode,
      );
    });
  });

  group('DeviceStatusService', () {
    test('returns the native snapshot on Android', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger().setMockMethodCallHandler(_channel, (call) async {
        expect(call.method, 'getBatteryStatus');
        return {'batteryLevelPercent': 12, 'sdkInt': 34};
      });

      final snapshot = await const DeviceStatusService()
          .getBatteryAndThermalStatus();

      expect(snapshot.batteryLevelPercent, 12);
      expect(snapshot.androidSdkInt, 34);
    });

    test('returns empty when the native call fails', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger().setMockMethodCallHandler(_channel, (call) async {
        throw PlatformException(code: 'ERROR');
      });

      expect(
        await const DeviceStatusService().getBatteryAndThermalStatus(),
        DeviceStatusSnapshot.empty,
      );
    });

    test('returns empty off Android without calling the channel', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      var called = false;
      messenger().setMockMethodCallHandler(_channel, (call) async {
        called = true;
        return null;
      });

      expect(
        await const DeviceStatusService().getBatteryAndThermalStatus(),
        DeviceStatusSnapshot.empty,
      );
      expect(called, isFalse);
    });
  });
}
