// lib/features/recording/widgets/recording_preview.dart

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

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
    required this.isRecording,
    required this.isSegmentLocked,
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

  /// A recording is running.
  final bool isRecording;

  /// The segment being recorded is locked.
  final bool isSegmentLocked;

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
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    if (!controller.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
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
            borderRadius: BorderRadius.circular(10),
            child: ColoredBox(
              color: Colors.black,
              child: Center(
                child: AspectRatio(
                  aspectRatio: portraitAspectRatio,
                  child: CameraPreview(controller),
                ),
              ),
            ),
          ),
        ),
        if (isRecording)
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'REC',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (isSegmentLocked) ...[
                    const SizedBox(width: 10),
                    const Icon(Icons.lock, color: Colors.white, size: 14),
                    const SizedBox(width: 4),
                    const Text(
                      'LOCKED',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCameraUnavailable() {
    final panel = cameraInitPanelFor(initFailure);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, color: Colors.white54, size: 40),
            const SizedBox(height: 12),
            Text(
              panel.title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              panel.message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                if (panel.showRetry)
                  ElevatedButton(
                    onPressed: onRetry,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: recordingStartButtonColor,
                      foregroundColor: recordingButtonLabelColor,
                    ),
                    child: const Text('Retry'),
                  ),
                if (panel.showOpenSettings)
                  OutlinedButton(
                    onPressed: onOpenSettings,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
                    child: const Text('Open Settings'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
