import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/services/background_recording_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('com.example.motocam/background_recording');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = BackgroundRecordingService.instance;
  final calls = <String>[];
  var ignoring = false;
  Object? startResult = true;
  var throwOnUpdate = false;

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Delivers a native -> Dart call on the channel, as MainActivity does.
  Future<void> sendFromNative(String method) async {
    final data = const StandardMethodCodec().encodeMethodCall(
      MethodCall(method),
    );
    await messenger().handlePlatformMessage(_channel.name, data, (_) {});
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    ignoring = false;
    startResult = true;
    throwOnUpdate = false;
    messenger().setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'isIgnoringBatteryOptimizations':
          return ignoring;
        case 'requestIgnoreBatteryOptimizations':
          return true;
        case 'startForegroundRecording':
          return startResult;
        case 'updateForegroundRecording':
          if (throwOnUpdate) {
            throw PlatformException(code: 'ILLEGAL_STATE');
          }
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger().setMockMethodCallHandler(_channel, null);
  });

  group('battery-optimisation offer', () {
    test('is offered once while the app is not exempt', () async {
      expect(await service.shouldOfferBatteryOptimizationExemption(), isTrue);

      await service.markBatteryOptimizationExemptionOffered();

      expect(await service.hasOfferedBatteryOptimizationExemption(), isTrue);
      expect(await service.shouldOfferBatteryOptimizationExemption(), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool(BackgroundRecordingService.batteryOptimizationOfferedKey),
        isTrue,
      );
    });

    test('is not offered when the app is already exempt', () async {
      ignoring = true;
      expect(await service.shouldOfferBatteryOptimizationExemption(), isFalse);
    });

    test('is never offered off Android', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(await service.shouldOfferBatteryOptimizationExemption(), isFalse);
      expect(calls, isEmpty);
    });

    test('checking never launches the exemption request', () async {
      await service.shouldOfferBatteryOptimizationExemption();
      expect(calls, isNot(contains('requestIgnoreBatteryOptimizations')));
    });
  });

  group('foreground service', () {
    test('START does not ask for the battery exemption', () async {
      final started = await service.startForegroundRecording(
        elapsed: Duration.zero,
      );

      expect(started, isTrue);
      expect(calls, ['startForegroundRecording']);
    });

    test('START reports a native refusal', () async {
      startResult = false;
      expect(
        await service.startForegroundRecording(elapsed: Duration.zero),
        isFalse,
      );
    });

    test('setKeepScreenOn sends the enabled flag', () async {
      final arguments = <Object?>[];
      messenger().setMockMethodCallHandler(_channel, (call) async {
        calls.add(call.method);
        arguments.add(call.arguments);
        return null;
      });

      await service.setKeepScreenOn(enabled: true);
      await service.setKeepScreenOn(enabled: false);

      expect(calls, ['setKeepScreenOn', 'setKeepScreenOn']);
      expect(arguments, [
        {'enabled': true},
        {'enabled': false},
      ]);
    });

    test('setKeepScreenOn swallows platform errors', () async {
      messenger().setMockMethodCallHandler(_channel, (call) async {
        throw PlatformException(code: 'ERROR');
      });
      await expectLater(service.setKeepScreenOn(enabled: true), completes);

      // An older native side without the method.
      messenger().setMockMethodCallHandler(_channel, null);
      await expectLater(service.setKeepScreenOn(enabled: true), completes);
    });

    test('setKeepScreenOn is a no-op off Android', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await service.setKeepScreenOn(enabled: true);
      expect(calls, isEmpty);
    });

    test('releaseCameraHold calls the native side only', () async {
      await service.releaseCameraHold();
      expect(calls, ['releaseCameraHold']);
    });

    test('releaseCameraHold swallows platform errors', () async {
      messenger().setMockMethodCallHandler(_channel, (call) async {
        throw PlatformException(code: 'ERROR');
      });
      await expectLater(service.releaseCameraHold(), completes);

      // An older native side without the method.
      messenger().setMockMethodCallHandler(_channel, null);
      await expectLater(service.releaseCameraHold(), completes);
    });

    test('releaseCameraHold is a no-op off Android', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await service.releaseCameraHold();
      expect(calls, isEmpty);
    });

    test('a failing notification update does not throw', () async {
      throwOnUpdate = true;
      await expectLater(
        service.updateForegroundRecording(elapsed: const Duration(seconds: 3)),
        completes,
      );
    });
  });

  group('notification Stop', () {
    test('is forwarded to a listener', () async {
      await service.initialize();
      final events = <BackgroundRecordingEvent>[];
      final subscription = service.events.listen(events.add);

      await sendFromNative('onStopRequested');
      await Future<void>.delayed(Duration.zero);

      expect(events, [BackgroundRecordingEvent.stopRequested]);
      expect(calls, isNot(contains('stopForegroundRecording')));
      await subscription.cancel();
    });

    test('stops the service itself when nobody listens', () async {
      await service.initialize();

      await sendFromNative('onStopRequested');

      expect(calls, contains('stopForegroundRecording'));
    });
  });

  group('service stopped on its own', () {
    test('is forwarded as protectionLost', () async {
      await service.initialize();
      final events = <BackgroundRecordingEvent>[];
      final subscription = service.events.listen(events.add);

      await sendFromNative('onForegroundStopped');
      await Future<void>.delayed(Duration.zero);

      expect(events, [BackgroundRecordingEvent.protectionLost]);
      expect(calls, isEmpty);
      await subscription.cancel();
    });

    test('calls nothing back when nobody listens', () async {
      await service.initialize();

      await sendFromNative('onForegroundStopped');

      expect(calls, isEmpty);
    });
  });
}
