import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/providers/app_settings_provider.dart';
import 'package:motocam/features/camera/providers/camera_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<AppSettingsProvider> _loadWith(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  final settings = AppSettingsProvider();
  await settings.load();
  return settings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('load', () {
    test('uses the defaults when nothing is stored', () async {
      final settings = await _loadWith({});

      expect(settings.isLoaded, isTrue);
      expect(settings.recordingResolution, 1080);
      expect(settings.recordingFps, 30);
      expect(settings.videoBitrateMbps, 8);
      expect(settings.qualityProfileId, '1080p_30_8');
      expect(settings.audioEnabled, isTrue);
      expect(settings.speedRefreshMs, 100);
      expect(settings.segmentDurationSeconds, 300);
      expect(settings.loopSegmentCount, 24);
      expect(settings.incidentSensitivity, IncidentSensitivity.medium);
      expect(settings.selectedCameraName, '');
      expect(settings.exportLockedClipsToGallery, isFalse);
    });

    test('persists the gallery export opt-in', () async {
      final settings = await _loadWith({});
      await settings.updateExportLockedClipsToGallery(true);
      expect(settings.exportLockedClipsToGallery, isTrue);

      final reloaded = AppSettingsProvider();
      await reloaded.load();
      expect(reloaded.exportLockedClipsToGallery, isTrue);
    });

    test('reads every stored value', () async {
      final settings = await _loadWith({
        'recording_resolution_p': 720,
        'recording_fps': 60,
        'video_bitrate_mbps': 12,
        'recording_audio_enabled': false,
        'speed_refresh_ms': 250,
        'dashcam_segment_duration_seconds': 60,
        'dashcam_loop_segment_count': 12,
        'incident_sensitivity': 'high',
        'camera_name': 'camera-1',
      });

      expect(settings.recordingResolution, 720);
      expect(settings.recordingFps, 60);
      expect(settings.videoBitrateMbps, 12);
      expect(settings.audioEnabled, isFalse);
      expect(settings.speedRefreshMs, 250);
      expect(settings.segmentDurationSeconds, 60);
      expect(settings.loopSegmentCount, 12);
      expect(settings.incidentSensitivity, IncidentSensitivity.high);
      expect(settings.selectedCameraName, 'camera-1');
      expect(settings.incidentTriggerGForce, 2.8);
      expect(settings.incidentDebounce, const Duration(seconds: 3));
    });

    test('migrates the legacy recording_quality key', () async {
      const expected = {
        'low': 480,
        'medium': 720,
        'high': 1080,
        'veryHigh': 1080,
        'ultraHigh': 2160,
        'unknown': 1080,
      };
      for (final entry in expected.entries) {
        final settings = await _loadWith({'recording_quality': entry.key});
        expect(settings.recordingResolution, entry.value, reason: entry.key);
      }
    });

    test('prefers the resolution key over the legacy quality key', () async {
      final settings = await _loadWith({
        'recording_quality': 'low',
        'recording_resolution_p': 2160,
      });
      expect(settings.recordingResolution, 2160);
    });

    test('migrates the legacy segment minutes key to seconds', () async {
      final settings = await _loadWith({'dashcam_segment_minutes': 2});
      expect(settings.segmentDurationSeconds, 120);
    });

    test('prefers the seconds key over the legacy minutes key', () async {
      final settings = await _loadWith({
        'dashcam_segment_minutes': 10,
        'dashcam_segment_duration_seconds': 15,
      });
      expect(settings.segmentDurationSeconds, 15);
    });

    test('clamps or snaps out-of-range values', () async {
      final settings = await _loadWith({
        'recording_resolution_p': 900,
        'recording_fps': 240,
        'video_bitrate_mbps': 50,
        'speed_refresh_ms': 5,
        'dashcam_segment_duration_seconds': 45,
        'dashcam_loop_segment_count': 7,
        'incident_sensitivity': 'extreme',
      });

      expect(settings.recordingResolution, 1080);
      expect(settings.recordingFps, 60);
      expect(settings.videoBitrateMbps, 8);
      expect(settings.speedRefreshMs, 100);
      expect(settings.segmentDurationSeconds, 300);
      expect(settings.loopSegmentCount, 24);
      expect(settings.incidentSensitivity, IncidentSensitivity.medium);
    });

    test('clamps a low FPS and a slow refresh interval', () async {
      final settings = await _loadWith({
        'recording_fps': 10,
        'speed_refresh_ms': 5000,
      });
      expect(settings.recordingFps, 24);
      expect(settings.speedRefreshMs, 1000);
    });

    test('derives the preset id from the values, not the stored id', () async {
      final matching = await _loadWith({
        'recording_quality_profile_id': 'custom',
        'recording_resolution_p': 720,
        'recording_fps': 30,
        'video_bitrate_mbps': 4,
      });
      expect(matching.qualityProfileId, '720p_30_4');

      final custom = await _loadWith({
        'recording_quality_profile_id': '720p_30_4',
        'recording_resolution_p': 720,
        'recording_fps': 60,
        'video_bitrate_mbps': 4,
      });
      expect(
        custom.qualityProfileId,
        AppSettingsProvider.customQualityProfileId,
      );
    });

    test('runs only once', () async {
      final settings = await _loadWith({'recording_fps': 60});
      SharedPreferences.setMockInitialValues({'recording_fps': 24});
      await settings.load();
      expect(settings.recordingFps, 60);
    });
  });

  group('updates', () {
    test('a quality preset persists the four video keys', () async {
      final settings = await _loadWith({});
      var notifications = 0;
      settings.addListener(() => notifications++);

      await settings.updateRecordingQualityProfile('2160p_24_16');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('recording_resolution_p'), 2160);
      expect(prefs.getInt('recording_fps'), 24);
      expect(prefs.getInt('video_bitrate_mbps'), 16);
      expect(prefs.getString('recording_quality_profile_id'), '2160p_24_16');
      expect(notifications, 1);
    });

    test('an unknown preset id is ignored', () async {
      final settings = await _loadWith({});
      await settings.updateRecordingQualityProfile('nope');
      expect(settings.qualityProfileId, '1080p_30_8');
    });

    test('a segment length also writes the legacy minutes key', () async {
      final settings = await _loadWith({});
      await settings.updateSegmentDurationSeconds(90);
      expect(settings.segmentDurationSeconds, 300, reason: 'not an option');

      await settings.updateSegmentDurationSeconds(30);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('dashcam_segment_duration_seconds'), 30);
      expect(prefs.getInt('dashcam_segment_minutes'), 1);
    });

    test('changing one video value re-derives the preset id', () async {
      final settings = await _loadWith({});
      await settings.updateRecordingFps(60);
      expect(
        settings.qualityProfileId,
        AppSettingsProvider.customQualityProfileId,
      );
      await settings.updateVideoBitrateMbps(12);
      expect(settings.qualityProfileId, '1080p_60_12');
    });

    test('the camera name is trimmed and persisted', () async {
      final settings = await _loadWith({});
      await settings.updateSelectedCameraName('  back  ');
      final prefs = await SharedPreferences.getInstance();
      expect(settings.selectedCameraName, 'back');
      expect(prefs.getString('camera_name'), 'back');
    });
  });

  group('static helpers', () {
    test('every resolution option round-trips through the camera mapping', () {
      for (final resolution in AppSettingsProvider.resolutionOptions) {
        expect(
          CameraProvider.resolutionForPreset(
            CameraProvider.presetForResolution(resolution),
          ),
          resolution,
          reason: '${resolution}p',
        );
      }
    });

    test('labels', () {
      expect(AppSettingsProvider.resolutionLabel(720), '720p');
      expect(AppSettingsProvider.resolutionLabel(2160), '4K (2160p)');
      expect(
        AppSettingsProvider.segmentDurationLabel(15),
        '15 sec per segment',
      );
      expect(
        AppSettingsProvider.segmentDurationLabel(120),
        '2 min per segment',
      );
      expect(
        AppSettingsProvider.segmentDurationLabel(90),
        '1 min 30 sec per segment',
      );
      expect(
        AppSettingsProvider.profileById('1080p_30_8')?.label,
        '1080p / 30 FPS / 8 Mbps',
      );
    });

    test('every option of a list snaps to itself', () async {
      for (final seconds in AppSettingsProvider.segmentDurationOptionsSeconds) {
        final settings = await _loadWith({
          'dashcam_segment_duration_seconds': seconds,
        });
        expect(settings.segmentDurationSeconds, seconds);
      }
    });
  });
}
