import 'package:flutter/material.dart';

import 'playback_seekbar_track_shape.dart';
import 'playback_timeline.dart';

/// The row under the seekbar's time labels that names each kind of range
/// and marker present in [marks]: a coloured dot and a label per kind.
/// Empty when nothing is marked.
class PlaybackLegend extends StatelessWidget {
  /// Creates the legend for [marks].
  const PlaybackLegend({super.key, required this.marks});

  /// What the seekbar marks.
  final PlaybackTimelineMarks marks;

  @override
  Widget build(BuildContext context) {
    if (marks.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: 12,
          runSpacing: 4,
          children: [
            if (marks.noVideoRanges.isNotEmpty)
              const _LegendEntry(noVideoColor, 'No video'),
            if (marks.missingRanges.isNotEmpty)
              const _LegendEntry(missingFootageColor, 'Missing segment'),
            if (marks.failedCheckRanges.isNotEmpty)
              const _LegendEntry(failedCheckColor, 'Failed integrity check'),
            if (marks.incidentMarkerMs.isNotEmpty)
              const _LegendEntry(incidentMarkerColor, 'Incident'),
            if (marks.lockMarkerMs.isNotEmpty)
              const _LegendEntry(lockMarkerColor, 'Locked'),
          ],
        ),
      ),
    );
  }
}

class _LegendEntry extends StatelessWidget {
  const _LegendEntry(this.color, this.label);

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ],
    );
  }
}
