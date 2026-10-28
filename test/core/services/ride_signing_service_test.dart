import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/services/ride_signing_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_signing_key.dart';

const _channel = MethodChannel(RideSigningService.channelName);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final phone = TestSigningKey.generate(1);
  final other = TestSigningKey.generate(2);
  final payloadHash = 'ab' * 32;

  tearDown(() {
    messenger().setMockMethodCallHandler(_channel, null);
  });

  group('RideSigningService', () {
    test('reads the signing key and signs a payload hash', () async {
      final calls = <MethodCall>[];
      messenger().setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        if (call.method == 'getSigningKey') {
          return <String, Object?>{
            'keyId': phone.keyId,
            'publicKey': phone.publicKeyBase64,
          };
        }
        final arguments = call.arguments as Map<Object?, Object?>;
        return phone.sign(arguments['payloadHash'] as String).toJson();
      });
      final service = RideSigningService();

      final key = await service.getSigningKey();
      expect(key!.publicKey, phone.publicKeyBase64);
      expect(key.keyId, phone.keyId);

      final signature = await service.signPayloadHash(payloadHash);
      expect(signature!.alg, 'ES256');
      expect(signature.publicKey, phone.publicKeyBase64);
      expect(calls.last.method, 'signPayloadHash');
      expect(calls.last.arguments, <String, Object?>{
        'payloadHash': payloadHash,
      });
    });

    test('returns null without the plugin (iOS, tests)', () async {
      final service = RideSigningService();
      expect(await service.getSigningKey(), isNull);
      expect(await service.signPayloadHash(payloadHash), isNull);
    });

    test('returns null on a PlatformException', () async {
      messenger().setMockMethodCallHandler(_channel, (call) async {
        throw PlatformException(code: 'SIGNING_FAILED', message: 'keystore');
      });
      final service = RideSigningService();
      expect(await service.getSigningKey(), isNull);
      expect(await service.signPayloadHash(payloadHash), isNull);
    });

    test('returns null on a malformed reply', () async {
      messenger().setMockMethodCallHandler(_channel, (call) async {
        return <String, Object?>{'keyId': 1, 'publicKey': 'not base64!'};
      });
      final service = RideSigningService();
      expect(await service.getSigningKey(), isNull);
      expect(await service.signPayloadHash(payloadHash), isNull);
    });

    test('returns null after the timeout', () async {
      messenger().setMockMethodCallHandler(_channel, (call) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        return phone.sign(payloadHash).toJson();
      });
      final service = RideSigningService(
        timeout: const Duration(milliseconds: 50),
      );
      expect(await service.signPayloadHash(payloadHash), isNull);
      expect(await service.getSigningKey(), isNull);
    });

    test('the session key is read once and a failure is retried', () async {
      var calls = 0;
      var fail = true;
      messenger().setMockMethodCallHandler(_channel, (call) async {
        calls++;
        if (fail) {
          throw PlatformException(code: 'KEY_UNAVAILABLE');
        }
        return <String, Object?>{
          'keyId': phone.keyId,
          'publicKey': phone.publicKeyBase64,
        };
      });
      final service = RideSigningService();
      expect(await service.sessionSigningKey(), isNull);
      fail = false;
      expect(
        (await service.sessionSigningKey())!.publicKey,
        phone.publicKeyBase64,
      );
      expect(
        (await service.sessionSigningKey())!.publicKey,
        phone.publicKeyBase64,
      );
      expect(calls, 2);
    });
  });

  group('SignedRideRegistry', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('keeps ids for the current key only', () async {
      final registry = SignedRideRegistry();
      await registry.add(phone.publicKeyBase64, 'ride-1');
      await registry.add(phone.publicKeyBase64, 'ride-2');
      expect(await registry.idsFor(phone.publicKeyBase64), <String>{
        'ride-1',
        'ride-2',
      });
      // Another key (a reinstall or a new key) sees an empty registry.
      expect(await registry.idsFor(other.publicKeyBase64), isEmpty);

      await registry.remove('ride-1');
      expect(await registry.idsFor(phone.publicKeyBase64), <String>{'ride-2'});

      // A ride signed with a new key replaces the old key's list.
      await registry.add(other.publicKeyBase64, 'ride-3');
      expect(await registry.idsFor(other.publicKeyBase64), <String>{'ride-3'});
      expect(await registry.idsFor(phone.publicKeyBase64), isEmpty);

      final prefs = await SharedPreferences.getInstance();
      final stored =
          jsonDecode(prefs.getString(SignedRideRegistry.prefsKey)!) as Map;
      expect(stored['rideSessionIds'], <String>['ride-3']);
      expect(stored['keyFingerprint'], hasLength(64));
    });

    test('a corrupt value reads as empty', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SignedRideRegistry.prefsKey: '{not json',
      });
      final registry = SignedRideRegistry();
      expect(await registry.idsFor(phone.publicKeyBase64), isEmpty);
      await registry.add(phone.publicKeyBase64, 'ride-1');
      expect(await registry.idsFor(phone.publicKeyBase64), <String>{'ride-1'});
    });
  });

  group('loadRideSignerContext', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('carries the key and its registered rides', () async {
      messenger().setMockMethodCallHandler(_channel, (call) async {
        return <String, Object?>{
          'keyId': phone.keyId,
          'publicKey': phone.publicKeyBase64,
        };
      });
      final registry = SignedRideRegistry();
      await registry.add(phone.publicKeyBase64, 'ride-1');
      final context = await loadRideSignerContext(
        service: RideSigningService(),
        registry: registry,
      );
      expect(context.thisDevicePublicKey, phone.publicKeyBase64);
      expect(context.signedRideIds, <String>{'ride-1'});
    });

    test('an unknown key gives no registry', () async {
      final registry = SignedRideRegistry();
      await registry.add(phone.publicKeyBase64, 'ride-1');
      final context = await loadRideSignerContext(
        service: RideSigningService(),
        registry: registry,
      );
      expect(context.thisDevicePublicKey, isNull);
      expect(context.signedRideIds, isEmpty);
    });
  });
}
