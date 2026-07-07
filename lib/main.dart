// lib/main.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'core/providers/app_settings_provider.dart';
import 'features/camera/providers/camera_provider.dart';
import 'features/telemetry/providers/telemetry_provider.dart';
import 'features/recording/recording_screen.dart';
import 'dart:async';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set up error handling for Flutter errors
  FlutterError.onError = (FlutterErrorDetails details) {
    if (kDebugMode) {
      debugPrint('Flutter Error: ${details.exception}');
      debugPrint('Stack trace: ${details.stack}');
    }
    // Errors are logged but app continues running
  };

  // Set up zone error handling
  runZonedGuarded(
    () async {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);

      runApp(const MotoCamApp());
    },
    (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Zone Error: $error');
        debugPrint('Stack trace: $stackTrace');
      }
      // Errors are logged but app continues running
    },
  );
}

class MotoCamApp extends StatelessWidget {
  const MotoCamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSettingsProvider()..load()),
        ChangeNotifierProvider(
            create: (_) => CameraProvider(enableDebugLogging: kDebugMode)),
        ChangeNotifierProvider(create: (_) => TelemetryProvider()),
      ],
      child: MaterialApp(
        title: 'MotoCam',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.blue,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const RecordingScreen(),
      ),
    );
  }
}
