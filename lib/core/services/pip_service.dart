// lib/core/services/pip_service.dart

import 'package:flutter/services.dart';

class PipService {
  static const platform = MethodChannel('com.example.motocam/pip');

  static Future<bool> isPipSupported() async {
    try {
      final bool result = await platform.invokeMethod('isPipSupported');
      return result;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> enterPipMode() async {
    try {
      final bool result = await platform.invokeMethod('enterPipMode');
      return result;
    } catch (e) {
      return false;
    }
  }
}