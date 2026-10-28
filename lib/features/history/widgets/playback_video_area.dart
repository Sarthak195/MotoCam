import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// The video itself, centred at its aspect ratio; a tap calls [onTap].
///
/// The only playback widget that holds the [VideoPlayerController]: the rest
/// of the screen takes a position and callbacks.
class PlaybackVideoSurface extends StatelessWidget {
  /// Creates the surface for an initialized [controller].
  const PlaybackVideoSurface({
    super.key,
    required this.controller,
    required this.onTap,
  });

  /// The initialized controller of the segment being played.
  final VideoPlayerController controller;

  /// The rider tapped the video.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }
}

/// The area above the seekbar: the [video], the optional telemetry [overlay]
/// and [speedGraph] on top of it (both [Positioned] widgets), the fullscreen
/// button and, in fullscreen, the hint to tap the video.
class PlaybackVideoArea extends StatelessWidget {
  /// Creates the video area.
  const PlaybackVideoArea({
    super.key,
    required this.video,
    required this.isFullscreen,
    required this.onToggleFullscreen,
    this.overlay,
    this.speedGraph,
  });

  /// The video, usually a [PlaybackVideoSurface].
  final Widget video;

  /// The telemetry overlay (a [Positioned]), shown outside fullscreen.
  final Widget? overlay;

  /// The speed graph (a [Positioned]), shown outside fullscreen.
  final Widget? speedGraph;

  /// Whether the screen is in fullscreen playback.
  final bool isFullscreen;

  /// The rider pressed the fullscreen button.
  final VoidCallback onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        video,
        ?overlay,
        ?speedGraph,
        Positioned(
          top: 10,
          right: 10,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(20),
            ),
            child: IconButton(
              onPressed: onToggleFullscreen,
              icon: Icon(
                isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                color: Colors.white,
              ),
              tooltip: isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
            ),
          ),
        ),
        if (isFullscreen)
          Positioned(
            left: 0,
            right: 0,
            bottom: 14,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Tap video to show controls',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// What the screen shows when no segment of the ride can be played.
class PlaybackErrorView extends StatelessWidget {
  /// Creates the view for [message] with Back and Retry buttons.
  const PlaybackErrorView({
    super.key,
    required this.message,
    required this.onBack,
    required this.onRetry,
  });

  /// Why nothing can be played.
  final String message;

  /// The rider pressed Back.
  final VoidCallback onBack;

  /// The rider pressed Retry.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, size: 48, color: Colors.white54),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(onPressed: onBack, child: const Text('Back')),
                const SizedBox(width: 12),
                FilledButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
