import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/features/camera/providers/camera_provider.dart';

void main() {
  group('CameraProvider resolution mapping', () {
    test('maps each selectable resolution to its preset', () {
      expect(CameraProvider.presetForResolution(480), ResolutionPreset.medium);
      expect(CameraProvider.presetForResolution(720), ResolutionPreset.high);
      expect(
        CameraProvider.presetForResolution(1080),
        ResolutionPreset.veryHigh,
      );
      expect(
        CameraProvider.presetForResolution(2160),
        ResolutionPreset.ultraHigh,
      );
    });

    test('maps each preset back to the resolution shown in the UI', () {
      expect(CameraProvider.resolutionForPreset(ResolutionPreset.low), 480);
      expect(CameraProvider.resolutionForPreset(ResolutionPreset.medium), 480);
      expect(CameraProvider.resolutionForPreset(ResolutionPreset.high), 720);
      expect(
        CameraProvider.resolutionForPreset(ResolutionPreset.veryHigh),
        1080,
      );
      expect(
        CameraProvider.resolutionForPreset(ResolutionPreset.ultraHigh),
        2160,
      );
      expect(CameraProvider.resolutionForPreset(ResolutionPreset.max), 2160);
    });

    test('selectable resolutions round-trip', () {
      for (final resolution in const [480, 720, 1080, 2160]) {
        expect(
          CameraProvider.resolutionForPreset(
            CameraProvider.presetForResolution(resolution),
          ),
          resolution,
        );
      }
    });
  });

  group('CameraProvider idle state', () {
    test('starts idle with no transition or failure in progress', () {
      final provider = CameraProvider();
      addTearDown(provider.dispose);

      expect(provider.isRecording, isFalse);
      expect(provider.isStartingRecording, isFalse);
      expect(provider.isStoppingRecording, isFalse);
      expect(provider.isInitializing, isFalse);
      expect(provider.lastRecordingError, isNull);
      expect(provider.recordingStartedAt, isNull);
      expect(provider.autoExportLockedClipsToGallery, isFalse);
    });

    test(
      'startRecording refuses while the camera is not initialized',
      () async {
        final provider = CameraProvider();
        addTearDown(provider.dispose);

        expect(await provider.startRecording(), isFalse);
        expect(provider.isStartingRecording, isFalse);
      },
    );

    test('stopRecording is a no-op when not recording', () async {
      final provider = CameraProvider();
      addTearDown(provider.dispose);

      expect(await provider.stopRecording(), isNull);
      expect(provider.isStoppingRecording, isFalse);
    });

    test(
      'availableStorageBytes is null before a recordings directory exists',
      () async {
        final provider = CameraProvider();
        addTearDown(provider.dispose);

        expect(await provider.availableStorageBytes(), isNull);
      },
    );

    test('markIncident without a session adds no pending locks', () {
      final provider = CameraProvider();
      addTearDown(provider.dispose);

      provider.markIncident();
      expect(provider.lockedSegmentCount, 0);
    });

    test('a migration hold can be released more than once, and overlapping '
        'holds release independently', () {
      final provider = CameraProvider();
      addTearDown(provider.dispose);

      final first = provider.holdRecordingsMigration();
      final second = provider.holdRecordingsMigration();
      first();
      first();
      second();
      // Nothing starts without a recordings directory (and off Android).
      expect(provider.isRecordingsMigrationIdle, isTrue);
    });

    test('gallery export of locked clips is off by default', () {
      final provider = CameraProvider();
      addTearDown(provider.dispose);

      expect(provider.autoExportLockedClipsToGallery, isFalse);
      expect(provider.lastGalleryExportMessage, isNull);
    });
  });

  group('CameraProvider.nearestSupportedFps', () {
    test('keeps the requested rate when offered', () {
      expect(
        CameraProvider.nearestSupportedFps(
          requested: 60,
          options: [24, 30, 60],
        ),
        60,
      );
    });

    test('falls back to 30, then the next lower, then the lowest rate', () {
      expect(
        CameraProvider.nearestSupportedFps(requested: 60, options: [24, 30]),
        30,
      );
      expect(
        CameraProvider.nearestSupportedFps(requested: 60, options: [24, 48]),
        48,
      );
      expect(
        CameraProvider.nearestSupportedFps(requested: 20, options: [60, 24]),
        24,
      );
      expect(
        CameraProvider.nearestSupportedFps(requested: 30, options: const []),
        30,
      );
    });
  });

  group('CameraProvider.galleryExportSummary', () {
    test('describes copied, failed and denied clips', () {
      expect(
        CameraProvider.galleryExportSummary(
          exported: 1,
          failed: 0,
          permissionDenied: false,
        ),
        '1 locked clip copied to the gallery.',
      );
      expect(
        CameraProvider.galleryExportSummary(
          exported: 2,
          failed: 1,
          permissionDenied: false,
        ),
        '2 locked clips copied to the gallery; 1 locked clip could not be '
        'copied to the gallery.',
      );
      expect(
        CameraProvider.galleryExportSummary(
          exported: 0,
          failed: 3,
          permissionDenied: true,
        ),
        '3 locked clips not copied (storage permission denied).',
      );
    });
  });
}
