import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../../core/theme/tokens.dart';

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

/// Hides the status and navigation bars for fullscreen playback
/// ([immersive] true, sticky: a swipe shows them for a moment) or shows
/// both again. The playback body calls it when fullscreen changes and when
/// it is disposed, so leaving the screen always restores the bars.
Future<void> setPlaybackImmersive(bool immersive) => immersive
    ? SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)
    : SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );

/// The video box: the [video] on a dark rounded surface, the optional
/// telemetry [overlay] (a [Positioned]), the "Clip 2 of 6" chip, the
/// fullscreen button and, in fullscreen, the hint to tap the video.
class PlaybackVideoArea extends StatelessWidget {
  /// Creates the video area.
  const PlaybackVideoArea({
    super.key,
    required this.video,
    required this.isFullscreen,
    required this.onToggleFullscreen,
    this.overlay,
    this.clipLabel,
  });

  /// The video, usually a [PlaybackVideoSurface].
  final Widget video;

  /// The telemetry overlay (a [Positioned]), shown outside fullscreen.
  final Widget? overlay;

  /// "Clip 2 of 6", shown outside fullscreen; left out when null.
  final String? clipLabel;

  /// Whether the screen is in fullscreen playback.
  final bool isFullscreen;

  /// The rider pressed the fullscreen button.
  final VoidCallback onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    final clipLabel = this.clipLabel;
    final stack = Stack(
      children: [
        Positioned.fill(child: video),
        ?overlay,
        if (clipLabel != null && !isFullscreen)
          Positioned(left: 10, top: 10, child: _VideoChip(label: clipLabel)),
        Positioned(
          top: 4,
          right: 4,
          child: IconButton(
            onPressed: onToggleFullscreen,
            style: IconButton.styleFrom(
              backgroundColor: MotoColors.bg.withValues(alpha: 0.72),
              minimumSize: const Size.square(MotoSize.minTarget),
            ),
            icon: Icon(
              isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
              color: MotoColors.text,
            ),
            tooltip: isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
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
                  color: MotoColors.bg.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(MotoRadii.sm),
                ),
                child: Text(
                  'Tap video to show controls',
                  style: MotoFonts.bodyStyle(
                    12,
                    weight: FontWeight.w600,
                    color: MotoColors.dim,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    if (isFullscreen) {
      return ColoredBox(color: Colors.black, child: stack);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(MotoRadii.md),
      child: ColoredBox(color: MotoColors.surface, child: stack),
    );
  }
}

class _VideoChip extends StatelessWidget {
  const _VideoChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: MotoColors.bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: MotoFonts.bodyStyle(13, color: MotoColors.dim)),
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
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, size: 48, color: MotoColors.muted),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: MotoFonts.bodyStyle(15, color: MotoColors.text),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton(onPressed: onBack, child: const Text('Back')),
                FilledButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
