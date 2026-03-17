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
  
  // Disable flutter error handling/crash detection
  FlutterError.onError = (FlutterErrorDetails details) {
    // Silently ignore all Flutter errors
  };
  
  // Disable zone errors
  runZonedGuarded(
    () async {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      
      runApp(const MotoCamApp());
    },
    (error, stackTrace) {
      // Silently ignore all zone errors
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