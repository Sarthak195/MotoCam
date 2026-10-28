import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'playback_position.dart';

/// The transport row under the seekbar (back 10 seconds, play or pause,
/// forward 10 seconds) and the "Segment n/m" label.
///
/// Only the play/pause button listens to [position], for whether the video
/// is playing; the buttons report to the callbacks and never touch the video
/// controller.
class PlaybackControls extends StatelessWidget {
  /// Creates the controls for segment [segmentNumber] of [segmentCount].
  const PlaybackControls({
    super.key,
    required this.position,
    required this.segmentNumber,
    required this.segmentCount,
    required this.onSeekBy,
    required this.onTogglePlay,
  });

  /// Source of whether the video is playing.
  final ValueListenable<PlaybackPosition> position;

  /// One-based number of the segment being played.
  final int segmentNumber;

  /// Number of playable segments in the playlist.
  final int segmentCount;

  /// Seek by the given offset from the current position (negative goes back).
  final void Function(Duration offset) onSeekBy;

  /// Play when paused, pause when playing.
  final VoidCallback onTogglePlay;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: 'Back 10 seconds',
              onPressed: () => onSeekBy(const Duration(seconds: -10)),
              icon: const Icon(Icons.replay_10),
            ),
            ValueListenableBuilder<PlaybackPosition>(
              valueListenable: position,
              builder: (context, value, _) => IconButton(
                tooltip: value.isPlaying ? 'Pause' : 'Play',
                onPressed: onTogglePlay,
                icon: Icon(
                  value.isPlaying ? Icons.pause_circle : Icons.play_circle,
                  size: 36,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Forward 10 seconds',
              onPressed: () => onSeekBy(const Duration(seconds: 10)),
              icon: const Icon(Icons.forward_10),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Segment $segmentNumber/$segmentCount',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }
}
