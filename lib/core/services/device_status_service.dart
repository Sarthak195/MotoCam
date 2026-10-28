import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A point-in-time snapshot of battery level, temperature, and thermal
/// throttling state obtained from the Android platform.
class DeviceStatusSnapshot {
  /// Creates a snapshot; every field is optional and null when unknown.
  const DeviceStatusSnapshot({
    this.batteryLevelPercent,
    this.batteryTemperatureC,
    this.thermalStatus,
    this.androidSdkInt,
  });

  /// Battery charge in percent (0-100), or null when unknown.
  final int? batteryLevelPercent;

  /// Battery temperature in degrees Celsius, or null when unknown.
  final double? batteryTemperatureC;

  /// Thermal throttling status name reported by the platform (API 29+), or
  /// null when unknown.
  final String? thermalStatus;

  /// The Android API level (`Build.VERSION.SDK_INT`), or null when the
  /// native side does not report it.
  final int? androidSdkInt;

  /// A snapshot with every field unknown.
  static const empty = DeviceStatusSnapshot();

  /// Parses the map returned by the native `getBatteryStatus` call. Missing or
  /// mistyped entries become null.
  factory DeviceStatusSnapshot.fromMap(Map<dynamic, dynamic> map) {
    final rawLevel = map['batteryLevelPercent'];
    final rawTemp = map['batteryTemperatureC'];
    final rawThermal = map['thermalStatus'];
    final rawSdkInt = map['sdkInt'];

    return DeviceStatusSnapshot(
      batteryLevelPercent: rawLevel is num ? rawLevel.toInt() : null,
      batteryTemperatureC: rawTemp is num ? rawTemp.toDouble() : null,
      thermalStatus: rawThermal is String ? rawThermal : null,
      androidSdkInt: rawSdkInt is num ? rawSdkInt.toInt() : null,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is DeviceStatusSnapshot &&
        other.batteryLevelPercent == batteryLevelPercent &&
        other.batteryTemperatureC == batteryTemperatureC &&
        other.thermalStatus == thermalStatus &&
        other.androidSdkInt == androidSdkInt;
  }

  @override
  int get hashCode => Object.hash(
    batteryLevelPercent,
    batteryTemperatureC,
    thermalStatus,
    androidSdkInt,
  );
}

/// Reads battery and thermal status from the native Android platform via
/// a method channel.
///
/// Returns [DeviceStatusSnapshot.empty] on non-Android platforms or when
/// the native call fails.
class DeviceStatusService {
  /// Creates the service. It holds no state.
  const DeviceStatusService();

  static const MethodChannel _channel = MethodChannel(
    'com.example.motocam/device_status',
  );

  /// Fetches the current battery, thermal and API-level snapshot.
  Future<DeviceStatusSnapshot> getBatteryAndThermalStatus() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return DeviceStatusSnapshot.empty;
    }

    try {
      final data = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getBatteryStatus',
      );
      if (data == null) {
        return DeviceStatusSnapshot.empty;
      }
      return DeviceStatusSnapshot.fromMap(data);
    } catch (_) {
      return DeviceStatusSnapshot.empty;
    }
  }
}
