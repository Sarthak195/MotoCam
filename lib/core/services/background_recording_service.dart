import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Events broadcast by [BackgroundRecordingService] to the Flutter side.
enum BackgroundRecordingEvent {
  /// The rider tapped Stop in the recording notification.
  stopRequested,
}

/// Flutter-side bridge for the native Android foreground-service that keeps
/// recording alive when the app is backgrounded or the screen is off.
///
/// This is a singleton accessed via [instance]. Call [initialize] early in
/// the app lifecycle to register the method-channel handler. All calls are
/// no-ops on platforms other than Android.
class BackgroundRecordingService {
  BackgroundRecordingService._();

  /// The app-wide instance.
  static final BackgroundRecordingService instance =
      BackgroundRecordingService._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.motocam/background_recording',
  );

  /// SharedPreferences key recording that the battery-optimisation
  /// exemption has been offered once.
  static const String batteryOptimizationOfferedKey =
      'battery_optimization_exemption_offered';

  final StreamController<BackgroundRecordingEvent> _eventsController =
      StreamController<BackgroundRecordingEvent>.broadcast();

  bool _initialized = false;

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  /// Events from the native service, such as the notification's Stop action.
  Stream<BackgroundRecordingEvent> get events => _eventsController.stream;

  /// Registers the method-channel handler. Safe to call more than once.
  Future<void> initialize() async {
    if (!_isAndroid) {
      return;
    }

    if (_initialized) {
      return;
    }

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onStopRequested':
          if (_eventsController.hasListener) {
            _eventsController.add(BackgroundRecordingEvent.stopRequested);
          } else {
            // Nobody can run the stop flow, so do not leave the foreground
            // service and its notification behind.
            await stopForegroundRecording();
          }
          break;
      }
      return null;
    });

    _initialized = true;
  }

  /// Starts the foreground service with the recording notification.
  ///
  /// Returns false when the native side reports that the service could not
  /// be started (for example no foreground-service type is permitted, or the
  /// app is not in the foreground). Never asks for the battery-optimisation
  /// exemption.
  Future<bool> startForegroundRecording({required Duration elapsed}) async {
    if (!_isAndroid) {
      return true;
    }
    final started = await _channel.invokeMethod<bool>(
      'startForegroundRecording',
      {'elapsedMs': elapsed.inMilliseconds},
    );
    return started ?? true;
  }

  /// Whether the OS currently exempts the app from battery optimisations.
  ///
  /// Returns true off Android and when the native call fails.
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!_isAndroid) {
      return true;
    }
    await initialize();
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          true;
    } catch (_) {
      return true;
    }
  }

  /// Opens the system screen for the battery-optimisation exemption.
  ///
  /// The result only says whether the screen was launched, not what the
  /// user chose; re-check [isIgnoringBatteryOptimizations] once the app has
  /// resumed. Only call this after the rider accepted an explanatory prompt
  /// (see [shouldOfferBatteryOptimizationExemption]).
  Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!_isAndroid) {
      return true;
    }
    await initialize();
    try {
      return await _channel.invokeMethod<bool>(
            'requestIgnoreBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Whether the battery-optimisation exemption was already offered once.
  Future<bool> hasOfferedBatteryOptimizationExemption() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(batteryOptimizationOfferedKey) ?? false;
  }

  /// Persists that the exemption was offered, whatever the rider answered,
  /// so it is never offered again.
  Future<void> markBatteryOptimizationExemptionOffered() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(batteryOptimizationOfferedKey, true);
  }

  /// Whether to show the one-time explanatory prompt for the exemption:
  /// true only on Android, when the app is not exempt and the prompt has
  /// never been shown.
  Future<bool> shouldOfferBatteryOptimizationExemption() async {
    if (!_isAndroid) {
      return false;
    }
    if (await hasOfferedBatteryOptimizationExemption()) {
      return false;
    }
    return !(await isIgnoringBatteryOptimizations());
  }

  /// Updates the elapsed time shown in the recording notification.
  ///
  /// Called fire-and-forget once per second, so platform errors are
  /// swallowed instead of surfacing as unhandled async errors.
  Future<void> updateForegroundRecording({required Duration elapsed}) async {
    if (!_isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('updateForegroundRecording', {
        'elapsedMs': elapsed.inMilliseconds,
      });
    } on PlatformException catch (error) {
      debugPrint('[MotoCam] updateForegroundRecording failed: $error');
    }
  }

  /// Asks the activity to keep the screen on while a recording is active.
  ///
  /// The native side applies the window flag only between
  /// [startForegroundRecording] and [stopForegroundRecording] (the flag is
  /// cleared there and when the activity is destroyed), so call this after
  /// the start. Best effort: platform errors are logged, not thrown. A
  /// no-op off Android.
  Future<void> setKeepScreenOn({required bool enabled}) async {
    if (!_isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setKeepScreenOn', {
        'enabled': enabled,
      });
    } on PlatformException catch (error) {
      debugPrint('[MotoCam] setKeepScreenOn failed: $error');
    } on MissingPluginException catch (error) {
      debugPrint('[MotoCam] setKeepScreenOn unavailable: $error');
    }
  }

  /// Stops the foreground service and removes its notification. On
  /// Android this also clears the keep-screen-on flag and releases the
  /// activity's camera lifecycle hold.
  Future<void> stopForegroundRecording() async {
    if (!_isAndroid) {
      return;
    }
    await _channel.invokeMethod<void>('stopForegroundRecording');
  }
}
