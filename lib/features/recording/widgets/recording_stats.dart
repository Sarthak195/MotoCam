// lib/features/recording/widgets/recording_stats.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/services/device_status_service.dart';
import '../../telemetry/providers/telemetry_provider.dart';
import '../recording_screen_logic.dart';

/// The live readings: speed, recording time, distance, battery and
/// temperature.
///
/// Speed and distance keep their own [Selector] and the time its own
/// [StreamBuilder], so a reading tick rebuilds only its item and never the
/// screen.
class RecordingStats extends StatelessWidget {
  /// Creates the readings row.
  const RecordingStats({
    super.key,
    required this.timerStream,
    required this.elapsed,
    required this.deviceStatus,
  });

  /// Emits the recording time about once per second.
  final Stream<Duration> timerStream;

  /// The recording time now.
  final Duration elapsed;

  /// Battery and thermal status, polled every 15 s.
  final ValueListenable<DeviceStatusSnapshot> deviceStatus;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Selector<TelemetryProvider, String>(
              selector: (_, telemetry) =>
                  '${telemetry.currentData.speed.toStringAsFixed(0)} km/h',
              builder: (context, speed, _) {
                return _statItem(
                  icon: Icons.speed,
                  label: 'Speed',
                  value: speed,
                );
              },
            ),
          ),
          Expanded(
            child: StreamBuilder<Duration>(
              stream: timerStream,
              initialData: elapsed,
              builder: (context, snapshot) {
                return _statItem(
                  icon: Icons.timer,
                  label: 'Duration',
                  value: formatRecordingElapsed(snapshot.data ?? Duration.zero),
                );
              },
            ),
          ),
          Expanded(
            child: Selector<TelemetryProvider, String>(
              selector: (_, telemetry) =>
                  '${telemetry.rideDistanceKm.toStringAsFixed(2)} km',
              builder: (context, distance, _) {
                return _statItem(
                  icon: Icons.route,
                  label: 'Distance',
                  value: distance,
                );
              },
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<DeviceStatusSnapshot>(
              valueListenable: deviceStatus,
              builder: (context, status, _) {
                final batteryLevel = status.batteryLevelPercent;
                return _statItem(
                  icon: Icons.battery_std,
                  label: 'Battery',
                  value: batteryLevel == null ? '--' : '$batteryLevel%',
                );
              },
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<DeviceStatusSnapshot>(
              valueListenable: deviceStatus,
              builder: (context, status, _) {
                final batteryTemp = status.batteryTemperatureC;
                return _statItem(
                  icon: Icons.device_thermostat,
                  label: 'Temp',
                  value: batteryTemp == null
                      ? '--'
                      : '${batteryTemp.toStringAsFixed(1)} C',
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _statItem({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.blue, size: 20),
        const SizedBox(height: 2),
        // Scales the value down instead of ellipsizing it at large system
        // font sizes.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            maxLines: 1,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[400], fontSize: 10),
        ),
      ],
    );
  }
}
