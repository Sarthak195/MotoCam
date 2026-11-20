// lib/main.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'core/diagnostics/diagnostics.dart';
import 'core/providers/app_settings_provider.dart';
import 'features/camera/providers/camera_provider.dart';
import 'features/map/map_licence.dart';
import 'features/telemetry/providers/telemetry_provider.dart';
import 'features/recording/recording_screen.dart';

// Flushes the diagnostic log when the app is paused; kept for the app's
// lifetime.
// ignore: unused_element
AppLifecycleListener? _diagnosticsPauseListener;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Release builds: silence debugPrint, which ride paths and flutter_map's
  // failed-tile URLs (which reveal the ride area) go through. Errors are
  // still logged below with debugPrintSynchronously, which this does not
  // affect.
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }

  // Errors (framework and uncaught asynchronous) go to the persistent
  // diagnostic log (<filesDir>/diagnostics/app.log, shared from the
  // recording settings sheet) and, as before, to the console: Flutter's
  // default reporting in debug and profile, debugPrintSynchronously in
  // release. Errors reported as silent are never logged; see
  // installErrorHooks.
  final diagnostics = DiagnosticLog(
    resolveDirectory: getApplicationSupportDirectory,
  );
  DiagnosticLog.instance = diagnostics;
  installErrorHooks(diagnostics);
  _diagnosticsPauseListener = flushDiagnosticsOnPause(diagnostics);
  unawaited(startDiagnosticSession(diagnostics, const DiagnosticsChannel()));
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
