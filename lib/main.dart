// lib/main.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'features/camera/providers/camera_provider.dart';
import 'features/telemetry/providers/telemetry_provider.dart';
import 'features/recording/recording_screen.dart';
import 'dart:async';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Set up error handling for Flutter errors
  FlutterError.onError = (FlutterErrorDetails details) {
    debugPrint('❌ Flutter Error: ${details.exception}');
    debugPrint('Stack trace: ${details.stack}');
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
      debugPrint('❌ Zone Error: $error');
      debugPrint('Stack trace: $stackTrace');
      // Errors are logged but app continues running
    },
  );
}

class MotoCamApp extends StatelessWidget {
  const MotoCamApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => CameraProvider(enableDebugLogging: true)),
        ChangeNotifierProvider(create: (_) => TelemetryProvider()),
      ],
      child: MaterialApp(
        title: 'MotoCam',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          primarySwatch: Colors.blue,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const RecordingScreen(),
      ),
    );
  }
}