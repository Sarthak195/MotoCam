// lib/features/telemetry/widgets/speed_overlay.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/telemetry_provider.dart';

class SpeedOverlay extends StatelessWidget {
  const SpeedOverlay({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Consumer<TelemetryProvider>(
      builder: (context, telemetry, _) {
        final speed = telemetry.currentData.speed;

        return Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.7),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: _getSpeedColor(speed),
                width: 2,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  speed.toStringAsFixed(0),
                  style: TextStyle(
                    color: _getSpeedColor(speed),
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'km/h',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.8),
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Color _getSpeedColor(double speed) {
    if (speed < 40) return Colors.greenAccent;
    if (speed < 60) return Colors.yellowAccent;
    if (speed < 80) return Colors.orangeAccent;
    return Colors.redAccent;
  }
}