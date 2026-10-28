import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/core/ride_file/ride_telemetry_codec.dart';

import '../../support/test_signing_key.dart';

void main() {
  // Two keys: "phone" stands in for this phone's Keystore key, "other" for
  // another phone or an earlier install.
  final phone = TestSigningKey.generate(1);
  final other = TestSigningKey.generate(2);

  final payload = <String, dynamic>{
    'schemaVersion': 3,
    'rideSessionId': 'ride-1',
    'sessionComplete': true,
    'distanceKm': 1.5,
    'segmentPaths': <String>['a.mp4'],
  };
  final generatedAt = DateTime.utc(2026, 1, 1);

  /// A version 3 ride JSON signed by [key] (unsigned when `null`).
  Map<String, dynamic> signedRide(
    TestSigningKey? key, {
    Map<String, dynamic>? fields,
    bool highS = false,
  }) {
    final body = <String, dynamic>{...payload, ...?fields};
    final envelope = buildIntegrityEnvelope(
      payload: body,
      segmentHashes: const <String, String>{'a.mp4': 'aaaa'},
      segmentCount: 1,
      generatedAt: generatedAt,
      envelopeVersion: signedIntegrityEnvelopeVersion,
    );
    final json = <String, dynamic>{...body, 'integrity': envelope};
    if (key == null) {
      return json;
    }
    return withRideSignature(
      json,
      key.sign(envelope['payloadHash'] as String, highS: highS),
    );
  }

  Future<RideIntegrityReport> check(Map<String, dynamic> json) =>
      checkRideIntegrity(
        json: json,
        schemaVersion: 3,
        sessionComplete: true,
        segments: const <RideIntegritySegment>[
          RideIntegritySegment(
            resolvedPath: 'a.mp4',
            declaredPath: 'a.mp4',
            isMissing: true,
          ),
        ],
      );

  Map<String, dynamic> signatureOf(Map<String, dynamic> json) =>
      (json['integrity'] as Map<String, dynamic>)['signature']
          as Map<String, dynamic>;

  /// [json] with its signature fields replaced by [changes].
  Map<String, dynamic> withSignatureFields(
    Map<String, dynamic> json,
    Map<String, Object?> changes,
  ) {
    final integrity = Map<String, dynamic>.from(json['integrity'] as Map);
    integrity['signature'] = <String, dynamic>{
      ...signatureOf(json),
      ...changes,
    };
    return <String, dynamic>{...json, 'integrity': integrity};
  }

  group('version 3 envelope', () {
    test('payload hash leaves out payloadHash and signature', () {
      final json = signedRide(phone);
      final integrity = json['integrity'] as Map<String, dynamic>;
      expect(integrity['envelopeVersion'], 3);
      expect(integrity['payloadHash'], computeRidePayloadHash(json));
      // Changing only the signature keeps the payload hash.
      final resigned = withRideSignature(
        json,
        other.sign(integrity['payloadHash'] as String),
      );
      expect(computeRidePayloadHash(resigned), integrity['payloadHash']);
      // Version 3 hashes differently from version 2 (envelopeVersion is
      // covered).
      final v2 = buildIntegrityEnvelope(
        payload: payload,
        segmentHashes: const <String, String>{'a.mp4': 'aaaa'},
        segmentCount: 1,
        generatedAt: generatedAt,
      );
      expect(v2['payloadHash'], isNot(integrity['payloadHash']));
    });

    test('a signed ride verifies and keeps its signature facts', () async {
      final report = await check(signedRide(phone));
      expect(report.status, RideIntegrityStatus.verified);
      expect(report.issues, isEmpty);
      expect(
        report.signature,
        RideSignatureFacts(signerPublicKey: phone.publicKeyBase64, valid: true),
      );
      // Without a context the signer is unknown, never this phone.
      expect(report.signedBy, RideSignedBy.unknownSigner);
    });

    test('a high-S signature is accepted', () async {
      final json = signedRide(phone, highS: true);
      final raw = phone.signRaw(
        (json['integrity'] as Map)['payloadHash'] as String,
        highS: true,
      );
      expect(raw.s > p256Order >> 1, isTrue);
      expect((await check(json)).status, RideIntegrityStatus.verified);
    });

    test('an edited field with the old hash is a payload mismatch', () async {
      final json = signedRide(phone)..['distanceKm'] = 99.0;
      final report = await check(json);
      expect(report.issues, <String>['payload-hash-mismatch']);
      // The signature still matches the stored hash, but the ride is
      // modified.
      expect(report.status, RideIntegrityStatus.modified);
    });

    test(
      'an edited field with a recomputed hash fails the signature',
      () async {
        final json = signedRide(phone)..['distanceKm'] = 99.0;
        (json['integrity'] as Map<String, dynamic>)['payloadHash'] =
            computeRidePayloadHash(json);
        final report = await check(json);
        expect(report.issues, <String>['signature-invalid']);
        expect(report.signature!.valid, isFalse);
        expect(report.signedBy, RideSignedBy.none);
      },
    );

    test('a tampered signature is invalid', () async {
      final json = signedRide(phone);
      final der = base64.decode(signatureOf(json)['sig'] as String);
      der[der.length - 1] ^= 0x01;
      final report = await check(
        withSignatureFields(json, <String, Object?>{'sig': base64.encode(der)}),
      );
      expect(report.issues, <String>['signature-invalid']);
    });

    test('a signature by another key with its own key is valid', () async {
      final report = await check(signedRide(other));
      expect(report.status, RideIntegrityStatus.verified);
      expect(report.signature!.signerPublicKey, other.publicKeyBase64);
    });

    test('a swapped public key fails the signature', () async {
      final json = withSignatureFields(signedRide(phone), <String, Object?>{
        'publicKey': other.publicKeyBase64,
        'keyId': other.keyId,
      });
      expect((await check(json)).issues, <String>['signature-invalid']);
    });

    test('a wrong keyId is a key mismatch', () async {
      final json = withSignatureFields(signedRide(phone), <String, Object?>{
        'keyId': other.keyId,
      });
      final report = await check(json);
      expect(report.issues, <String>['signature-key-mismatch']);
      expect(report.signature!.valid, isFalse);
    });

    test('a version 3 envelope without a signature is modified', () async {
      final report = await check(signedRide(null));
      expect(report.issues, <String>['missing-signature']);
      expect(report.signature, isNull);
    });

    test('an unknown algorithm is reported', () async {
      final json = withSignatureFields(signedRide(phone), <String, Object?>{
        'alg': 'RS256',
      });
      expect((await check(json)).issues, <String>[
        'unsupported-signature-alg:RS256',
      ]);
    });

    test('envelope versions above 3 are unsupported', () async {
      final json = signedRide(phone);
      (json['integrity'] as Map<String, dynamic>)['envelopeVersion'] = 4;
      final report = await check(json);
      expect(report.issues, contains('unsupported-integrity-version:4'));
      expect(maxIntegrityEnvelopeVersion, 3);
    });

    test('malformed signature values are issues, never exceptions', () async {
      final json = signedRide(phone);
      final valid = signatureOf(json);
      final validKey = base64.decode(valid['publicKey'] as String);
      final raw = phone.signRaw(
        (json['integrity'] as Map)['payloadHash'] as String,
      );
      final sigBody = <int>[...derInteger(raw.r), ...derInteger(raw.s)];
      final notOnCurve = List<int>.of(validKey)..[validKey.length - 1] ^= 1;
      final compressed = <int>[
        ...validKey.sublist(0, 26),
        0x02,
        ...validKey.sublist(27, 59),
      ];
      final malformed = <Map<String, Object?>>[
        <String, Object?>{'sig': 'not base64!'},
        <String, Object?>{'sig': '${valid['sig']}\n'},
        <String, Object?>{'sig': ''},
        <String, Object?>{'sig': 'A' * 5000},
        <String, Object?>{'sig': 42},
        <String, Object?>{'sig': null},
        // Trailing byte after the SEQUENCE.
        <String, Object?>{
          'sig': base64.encode(<int>[0x30, sigBody.length, ...sigBody, 0]),
        },
        // Long-form length.
        <String, Object?>{
          'sig': base64.encode(<int>[0x30, 0x81, sigBody.length, ...sigBody]),
        },
        // Non-minimal integer (extra leading zero).
        <String, Object?>{
          'sig': base64.encode(<int>[
            0x30,
            sigBody.length + 1,
            0x02,
            sigBody[1] + 1,
            0x00,
            ...sigBody.sublist(2),
          ]),
        },
        // Negative r.
        <String, Object?>{
          'sig': base64.encode(derSignatureWithRawR(<int>[0x80, 1], raw.s)),
        },
        // r and s out of range.
        <String, Object?>{
          'sig': base64.encode(derSignature(BigInt.zero, raw.s)),
        },
        <String, Object?>{'sig': base64.encode(derSignature(raw.r, p256Order))},
        <String, Object?>{
          'sig': base64.encode(<int>[0x30, 0x00]),
        },
        <String, Object?>{'publicKey': 'garbage'},
        <String, Object?>{'publicKey': base64.encode(notOnCurve)},
        <String, Object?>{'publicKey': base64.encode(compressed)},
        <String, Object?>{'publicKey': base64.encode(validKey.sublist(1))},
        <String, Object?>{'publicKey': null},
      ];
      for (final change in malformed) {
        final report = await check(withSignatureFields(json, change));
        expect(report.status, RideIntegrityStatus.modified, reason: '$change');
        expect(report.issues, contains('signature-invalid'), reason: '$change');
        expect(report.signedBy, RideSignedBy.none, reason: '$change');
      }

      // A signature that is not an object.
      final notObject = Map<String, dynamic>.from(json);
      notObject['integrity'] = <String, dynamic>{
        ...json['integrity'] as Map<String, dynamic>,
        'signature': 'sig',
      };
      expect((await check(notObject)).issues, <String>['signature-invalid']);
    });

    test('a signature in a version 2 envelope is not read', () async {
      final envelope = buildIntegrityEnvelope(
        payload: payload,
        segmentHashes: const <String, String>{'a.mp4': 'aaaa'},
        segmentCount: 1,
        generatedAt: generatedAt,
      );
      final json = <String, dynamic>{...payload, 'integrity': envelope};
      final report = await check(json);
      expect(report.status, RideIntegrityStatus.verified);
      expect(report.signature, isNull);
    });

    test('re-sealing drops the signature and can upgrade to version 3', () {
      final json = signedRide(phone);
      json['lockedSegmentPaths'] = <String>['a.mp4'];
      final v3Hash = resealIntegrityEnvelope(
        Map<String, dynamic>.of(json),
        envelopeVersion: signedIntegrityEnvelopeVersion,
      );
      final v2 = Map<String, dynamic>.of(json);
      final v2Hash = resealIntegrityEnvelope(v2);
      final envelope = v2['integrity'] as Map<String, dynamic>;
      expect(envelope.containsKey('signature'), isFalse);
      expect(envelope['envelopeVersion'], 2);
      expect(envelope['payloadHash'], v2Hash);
      expect(v3Hash, isNot(v2Hash));
    });
  });

  group('signer context', () {
    RideIntegrityReport withContext(
      RideIntegrityReport report, {
      String? deviceKey,
      Set<String> ids = const <String>{},
      String? rideSessionId = 'ride-1',
    }) => applySignerContext(
      report,
      rideSessionId: rideSessionId,
      context: RideSignerContext(
        thisDevicePublicKey: deviceKey,
        signedRideIds: ids,
      ),
    );

    test('a registered file or segment name is matched without the id', () {
      const context = RideSignerContext(
        thisDevicePublicKey: 'key',
        signedRideIds: <String>{'ride-1'},
        signedTelemetryFileNames: <String>{'ride_ride-1.telemetry.json'},
        signedSegmentFileNames: <String>{'segment_1.mp4'},
      );
      bool removed({
        String? id,
        String? telemetryFileName,
        List<String> segments = const <String>[],
        String? deviceKey = 'key',
      }) => resolveRideSigner(
        facts: null,
        rideSessionId: id,
        context: deviceKey == null
            ? RideSignerContext(
                thisDevicePublicKey: null,
                signedRideIds: context.signedRideIds,
                signedTelemetryFileNames: context.signedTelemetryFileNames,
                signedSegmentFileNames: context.signedSegmentFileNames,
              )
            : context,
        telemetryFileName: telemetryFileName,
        segmentFileNames: segments,
      ).signatureRemoved;

      expect(removed(id: 'ride-1'), isTrue);
      expect(
        removed(id: 'edited', telemetryFileName: 'ride_ride-1.telemetry.json'),
        isTrue,
      );
      expect(
        removed(
          telemetryFileName: 'ride_renamed.telemetry.json',
          segments: const <String>['segment_0.mp4', 'segment_1.mp4'],
        ),
        isTrue,
      );
      expect(
        removed(
          id: 'ride-2',
          telemetryFileName: 'ride_ride-2.telemetry.json',
          segments: const <String>['segment_2.mp4'],
        ),
        isFalse,
      );
      expect(
        removed(
          id: 'ride-1',
          telemetryFileName: 'ride_ride-1.telemetry.json',
          deviceKey: null,
        ),
        isFalse,
      );
    });

    test('a ride signed by this phone is thisDevice', () async {
      final report = withContext(
        await check(signedRide(phone)),
        deviceKey: phone.publicKeyBase64,
        ids: const <String>{'ride-1'},
      );
      expect(report.signedBy, RideSignedBy.thisDevice);
      expect(report.status, RideIntegrityStatus.verified);
    });

    test('a ride signed by another key is otherKey', () async {
      final report = withContext(
        await check(signedRide(other)),
        deviceKey: phone.publicKeyBase64,
      );
      expect(report.signedBy, RideSignedBy.otherKey);
      expect(report.status, RideIntegrityStatus.verified);
    });

    test('an unknown phone key never gives thisDevice or otherKey', () async {
      for (final key in <TestSigningKey>[phone, other]) {
        final report = withContext(
          await check(signedRide(key)),
          ids: const <String>{'ride-1'},
        );
        expect(report.signedBy, RideSignedBy.unknownSigner);
        expect(report.status, RideIntegrityStatus.verified);
      }
    });

    test('keys are compared by bytes, not by keyId', () async {
      // Full key bytes decide; keyIds are never compared.
      expect(
        sameRideSigningKey(phone.publicKeyBase64, other.publicKeyBase64),
        isFalse,
      );
      expect(
        sameRideSigningKey(phone.publicKeyBase64, phone.publicKeyBase64),
        isTrue,
      );
      expect(sameRideSigningKey(null, phone.publicKeyBase64), isFalse);
    });

    test(
      'a registered ride that loads unsigned is signature-removed',
      () async {
        final v2 = buildIntegrityEnvelope(
          payload: payload,
          segmentHashes: const <String, String>{'a.mp4': 'aaaa'},
          segmentCount: 1,
          generatedAt: generatedAt,
        );
        final content = await check(<String, dynamic>{
          ...payload,
          'integrity': v2,
        });
        final report = withContext(
          content,
          deviceKey: phone.publicKeyBase64,
          ids: const <String>{'ride-1'},
        );
        expect(report.status, RideIntegrityStatus.modified);
        expect(report.issues, <String>['signature-removed']);
        // The content report is kept for the ride index.
        expect(report.contentReport.status, RideIntegrityStatus.verified);
        expect(report.contentReport.issues, isEmpty);

        // A ride without any envelope is flagged too.
        final bare = withContext(
          const RideIntegrityReport.unknown(),
          deviceKey: phone.publicKeyBase64,
          ids: const <String>{'ride-1'},
        );
        expect(bare.issues, <String>['signature-removed']);
      },
    );

    test(
      'a registered ride re-signed by another key is signature-removed',
      () async {
        final report = withContext(
          await check(signedRide(other)),
          deviceKey: phone.publicKeyBase64,
          ids: const <String>{'ride-1'},
        );
        expect(report.issues, <String>['signature-removed']);
        expect(report.signedBy, RideSignedBy.otherKey);
      },
    );

    test(
      'nothing is flagged for unregistered rides or an unknown key',
      () async {
        final unsigned = await check(signedRide(null));
        // Not registered: only the content issue.
        expect(
          withContext(unsigned, deviceKey: phone.publicKeyBase64).issues,
          <String>['missing-signature'],
        );
        // Key unknown: the registry is never consulted.
        final v2Report = const RideIntegrityReport.verified();
        expect(
          withContext(v2Report, ids: const <String>{'ride-1'}).status,
          RideIntegrityStatus.verified,
        );
        // No session id.
        expect(
          withContext(
            v2Report,
            deviceKey: phone.publicKeyBase64,
            ids: const <String>{'ride-1'},
            rideSessionId: null,
          ).status,
          RideIntegrityStatus.verified,
        );
      },
    );

    test('re-applying a context starts from the content report', () async {
      final content = await check(signedRide(other));
      final first = withContext(
        content,
        deviceKey: phone.publicKeyBase64,
        ids: const <String>{'ride-1'},
      );
      final second = withContext(first, deviceKey: other.publicKeyBase64);
      expect(second.issues, isEmpty);
      expect(second.signedBy, RideSignedBy.thisDevice);
      expect(
        applySignerContext(first, rideSessionId: 'ride-1', context: null),
        same(content),
      );
    });
  });

  group('sealAndSignRidePayload', () {
    Future<SealedRidePayload> seal(
      RidePayloadSigner? signer, {
      Duration? timeout,
    }) => sealAndSignRidePayload(
      payload,
      segmentHashes: const <String, String>{'a.mp4': 'aaaa'},
      segmentCount: 1,
      generatedAt: generatedAt,
      signer: signer,
      signerTimeout: timeout ?? const Duration(seconds: 6),
    );

    test('a signer writes a verified version 3 ride', () async {
      final sealed = await seal(phone.signer);
      expect(sealed.signature, isNotNull);
      final integrity = sealed.json['integrity'] as Map<String, dynamic>;
      expect(integrity['envelopeVersion'], 3);
      expect(signatureOf(sealed.json)['publicKey'], phone.publicKeyBase64);
      final report = await check(sealed.json);
      expect(report.status, RideIntegrityStatus.verified);
      expect(report.signature!.valid, isTrue);
    });

    test(
      'without a signature the ride is sealed as version 2 exactly',
      () async {
        final expected = await sealRidePayload(
          payload,
          segmentHashes: const <String, String>{'a.mp4': 'aaaa'},
          segmentCount: 1,
          generatedAt: generatedAt,
        );
        final signers = <RidePayloadSigner?>[
          null,
          (_) async => null,
          (_) async => throw StateError('keystore'),
          // A signature over something else.
          (_) async => phone.sign('0' * 64),
          (_) => Future<RideSignatureData?>.delayed(
            const Duration(seconds: 1),
            () => phone.sign('0' * 64),
          ),
        ];
        for (final signer in signers) {
          final sealed = await seal(
            signer,
            timeout: const Duration(milliseconds: 100),
          );
          expect(sealed.signature, isNull);
          expect(jsonEncode(sealed.json), jsonEncode(expected));
        }
      },
    );
  });
}

/// DER signature whose r is the raw bytes [rBytes] (for malformed cases).
List<int> derSignatureWithRawR(List<int> rBytes, BigInt s) {
  final body = <int>[0x02, rBytes.length, ...rBytes, ...derInteger(s)];
  return <int>[0x30, body.length, ...body];
}
