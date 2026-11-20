// lib/features/recording/widgets/recording_preview.dart

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../camera/providers/camera_init_status.dart';
import '../recording_screen_logic.dart';

/// The camera preview area: the live preview, a spinner while the camera
/// gets ready, or the camera-unavailable panel.
///
/// Nothing is built under Blackout: the camera keeps its Preview use case
/// bound, but no preview widget is drawn behind the black overlay.
class RecordingPreview extends StatelessWidget {
  /// Creates the preview area.
  const RecordingPreview({
    super.key,
    required this.isBlackoutMode,
    required this.controller,
    required this.mode,
    required this.initFailure,
    required this.previewKey,
    required this.thumbnail,
    required this.onRetry,
    required this.onOpenSettings,
  });

  /// The Blackout overlay is up.
  final bool isBlackoutMode;

  /// The initialized camera controller, or null.
  final CameraController? controller;

  /// What the area shows when [controller] is not ready.
  final CameraPreviewMode mode;

  /// Why the camera is unavailable, when [mode] is failed.
  final CameraInitFailure? initFailure;

  /// Key of the preview subtree. A changed key rebuilds the preview, so it
  /// changes only with the resolution, frame rate, camera or controller.
  final Key previewKey;

  /// Drawn as the small live thumbnail of a recording (no caption, smaller
  /// corners) instead of the large Ready preview.
  final bool thumbnail;

  /// Retries the camera setup.
  final VoidCallback onRetry;

  /// Opens the app's system settings, then retries.
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    if (isBlackoutMode) {
      return const ColoredBox(color: Colors.black);
    }

    final controller = this.controller;
    if (controller == null) {
      if (mode == CameraPreviewMode.failed) {
        return _buildCameraUnavailable();
      }
      return const Center(
        child: CircularProgressIndicator(color: MotoColors.dim),
      );
    }

    if (!controller.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: MotoColors.dim),
      );
    }
    final rawAspectRatio = controller.value.aspectRatio;
    final safeAspectRatio = rawAspectRatio.isFinite && rawAspectRatio > 0
        ? rawAspectRatio
        : (16 / 9);
    final portraitAspectRatio = safeAspectRatio > 1
        ? (1 / safeAspectRatio)
        : safeAspectRatio;

    return Stack(
      key: previewKey,
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(thumbnail ? 10 : MotoRadii.lg),
            child: ColoredBox(
              color: MotoColors.surface,
              child: Center(
                child: AspectRatio(
                  aspectRatio: portraitAspectRatio,
                  child: CameraPreview(controller),
                ),
              ),
            ),
          ),
        ),
        if (!thumbnail)
          Positioned(
            left: 12,
            top: 12,
            child: ExcludeSemantics(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: MotoColors.bg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Live view',
                  style: MotoFonts.bodyStyle(13, color: MotoColors.dim),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCameraUnavailable() {
    final panel = cameraInitPanelFor(initFailure);
    return ColoredBox(
      color: MotoColors.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.videocam_off_outlined,
                color: MotoColors.dim,
                size: 40,
              ),
              const SizedBox(height: MotoSize.gapWide),
              Text(
                panel.title,
                textAlign: TextAlign.center,
                style: MotoFonts.condensedStyle(
                  24,
                  weight: FontWeight.w600,
                  color: MotoColors.text,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                panel.message,
                textAlign: TextAlign.center,
                style: MotoFonts.bodyStyle(15, color: MotoColors.dim),
              ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: MotoSize.gapWide,
                runSpacing: MotoSize.gap,
                children: [
                  if (panel.showRetry)
                    FilledButton(
                      onPressed: onRetry,
                      child: const Text('Retry'),
                    ),
                  if (panel.showOpenSettings)
                    OutlinedButton(
                      onPressed: onOpenSettings,
                      child: const Text('Open Settings'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
