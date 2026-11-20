// lib/features/recording/widgets/recording_stats.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/ui/big_numeral.dart';
import '../../telemetry/providers/telemetry_provider.dart';

/// The speed hero of a recording: the speed in large type with its unit.
///
/// It keeps its own [Selector], so a speed tick rebuilds only the number and
/// never the screen.
class RecordingSpeed extends StatelessWidget {
  /// Creates the speed reading.
  const RecordingSpeed({super.key, this.size = 220});

  /// Font size of the number at full scale (it scales down to fit).
  final double size;

  @override
  Widget build(BuildContext context) {
    return Selector<TelemetryProvider, String>(
      selector: (_, telemetry) =>
          telemetry.currentData.speed.toStringAsFixed(0),
      builder: (context, speed, _) => BigNumeral(
        value: speed,
        unit: 'km/h',
        size: size,
        semanticsLabel: 'Speed $speed kilometres per hour',
      ),
    );
  }
}
