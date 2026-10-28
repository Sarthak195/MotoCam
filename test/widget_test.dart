// Smoke test for the app root: providers, theme and first screen.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motocam/core/providers/app_settings_provider.dart';
import 'package:motocam/features/recording/recording_screen.dart';
import 'package:motocam/main.dart';

const _mockedChannels = [
  MethodChannel('flutter.baseflow.com/permissions/methods'),
  MethodChannel('com.example.motocam/background_recording'),
  MethodChannel('com.example.motocam/device_status'),
  MethodChannel('com.example.motocam/pip'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'recording_resolution_p': 720,
      'recording_fps': 30,
      'video_bitrate_mbps': 4,
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in _mockedChannels) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'checkPermissionStatus':
            return 1; // granted
          case 'requestPermissions':
            return {
              for (final value in (call.arguments as List).cast<int>())
                value: 1,
            };
          case 'isIgnoringBatteryOptimizations':
            return true;
          case 'getBatteryStatus':
            return {'batteryLevelPercent': 80};
        }
        return null;
      });
    }
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in _mockedChannels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('builds the dark M3 app with the recording screen and loads '
      'the stored settings', (WidgetTester tester) async {
    await tester.pumpWidget(const MotoCamApp());
    await tester.pump(const Duration(milliseconds: 100));

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, 'MotoCam');
    expect(app.theme?.brightness, Brightness.dark);
    expect(app.theme?.useMaterial3, isTrue);
    expect(find.byType(RecordingScreen), findsOneWidget);

    final settings = Provider.of<AppSettingsProvider>(
      tester.element(find.byType(RecordingScreen)),
      listen: false,
    );
    expect(settings.isLoaded, isTrue);
    expect(settings.recordingResolution, 720);
    expect(settings.qualityProfileId, '720p_30_4');

    // Dispose the tree so periodic timers and subscriptions are released.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
