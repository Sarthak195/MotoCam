import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../telemetry/models/telemetry_data.dart';

/// The stats strip over the bottom of the video: speed, distance, G-force
/// and GPS position of the sample at the playback position. The stats wrap
/// onto a second line when the video is narrow.
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
      left: 10,
      right: 10,
      bottom: 10,
      child: RepaintBoundary(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: MotoColors.bg.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(MotoRadii.sm),
          ),
          child: ValueListenableBuilder<TelemetryData>(
            valueListenable: sample,
            builder: (context, sample, _) => Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 14,
              runSpacing: 4,
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
        Text(label, style: MotoFonts.bodyStyle(11, color: MotoColors.dim)),
        Text(
          value,
          style: MotoFonts.condensedStyle(
            15,
            weight: FontWeight.w600,
            color: MotoColors.text,
            tabularFigures: true,
          ),
        ),
      ],
    );
  }
}
