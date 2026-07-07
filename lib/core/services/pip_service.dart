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

  static final PipService instance = PipService._();

  static const MethodChannel _platform = MethodChannel('com.example.motocam/pip');

  final StreamController<bool> _pipModeController =
      StreamController<bool>.broadcast();

  bool _initialized = false;
  bool _isInPipMode = false;

  Stream<bool> get pipModeStream => _pipModeController.stream;
  bool get isInPipMode => _isInPipMode;

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

  static Future<bool> isPipSupported() async {
    return instance._isPipSupported();
  }

  static Future<bool> enterPipMode() async {
    return instance._enterPipMode();
  }

  Future<bool> _isPipSupported() async {
    try {
      final bool result = await _platform.invokeMethod('isPipSupported');
      return result;
    } catch (_) {
      return false;
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

  void dispose() {
    _pipModeController.close();
  }
}