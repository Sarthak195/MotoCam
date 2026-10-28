import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/services/pip_service.dart';

const _channel = MethodChannel('com.example.motocam/pip');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> sendFromNative(Object? arguments) async {
    final data = const StandardMethodCodec().encodeMethodCall(
      MethodCall('onPipModeChanged', arguments),
    );
    await messenger().handlePlatformMessage(_channel.name, data, (_) {});
  }

  tearDown(() {
    messenger().setMockMethodCallHandler(_channel, null);
  });

  test('publishes PiP mode changes from the native activity', () async {
    final service = PipService.instance;
    await service.initialize();
    final modes = <bool>[];
    final subscription = service.pipModeStream.listen(modes.add);

    await sendFromNative(true);
    expect(service.isInPipMode, isTrue);
    await sendFromNative(false);
    await Future<void>.delayed(Duration.zero);

    expect(modes, [true, false]);
    expect(service.isInPipMode, isFalse);
    await subscription.cancel();
  });

  test('enterPipMode returns the native answer', () async {
    messenger().setMockMethodCallHandler(_channel, (call) async {
      expect(call.method, 'enterPipMode');
      return true;
    });

    expect(await PipService.enterPipMode(), isTrue);
  });

  test('enterPipMode returns false when the platform has no handler', () async {
    expect(await PipService.enterPipMode(), isFalse);
  });

  test(
    'dispose can be called twice and later mode changes are ignored',
    () async {
      // Runs last: it closes the singleton's stream.
      final service = PipService.instance;
      service.dispose();
      expect(service.dispose, returnsNormally);

      await sendFromNative(true);
      expect(service.isInPipMode, isTrue);
    },
  );
}
