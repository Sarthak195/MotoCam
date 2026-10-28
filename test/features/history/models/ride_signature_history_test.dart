// Signed rides (envelope version 3) in Ride History: the signer context in
// the loader and the index, the downgrade check, playback's re-read, the
// lock change and the playback notice.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/core/ride_file/ride_telemetry_codec.dart';
import 'package:motocam/core/utils/integrity_utils.dart';
import 'package:motocam/features/history/models/ride_history_loader.dart';
import 'package:motocam/features/history/models/ride_index.dart';
import 'package:motocam/features/history/models/ride_record.dart';
import 'package:motocam/features/history/widgets/playback_timeline.dart';

import '../../../support/test_signing_key.dart';

void main() {
  late Directory directory;
  final sep = Platform.pathSeparator;
  final phone = TestSigningKey.generate(1);
  final other = TestSigningKey.generate(2);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('motocam_signed_');
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  RideSignerContext contextFor(
    TestSigningKey? key, {
    Set<String> ids = const <String>{},
    Set<String> segmentFileNames = const <String>{},
  }) => RideSignerContext(
    thisDevicePublicKey: key?.publicKeyBase64,
    signedRideIds: key == null ? const <String>{} : ids,
    signedTelemetryFileNames: key == null
        ? const <String>{}
        : <String>{for (final id in ids) rideTelemetryFileNameFor(id)},
    signedSegmentFileNames: key == null ? const <String>{} : segmentFileNames,
  );

  /// Writes a one-segment ride `ride_<id>` signed by [signer] (version 2
  /// when `null`) and returns its telemetry file.
  Future<File> writeRide(String id, {TestSigningKey? signer}) async {
    final segment = File('${directory.path}${sep}seg_$id.mp4');
    await segment.writeAsString('video-$id');
    final payload = <String, dynamic>{
      'schemaVersion': 3,
      'rideSessionId': id,
      'sessionComplete': true,
      'videoPath': segment.path,
      'segmentPaths': <String>[segment.path],
      'lockedSegmentPaths': <String>[segment.path],
      'segmentTimeline': <Map<String, dynamic>>[
        <String, dynamic>{'path': segment.path, 'startMs': 0, 'endMs': 1000},
      ],
      'startedAt': '2026-05-03T10:00:00.000Z',
      'distanceKm': 1.5,
      'maxSpeedKmh': 40.0,
      'averageSpeedKmh': 20.0,
      'samples': <Map<String, dynamic>>[
        <String, dynamic>{
          'elapsedMs': 0,
          'speed': 10.0,
          'timestamp': '2026-05-03T10:00:00Z',
        },
      ],
    };
    final sealed = await sealAndSignRidePayload(
      payload,
      segmentHashes: <String, String>{
        segment.path: (await hashFileSha256(segment.path))!,
      },
      segmentCount: 1,
      generatedAt: DateTime.utc(2026, 5, 3),
      signer: signer?.signer,
    );
    expect(sealed.signature != null, signer != null);
    final file = File('${directory.path}${sep}ride_$id.telemetry.json');
    await file.writeAsString(jsonEncode(sealed.json));
    return file;
  }

  List<String> listing() =>
      directory.listSync().map((entity) => entity.path).toList()..sort();

  Future<Map<String, dynamic>> readJson(File file) async =>
      jsonDecode(await file.readAsString()) as Map<String, dynamic>;

  group('loader and index', () {
    test('who signed is derived for decoded and cached rides', () async {
      await writeRide('mine', signer: phone);
      await writeRide('theirs', signer: other);
      await writeRide('plain');

      Map<String, RideRecord> byId(RideHistoryLoad load) =>
          <String, RideRecord>{
            for (final ride in load.rides) ride.rideSessionId!: ride,
          };

      final first = await loadRideHistoryIndexed(
        listing(),
        signerContext: contextFor(phone),
      );
      expect(first.decodedPaths, hasLength(3));
      var rides = byId(first);
      expect(rides['mine']!.integrity.signedBy, RideSignedBy.thisDevice);
      expect(rides['theirs']!.integrity.signedBy, RideSignedBy.otherKey);
      expect(rides['plain']!.integrity.signedBy, RideSignedBy.none);
      for (final ride in rides.values) {
        expect(ride.integrity.status, RideIntegrityStatus.verified);
      }

      // The index stores the content report only, with the signature facts.
      final index = RideIndex.parse(
        jsonEncode(
          RideIndex(
            rides: Map<String, RideIndexEntry>.of(first.rideEntries),
          ).toJson(),
        ),
      );
      final stored = index.rides.values
          .map((entry) => entry.ride.integrity)
          .toList();
      expect(stored.every((report) => report.signerContext == null), isTrue);
      expect(
        stored.map((report) => report.signature?.signerPublicKey).toSet(),
        <String?>{phone.publicKeyBase64, other.publicKeyBase64, null},
      );

      // A cached load with this phone's key unknown never says thisDevice.
      final second = await loadRideHistoryIndexed(
        listing(),
        index: index,
        signerContext: contextFor(null),
      );
      expect(second.decodedPaths, isEmpty);
      rides = byId(second);
      expect(rides['mine']!.integrity.signedBy, RideSignedBy.unknownSigner);
      expect(rides['theirs']!.integrity.signedBy, RideSignedBy.unknownSigner);
      expect(rides['plain']!.integrity.signedBy, RideSignedBy.none);

      // After a reinstall (a new key) the old rides are signed by another
      // key.
      final third = await loadRideHistoryIndexed(
        listing(),
        index: index,
        signerContext: contextFor(TestSigningKey.generate(3)),
      );
      expect(byId(third)['mine']!.integrity.signedBy, RideSignedBy.otherKey);
    });

    test('an index of format 1 is rebuilt', () {
      expect(rideIndexFormatVersion, 2);
      expect(
        RideIndex.parse(
          jsonEncode(<String, dynamic>{
            'format': 1,
            'rides': <String, dynamic>{},
            'segmentHashes': <String, dynamic>{},
          }),
        ).rides,
        isEmpty,
      );
    });

    test('a registered ride that lost its signature is modified', () async {
      final file = await writeRide('mine', signer: phone);
      final registered = contextFor(phone, ids: const <String>{'mine'});

      final signed = await loadRideHistoryIndexed(
        listing(),
        signerContext: registered,
      );
      expect(
        signed.rides.single.integrity.status,
        RideIntegrityStatus.verified,
      );

      // Strip the signature and recompute a version 2 payload hash.
      final json = await readJson(file);
      final integrity = json['integrity'] as Map<String, dynamic>
        ..remove('signature')
        ..['envelopeVersion'] = 2;
      integrity['payloadHash'] = computeRidePayloadHash(json);
      await file.writeAsString(jsonEncode(json));

      final stripped = await loadRideHistoryIndexed(
        listing(),
        signerContext: registered,
      );
      final ride = stripped.rides.single;
      expect(ride.integrity.status, RideIntegrityStatus.modified);
      expect(ride.integrity.issues, <String>['signature-removed']);
      // The index keeps the file's own (verified) report.
      expect(
        stripped.rideEntries.values.single.ride.integrity.status,
        RideIntegrityStatus.verified,
      );

      // Re-signed by another key: still flagged.
      final resigned = await writeRide('mine', signer: other);
      expect(resigned.path, file.path);
      final replaced = await loadRideHistoryIndexed(
        listing(),
        signerContext: registered,
      );
      expect(replaced.rides.single.integrity.issues, <String>[
        'signature-removed',
      ]);

      // With this phone's key unknown nothing is flagged, and a stripped
      // ride is simply unsigned.
      final unknown = await loadRideHistoryIndexed(
        listing(),
        signerContext: contextFor(null, ids: const <String>{'mine'}),
      );
      expect(
        unknown.rides.single.integrity.status,
        RideIntegrityStatus.verified,
      );
      expect(
        unknown.rides.single.integrity.signedBy,
        RideSignedBy.unknownSigner,
      );
    });

    test('editing or removing the id does not escape the check', () async {
      final file = await writeRide('mine', signer: phone);
      final registered = contextFor(
        phone,
        ids: const <String>{'mine'},
        segmentFileNames: const <String>{'seg_mine.mp4'},
      );

      // Strip the signature, change or drop the id, recompute version 2.
      Future<void> strip(File target, String? newId) async {
        final json = await readJson(target);
        if (newId == null) {
          json.remove('rideSessionId');
        } else {
          json['rideSessionId'] = newId;
        }
        final integrity = json['integrity'] as Map<String, dynamic>
          ..remove('signature')
          ..['envelopeVersion'] = 2;
        integrity['payloadHash'] = computeRidePayloadHash(json);
        await target.writeAsString(jsonEncode(json));
      }

      Future<RideRecord> loadOnly() async => (await loadRideHistoryIndexed(
        listing(),
        signerContext: registered,
      )).rides.single;

      await strip(file, 'not-mine');
      var ride = await loadOnly();
      expect(ride.integrity.status, RideIntegrityStatus.modified);
      expect(ride.integrity.issues, <String>['signature-removed']);

      await strip(file, null);
      ride = await loadOnly();
      expect(ride.integrity.issues, <String>['signature-removed']);

      // Renamed as well: the segment file name still matches.
      final renamed = await file.rename(
        '${directory.path}${sep}ride_fresh.telemetry.json',
      );
      ride = await loadOnly();
      expect(ride.telemetryPath, renamed.path);
      expect(ride.integrity.issues, <String>['signature-removed']);

      // Playback's full check keeps the binding.
      final checked = await ride.verifySegmentIntegrity();
      expect(checked.integrity.issues, <String>['signature-removed']);
    });

    test('playback re-read keeps the signer context', () async {
      await writeRide('mine', signer: phone);
      final load = await loadRideHistoryIndexed(
        listing(),
        signerContext: contextFor(phone, ids: const <String>{'mine'}),
      );
      final full = await load.rides.single.loadSamples();
      expect(full.samplesLoaded, isTrue);
      expect(full.integrity.signedBy, RideSignedBy.thisDevice);
      expect(full.integrity.signerContext, isNotNull);
    });
  });

  group('setLockState', () {
    Future<RideRecord> loadRide(File file, RideSignerContext context) async =>
        (await RideRecord.fromTelemetryFile(
          file,
          loadSamples: false,
        ))!.withSignerContext(context);

    test('a ride signed by this phone is re-signed', () async {
      final file = await writeRide('mine', signer: phone);
      final context = contextFor(phone);
      final ride = await loadRide(file, context);
      var calls = 0;
      final saved = await ride.setLockState(
        false,
        signer: (hash) async {
          calls++;
          return phone.sign(hash);
        },
      );
      expect(saved, isTrue);
      expect(calls, 1);

      final json = await readJson(file);
      expect(json['lockedSegmentPaths'], isEmpty);
      expect((json['integrity'] as Map)['envelopeVersion'], 3);
      final reloaded = await loadRide(file, context);
      expect(reloaded.integrity.status, RideIntegrityStatus.verified);
      expect(reloaded.integrity.signedBy, RideSignedBy.thisDevice);

      // Lock it again: still signed.
      expect(await reloaded.setLockState(true, signer: phone.signer), isTrue);
      final relocked = await loadRide(file, context);
      expect(relocked.isLocked, isTrue);
      expect(relocked.integrity.signedBy, RideSignedBy.thisDevice);
    });

    test(
      're-signing works with a hasher that captures unsendable state',
      () async {
        // Ride History passes a hasher whose closure reaches the widget
        // State; the background signature check must not try to send it.
        final file = await writeRide('mine', signer: phone);
        final ride = await loadRide(file, contextFor(phone));
        final port = ReceivePort();
        addTearDown(port.close);
        var hashed = 0;
        final saved = await ride.setLockState(
          false,
          hashSegment: (path, expectedHash) async {
            hashed++;
            port.sendPort.hashCode;
            return hashSegmentFile(path, expectedHash);
          },
          signer: phone.signer,
        );
        expect(saved, isTrue);
        expect(hashed, 1);
        final reloaded = await loadRide(file, contextFor(phone));
        expect(reloaded.integrity.signedBy, RideSignedBy.thisDevice);
      },
    );

    test('a failed re-sign refuses the change and leaves the file', () async {
      final file = await writeRide('mine', signer: phone);
      final before = await file.readAsString();
      final ride = await loadRide(file, contextFor(phone));

      final signers = <RidePayloadSigner>[
        (_) async => null,
        (_) async => throw StateError('keystore'),
        // This phone answers with another key.
        other.signer,
        // A signature over something else.
        (_) async => phone.sign('0' * 64),
      ];
      for (final signer in signers) {
        expect(
          await ride.changeLockState(false, signer: signer),
          RideLockChangeResult.signingFailed,
        );
        expect(await file.readAsString(), before);
      }
    });

    test('who signed is decided from the re-read file', () async {
      // Listed while signed by another key, then replaced by a ride this
      // phone signed: it is re-signed, not resealed as version 2.
      final file = await writeRide('swap', signer: other);
      final ride = await loadRide(file, contextFor(phone));
      expect(ride.integrity.signedBy, RideSignedBy.otherKey);
      await writeRide('swap', signer: phone);
      expect(
        await ride.changeLockState(false, signer: phone.signer),
        RideLockChangeResult.saved,
      );
      final integrity = (await readJson(file))['integrity'] as Map;
      expect(integrity['envelopeVersion'], 3);
      expect(
        (await loadRide(file, contextFor(phone))).integrity.signedBy,
        RideSignedBy.thisDevice,
      );

      // Listed as signed here, then stripped back to version 2 while
      // registered: refused, file untouched.
      final registered = contextFor(phone, ids: const <String>{'swap'});
      final listed = await loadRide(file, registered);
      expect(listed.integrity.status, RideIntegrityStatus.verified);
      final json = await readJson(file);
      final envelope = json['integrity'] as Map<String, dynamic>
        ..remove('signature')
        ..['envelopeVersion'] = 2;
      envelope['payloadHash'] = computeRidePayloadHash(json);
      await file.writeAsString(jsonEncode(json));
      final before = await file.readAsString();
      expect(
        await listed.changeLockState(true, signer: phone.signer),
        RideLockChangeResult.refused,
      );
      expect(await file.readAsString(), before);
    });

    test('a ride signed by another key is re-sealed as version 2', () async {
      final file = await writeRide('theirs', signer: other);
      final ride = await loadRide(file, contextFor(phone));
      expect(ride.integrity.signedBy, RideSignedBy.otherKey);
      var calls = 0;
      final saved = await ride.setLockState(
        false,
        signer: (hash) async {
          calls++;
          return phone.sign(hash);
        },
      );
      expect(saved, isTrue);
      expect(calls, 0);
      final integrity = (await readJson(file))['integrity'] as Map;
      expect(integrity['envelopeVersion'], 2);
      expect(integrity.containsKey('signature'), isFalse);
      final reloaded = await loadRide(file, contextFor(phone));
      expect(reloaded.integrity.status, RideIntegrityStatus.verified);
      expect(reloaded.integrity.signedBy, RideSignedBy.none);
    });

    test('with the signer unknown, another key answering means a foreign '
        'ride', () async {
      final file = await writeRide('theirs', signer: other);
      final ride = await loadRide(file, contextFor(null));
      expect(ride.integrity.signedBy, RideSignedBy.unknownSigner);
      expect(await ride.setLockState(false, signer: phone.signer), isTrue);
      final integrity = (await readJson(file))['integrity'] as Map;
      expect(integrity['envelopeVersion'], 2);
      expect(integrity.containsKey('signature'), isFalse);
    });

    test('an unsigned ride never calls the signer', () async {
      final file = await writeRide('plain');
      final ride = await loadRide(file, contextFor(phone));
      final saved = await ride.setLockState(
        false,
        signer: (_) async => fail('must not sign'),
      );
      expect(saved, isTrue);
      expect(
        ((await readJson(file))['integrity'] as Map)['envelopeVersion'],
        2,
      );
    });

    test('a ride whose signature was removed cannot be unlocked', () async {
      final file = await writeRide('mine');
      final ride = await loadRide(
        file,
        contextFor(phone, ids: const <String>{'mine'}),
      );
      expect(ride.integrity.issues, <String>['signature-removed']);
      expect(await ride.setLockState(false, signer: phone.signer), isFalse);
    });
  });

  group('describeIntegrityIssues', () {
    test('names a removed signature and a bad signature', () {
      expect(
        describeIntegrityIssues(
          issues: const <String>['signature-removed'],
          quarantinedCount: 0,
        ),
        'Integrity check: this phone signed this ride, but its signature was '
        'removed or replaced, so the ride data may have changed since '
        'recording.',
      );
      expect(
        describeIntegrityIssues(
          issues: const <String>['signature-invalid'],
          quarantinedCount: 0,
        ),
        'Integrity check: the ride\'s signature does not match its data.',
      );
      expect(
        describeIntegrityIssues(
          issues: const <String>[
            'payload-hash-mismatch',
            'signature-key-mismatch',
          ],
          quarantinedCount: 0,
        ),
        'Integrity check: the ride\'s signature does not match its data; the '
        'ride data may have changed since recording.',
      );
    });
  });
}
