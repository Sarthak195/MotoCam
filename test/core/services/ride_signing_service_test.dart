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

    test('returns null without the plugin (tests)', () async {
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

    test('keeps segment file names per ride', () async {
      final registry = SignedRideRegistry();
      await registry.add(
        phone.publicKeyBase64,
        'ride-1',
        segmentFileNames: const <String>['segment_1.mp4', 'segment_2.mp4'],
      );
      await registry.add(phone.publicKeyBase64, 'ride-2');
      var registered = await registry.registrationsFor(phone.publicKeyBase64);
      expect(registered.rideSessionIds, <String>{'ride-1', 'ride-2'});
      expect(registered.segmentFileNames, <String>{
        'segment_1.mp4',
        'segment_2.mp4',
      });
      expect(
        (await registry.registrationsFor(
          other.publicKeyBase64,
        )).segmentFileNames,
        isEmpty,
      );

      // Deleting a file of another name that carries the id (a copy or a
      // decoy) leaves the ride registered; its own name removes it.
      await registry.remove(
        'ride-1',
        telemetryFileName: 'ride_copy.telemetry.json',
      );
      registered = await registry.registrationsFor(phone.publicKeyBase64);
      expect(registered.rideSessionIds, contains('ride-1'));
      await registry.remove(
        'ride-1',
        telemetryFileName: 'ride_ride-1.telemetry.json',
      );
      registered = await registry.registrationsFor(phone.publicKeyBase64);
      expect(registered.rideSessionIds, <String>{'ride-2'});
      expect(registered.segmentFileNames, isEmpty);
    });

    test('a value without segment file names still reads', () async {
      final registry = SignedRideRegistry();
      await registry.add(phone.publicKeyBase64, 'ride-1');
      final prefs = await SharedPreferences.getInstance();
      final stored =
          jsonDecode(prefs.getString(SignedRideRegistry.prefsKey)!) as Map;
      expect(stored.containsKey('segmentFileNames'), isFalse);
      SharedPreferences.setMockInitialValues(<String, Object>{
        SignedRideRegistry.prefsKey: jsonEncode(<String, Object?>{
          'keyFingerprint': stored['keyFingerprint'],
          'rideSessionIds': <String>['ride-1'],
          'segmentFileNames': <String, Object?>{
            'ride-1': <Object?>['segment_1.mp4', 7],
            'ride-9': 'not a list',
          },
        }),
      });
      final registered = await SignedRideRegistry().registrationsFor(
        phone.publicKeyBase64,
      );
      expect(registered.rideSessionIds, <String>{'ride-1'});
      expect(registered.segmentFileNames, <String>{'segment_1.mp4'});
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
      await registry.add(
        phone.publicKeyBase64,
        'ride/1',
        segmentFileNames: const <String>['segment_1.mp4'],
      );
      final context = await loadRideSignerContext(
        service: RideSigningService(),
        registry: registry,
      );
      expect(context.thisDevicePublicKey, phone.publicKeyBase64);
      expect(context.signedRideIds, <String>{'ride/1'});
      expect(context.signedTelemetryFileNames, <String>{
        'ride_ride_1.telemetry.json',
      });
      expect(context.signedSegmentFileNames, <String>{'segment_1.mp4'});
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
