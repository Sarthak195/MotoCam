import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import 'playback_position.dart';
import 'playback_seekbar_track_shape.dart';
import 'playback_timeline.dart';

/// The ride timeline: a slider whose track marks [marks] (missing,
/// failed-check and no-video ranges, clip edges, incident triangles and
/// lock diamonds) under a round playhead.
///
/// Only the slider listens to [position], so a position tick rebuilds
/// nothing else. Scrub gestures go to the callbacks; this widget never
/// touches the video controller. The elapsed and total time are shown by
/// the transport row (see `PlaybackTimeLabel`).
class PlaybackSeekBar extends StatelessWidget {
  /// Creates the timeline for a ride [totalDuration] long.
  const PlaybackSeekBar({
    super.key,
    required this.position,
    required this.totalDuration,
    required this.marks,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onScrubEnd,
    this.height = sliderHeight,
  });

  /// Height, in logical pixels, of the timeline in portrait.
  static const double sliderHeight = 56;

  /// Height, in logical pixels, of the timeline in landscape.
  static const double compactHeight = 44;

  /// The playback position the playhead shows.
  final ValueListenable<PlaybackPosition> position;

  /// Length of the ride timeline.
  final Duration totalDuration;

  /// The ranges and markers drawn on the track.
  final PlaybackTimelineMarks marks;

  /// The rider pressed the playhead or the track.
  final VoidCallback onScrubStart;

  /// The playhead moved to the given position.
  final void Function(Duration target) onScrubUpdate;

  /// The rider let go at [valueMs] on a slider [sliderWidth] pixels wide.
  final void Function(double valueMs, double sliderWidth) onScrubEnd;

  /// Height of the timeline: room for the triangles above the track and
  /// the diamonds under it.
  final double height;

  @override
  Widget build(BuildContext context) {
    final totalMs = totalDuration.inMilliseconds;
    final maxMs = totalMs > 0 ? totalMs : 1;
    final enabled = totalMs > 0;
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 8,
              activeTrackColor: MotoColors.text,
              inactiveTrackColor: MotoColors.hairlineStrong,
              disabledActiveTrackColor: MotoColors.disabled,
              disabledInactiveTrackColor: MotoColors.hairlineStrong,
              thumbColor: MotoColors.text,
              disabledThumbColor: MotoColors.disabled,
              overlayColor: MotoColors.text.withValues(alpha: 0.12),
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 10,
                elevation: 0,
                pressedElevation: 0,
              ),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
              trackShape: PlaybackSeekbarTrackShape(
                totalDurationMs: totalMs,
                missingRanges: marks.missingRanges,
                failedCheckRanges: marks.failedCheckRanges,
                noVideoRanges: marks.noVideoRanges,
                incidentMarkerMs: marks.incidentMarkerMs,
                lockMarkerMs: marks.lockMarkerMs,
                clipEdgeMs: marks.clipEdgeMs,
              ),
            ),
            child: Semantics(
              label: 'Ride timeline',
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
                      ? (newValue) => onScrubEnd(newValue, constraints.maxWidth)
                      : null,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
