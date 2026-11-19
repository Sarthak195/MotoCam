// lib/main.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'core/providers/app_settings_provider.dart';
import 'core/theme/app_theme.dart';
import 'features/camera/providers/camera_provider.dart';
import 'features/map/map_licence.dart';
import 'features/telemetry/providers/telemetry_provider.dart';
import 'features/recording/recording_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Release builds: silence debugPrint, which ride paths and flutter_map's
  // failed-tile URLs (which reveal the ride area) go through. Errors are
  // still logged below with debugPrintSynchronously, which this does not
  // affect.
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }

  // Framework errors (build, layout, paint, gesture callbacks): keep
  // Flutter's default reporting in debug and profile; in release, where
  // that reporting goes through the silenced debugPrint, log the error and
  // its stack directly. Like the default, release skips errors reported as
  // silent (for example failed image loads, whose message can contain a
  // file path or a map-tile URL).
  FlutterError.onError = (FlutterErrorDetails details) {
    if (kReleaseMode) {
      if (details.silent) {
        return;
      }
      debugPrintSynchronously('Flutter error: ${details.exceptionAsString()}');
      debugPrintSynchronously('Stack trace: ${details.stack}');
      return;
    }
    FlutterError.presentError(details);
  };

  // Uncaught asynchronous errors: log them in every build mode and keep the
  // app running.
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrintSynchronously('Uncaught error: $error');
    debugPrintSynchronously('Stack trace: $stack');
    return true;
  };

  // Android 16 ignores this lock on large screens (smallest width >= 600dp)
  // for apps targeting API 36 unless the manifest opts out.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  registerMapLicence();
  runApp(const MotoCamApp());
}

/// The root widget: creates the app-wide providers and the [MaterialApp].
class MotoCamApp extends StatelessWidget {
  /// Creates the root widget.
  const MotoCamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) {
            final settings = AppSettingsProvider();
            unawaited(settings.load());
            return settings;
          },
        ),
        ChangeNotifierProvider(
          create: (_) => CameraProvider(enableDebugLogging: kDebugMode),
        ),
        ChangeNotifierProvider(create: (_) => TelemetryProvider()),
      ],
      child: MaterialApp(
        title: 'MotoCam',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: const RecordingScreen(),
      ),
    );
  }
}
