import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/utils/format_utils.dart';
import 'playback_position.dart';
import 'playback_seekbar_track_shape.dart';
import 'playback_timeline.dart';

/// The seekbar: a slider whose track marks [marks], with the elapsed and
/// total time under it.
///
/// The slider and the elapsed-time label listen to [position] on their own,
/// so a position tick rebuilds nothing else. Scrub gestures go to the
/// callbacks; this widget never touches the video controller.
class PlaybackSeekBar extends StatelessWidget {
  /// Creates the seekbar for a timeline [totalDuration] long.
  const PlaybackSeekBar({
    super.key,
    required this.position,
    required this.totalDuration,
    required this.marks,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onScrubEnd,
  });

  /// Height, in logical pixels, of the slider row.
  static const double sliderHeight = 34;

  /// The playback position the thumb and the elapsed-time label show.
  final ValueListenable<PlaybackPosition> position;

  /// Length of the ride timeline.
  final Duration totalDuration;

  /// The ranges and markers drawn on the track.
  final PlaybackTimelineMarks marks;

  /// The rider pressed the thumb or the track.
  final VoidCallback onScrubStart;

  /// The thumb moved to the given position.
  final void Function(Duration target) onScrubUpdate;

  /// The rider let go at [valueMs] on a slider [sliderWidth] pixels wide.
  final void Function(double valueMs, double sliderWidth) onScrubEnd;

  @override
  Widget build(BuildContext context) {
    final totalMs = totalDuration.inMilliseconds;
    final maxMs = totalMs > 0 ? totalMs : 1;
    final enabled = totalMs > 0;
    return Column(
      children: [
        SizedBox(
          height: sliderHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackShape: PlaybackSeekbarTrackShape(
                    totalDurationMs: totalMs,
                    missingRanges: marks.missingRanges,
                    failedCheckRanges: marks.failedCheckRanges,
                    noVideoRanges: marks.noVideoRanges,
                    incidentMarkerMs: marks.incidentMarkerMs,
                    lockMarkerMs: marks.lockMarkerMs,
                  ),
                ),
                child: ValueListenableBuilder<PlaybackPosition>(
                  valueListenable: position,
                  builder: (context, value, _) => Slider(
                    min: 0,
                    max: maxMs.toDouble(),
                    value: value.position.inMilliseconds
                        .clamp(0, maxMs)
                        .toDouble(),
                    onChangeStart: enabled ? (_) => onScrubStart() : null,
                    onChanged: enabled
                        ? (newValue) => onScrubUpdate(
                            Duration(milliseconds: newValue.round()),
                          )
                        : null,
                    onChangeEnd: enabled
                        ? (newValue) =>
                              onScrubEnd(newValue, constraints.maxWidth)
                        : null,
                  ),
                ),
              );
            },
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            ValueListenableBuilder<PlaybackPosition>(
              valueListenable: position,
              builder: (context, value, _) =>
                  Text(formatElapsed(value.position)),
            ),
            Text(formatElapsed(totalDuration)),
          ],
        ),
      ],
    );
  }
}
