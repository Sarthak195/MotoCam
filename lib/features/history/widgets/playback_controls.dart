import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/utils/format_utils.dart';
import 'playback_position.dart';

/// The transport row: back 10 seconds, the round play or pause button,
/// forward 10 seconds, and the elapsed and total time.
///
/// Only the play/pause button and the elapsed time listen to [position];
/// the buttons report to the callbacks and never touch the video
/// controller.
class PlaybackControls extends StatelessWidget {
  /// Creates the transport row for a ride [totalDuration] long.
  const PlaybackControls({
    super.key,
    required this.position,
    required this.totalDuration,
    required this.onSeekBy,
    required this.onTogglePlay,
    this.playSize = 56,
  });

  /// The playback position and whether the video is playing.
  final ValueListenable<PlaybackPosition> position;

  /// Length of the ride timeline.
  final Duration totalDuration;

  /// Seek by the given offset from the current position (negative goes back).
  final void Function(Duration offset) onSeekBy;

  /// Play when paused, pause when playing.
  final VoidCallback onTogglePlay;

  /// Diameter of the play button (56 in portrait, 52 in landscape).
  final double playSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _SkipButton(
          tooltip: 'Back 10 seconds',
          icon: Icons.replay_10,
          onPressed: () => onSeekBy(const Duration(seconds: -10)),
        ),
        const SizedBox(width: 4),
        ValueListenableBuilder<PlaybackPosition>(
          valueListenable: position,
          builder: (context, value, _) => Tooltip(
            message: value.isPlaying ? 'Pause' : 'Play',
            child: Material(
              color: MotoColors.text,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTogglePlay,
                child: SizedBox(
                  width: playSize,
                  height: playSize,
                  child: Icon(
                    value.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: playSize * 0.55,
                    color: MotoColors.bg,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        _SkipButton(
          tooltip: 'Forward 10 seconds',
          icon: Icons.forward_10,
          onPressed: () => onSeekBy(const Duration(seconds: 10)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: PlaybackTimeLabel(
            position: position,
            totalDuration: totalDuration,
          ),
        ),
      ],
    );
  }
}

class _SkipButton extends StatelessWidget {
  const _SkipButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(
        width: MotoSize.minTarget,
        height: MotoSize.minTarget,
      ),
      padding: EdgeInsets.zero,
      icon: Icon(icon, color: MotoColors.text, size: 26),
    );
  }
}

/// "00:03:46 / 00:11:18": the elapsed time (it follows [position]) in the
/// text colour and the total in muted grey, scaled down when the row is
/// narrow.
class PlaybackTimeLabel extends StatelessWidget {
  /// Creates the label for a ride [totalDuration] long.
  const PlaybackTimeLabel({
    super.key,
    required this.position,
    required this.totalDuration,
  });

  /// The playback position.
  final ValueListenable<PlaybackPosition> position;

  /// Length of the ride timeline.
  final Duration totalDuration;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder<PlaybackPosition>(
            valueListenable: position,
            builder: (context, value, _) => Text(
              formatElapsed(value.position),
              style: MotoFonts.condensedStyle(
                26,
                weight: FontWeight.w600,
                color: MotoColors.text,
                tabularFigures: true,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '/ ${formatElapsed(totalDuration)}',
            style: MotoFonts.condensedStyle(
              26,
              weight: FontWeight.w600,
              color: MotoColors.muted,
              tabularFigures: true,
            ),
          ),
        ],
      ),
    );
  }
}
