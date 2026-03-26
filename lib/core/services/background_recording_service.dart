import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

enum BackgroundRecordingEvent { stopRequested }

class BackgroundRecordingService {
  BackgroundRecordingService._();

  static final BackgroundRecordingService instance =
      BackgroundRecordingService._();

  static const MethodChannel _channel =
      MethodChannel('com.example.motocam/background_recording');

  final StreamController<BackgroundRecordingEvent> _eventsController =
      StreamController<BackgroundRecordingEvent>.broadcast();

  bool _initialized = false;
  bool _batteryOptimizationRequestAttempted = false;

  Stream<BackgroundRecordingEvent> get events => _eventsController.stream;

  Future<void> initialize() async {
    if (!Platform.isAndroid) {
      return;
    }

    if (_initialized) {
      return;
    }

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onStopRequested':
          _eventsController.add(BackgroundRecordingEvent.stopRequested);
          break;
      }
      return null;
    });

    _initialized = true;
  }

  Future<void> startForegroundRecording({required Duration elapsed}) async {
    if (!Platform.isAndroid) {
      return;
    }
    await _ensureBatteryOptimizationExemption();
    await _channel.invokeMethod<void>('startForegroundRecording', {
      'elapsedMs': elapsed.inMilliseconds,
    });
  }

  Future<void> _ensureBatteryOptimizationExemption() async {
    if (_batteryOptimizationRequestAttempted) {
      return;
    }

    _batteryOptimizationRequestAttempted = true;
    try {
      final isIgnoring =
          await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
              true;
      if (isIgnoring) {
        return;
      }

      await _channel.invokeMethod<void>('requestIgnoreBatteryOptimizations');
    } catch (_) {
      // Best effort only: recording still proceeds with foreground service + wake lock.
    }
  }

  Future<void> updateForegroundRecording({required Duration elapsed}) async {
    if (!Platform.isAndroid) {
      return;
    }
    await _channel.invokeMethod<void>('updateForegroundRecording', {
      'elapsedMs': elapsed.inMilliseconds,
    });
  }

  Future<void> stopForegroundRecording() async {
    if (!Platform.isAndroid) {
      return;
    }
    await _channel.invokeMethod<void>('stopForegroundRecording');
  }

  void dispose() {
    _eventsController.close();
  }
}
