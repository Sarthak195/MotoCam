import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../telemetry/models/telemetry_data.dart';

/// The stats strip over the bottom of the video: speed, distance, G-force
/// and GPS position of the sample at the playback position.
///
/// Only this widget rebuilds when [sample] changes. Returns a [Positioned],
/// so it belongs directly in a [Stack].
class PlaybackTelemetryOverlay extends StatelessWidget {
  /// Creates the overlay for the sample in [sample].
  const PlaybackTelemetryOverlay({super.key, required this.sample});

  /// The telemetry sample at the playback position.
  final ValueListenable<TelemetryData> sample;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 12,
      right: 12,
      bottom: 84,
      child: RepaintBoundary(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(10),
          ),
          child: ValueListenableBuilder<TelemetryData>(
            valueListenable: sample,
            builder: (context, sample, _) => Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _Stat('Speed', '${sample.speed.toStringAsFixed(1)} km/h'),
                _Stat('Dist', '${sample.distanceKm.toStringAsFixed(2)} km'),
                _Stat('G', sample.accelerationG.toStringAsFixed(2)),
                _Stat(
                  'GPS',
                  '${sample.latitude.toStringAsFixed(5)}, '
                      '${sample.longitude.toStringAsFixed(5)}',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
