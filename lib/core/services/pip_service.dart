// lib/core/services/pip_service.dart

import 'dart:async';

import 'package:flutter/services.dart';

/// Flutter-side bridge for Android Picture-in-Picture mode.
///
/// This singleton listens for PiP mode-change callbacks from the native
/// activity and exposes them as a [Stream<bool>]. Call [initialize] once
/// during app startup to wire the method-channel handler.
class PipService {
  PipService._();

  /// The app-wide instance.
  static final PipService instance = PipService._();

  static const MethodChannel _platform = MethodChannel(
    'com.example.motocam/pip',
  );

  final StreamController<bool> _pipModeController =
      StreamController<bool>.broadcast();

  bool _initialized = false;
  bool _isInPipMode = false;

  /// Emits true when the activity enters PiP and false when it leaves.
  Stream<bool> get pipModeStream => _pipModeController.stream;

  /// The last PiP state reported by the native activity.
  bool get isInPipMode => _isInPipMode;

  /// Registers the method-channel handler. Safe to call more than once.
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    _platform.setMethodCallHandler((call) async {
      if (call.method == 'onPipModeChanged') {
        final inPip = call.arguments == true;
        _isInPipMode = inPip;
        _pipModeController.add(inPip);
      }
      return null;
    });

    _initialized = true;
  }

  /// Asks the activity to enter PiP. Returns false when PiP is unsupported,
  /// refused, or the platform has no handler.
  static Future<bool> enterPipMode() async {
    return instance._enterPipMode();
  }

  /// Sets the shape of the PiP window, manual or automatic, to the ride's
  /// capture orientation: 16:9 when [landscape], else 9:16 (the default).
  /// Also reshapes a window already open. Errors (no handler) are ignored.
  static Future<void> setAspectRatio({required bool landscape}) async {
    try {
      await _platform.invokeMethod<void>('setPipAspectRatio', {
        'landscape': landscape,
      });
    } catch (_) {
      // PiP keeps its last shape.
    }
  }

  Future<bool> _enterPipMode() async {
    try {
      final bool result = await _platform.invokeMethod('enterPipMode');
      return result;
    } catch (_) {
      return false;
    }
  }
}
