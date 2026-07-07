import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A point-in-time snapshot of battery level, temperature, and thermal
/// throttling state obtained from the Android platform.
class DeviceStatusSnapshot {
  const DeviceStatusSnapshot({
    this.batteryLevelPercent,
    this.batteryTemperatureC,
    this.thermalStatus,
  });

  final int? batteryLevelPercent;
  final double? batteryTemperatureC;
  final String? thermalStatus;

  static const empty = DeviceStatusSnapshot();

  factory DeviceStatusSnapshot.fromMap(Map<dynamic, dynamic> map) {
    final rawLevel = map['batteryLevelPercent'];
    final rawTemp = map['batteryTemperatureC'];
    final rawThermal = map['thermalStatus'];

    return DeviceStatusSnapshot(
      batteryLevelPercent: rawLevel is num ? rawLevel.toInt() : null,
      batteryTemperatureC: rawTemp is num ? rawTemp.toDouble() : null,
      thermalStatus: rawThermal is String ? rawThermal : null,
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
        other.thermalStatus == thermalStatus;
  }

  @override
  int get hashCode => Object.hash(
        batteryLevelPercent,
        batteryTemperatureC,
        thermalStatus,
      );
}

/// Reads battery and thermal status from the native Android platform via
/// a method channel.
///
/// Returns [DeviceStatusSnapshot.empty] on non-Android platforms or when
/// the native call fails.
class DeviceStatusService {
  static const MethodChannel _channel =
      MethodChannel('com.example.motocam/device_status');

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
