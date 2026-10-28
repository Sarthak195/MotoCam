import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/core/utils/integrity_utils.dart';
import 'package:motocam/features/history/models/ride_record.dart';

final String _sep = Platform.pathSeparator;

void main() {
  group('RideRecord', () {
    late Directory tempRoot;
    late Directory storageDirectory;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('motocam_ride_record_');
      storageDirectory = Directory(
        '${tempRoot.path}${_sep}storage${_sep}MotoCam${_sep}Recordings',
      );
      await storageDirectory.create(recursive: true);
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Future<File> createSegment(String name, String content) async {
      final file = File('${storageDirectory.path}$_sep$name');
      await file.writeAsString(content);
      return file;
    }

    File telemetryFileNamed(String name) =>
        File('${storageDirectory.path}$_sep$name.telemetry.json');

    test(
      'fromTelemetryFile returns verified ride when integrity matches',
      () async {
        final segmentFile = await createSegment(
          'segment_01.mp4',
          'segment-one-data',
        );
        final telemetryFile = telemetryFileNamed('segment_01');

        await _writeRide(
          telemetryFile: telemetryFile,
          payload: _ridePayload(
            segmentPaths: <String>[segmentFile.path],
            lockedSegmentPaths: <String>[segmentFile.path],
            storageDirectory: storageDirectory.path,
          ),
          envelope: _Envelope.bound,
        );

        final rideLazy = await RideRecord.fromTelemetryFile(telemetryFile);
        expect(rideLazy, isNotNull);
        expect(rideLazy!.integrity.status, RideIntegrityStatus.verified);
        expect(rideLazy.hasQuarantinedSegments, isFalse);
        expect(rideLazy.hasMissingSegments, isFalse);
        expect(rideLazy.segmentPaths, <String>[segmentFile.path]);
        expect(rideLazy.lockedSegmentPaths, <String>[segmentFile.path]);
        expect(rideLazy.integrity.isVerified, isTrue);
        expect(rideLazy.fileName, 'segment_01.mp4');

        final rideFull = await RideRecord.fromTelemetryFile(
          telemetryFile,
          verifySegments: true,
        );
        expect(rideFull, isNotNull);
        expect(rideFull!.integrity.status, RideIntegrityStatus.verified);
        expect(rideFull.integrity.isVerified, isTrue);

        final rideVerifiedOnDemand = await rideLazy.verifySegmentIntegrity();
        expect(
          rideVerifiedOnDemand.integrity.status,
          RideIntegrityStatus.verified,
        );
        expect(rideVerifiedOnDemand.integrity.isVerified, isTrue);
      },
    );

    test(
      'legacy (unbound) envelopes written by older versions still verify',
      () async {
        final segmentFile = await createSegment('legacy.mp4', 'legacy-data');
        final telemetryFile = telemetryFileNamed('legacy');
        await _writeRide(
          telemetryFile: telemetryFile,
          payload: _ridePayload(segmentPaths: <String>[segmentFile.path]),
          envelope: _Envelope.legacy,
        );

        final ride = await RideRecord.fromTelemetryFile(
          telemetryFile,
          verifySegments: true,
        );
        expect(ride!.integrity.status, RideIntegrityStatus.verified);
      },
    );

    test(
      'quarantines out-of-scope paths and blocks lock-state updates',
      () async {
        final outsideDirectory = Directory(
          '${tempRoot.path}${_sep}outside${_sep}Elsewhere',
        );
        await outsideDirectory.create(recursive: true);

        final goodSegment = await createSegment(
          'segment_good.mp4',
          'good-segment-data',
        );
        final quarantinedSegment = File(
          '${outsideDirectory.path}${_sep}segment_bad.mp4',
        );
        await quarantinedSegment.writeAsString('bad-segment-data');

        // <tmp>/storage/MotoCam/Recordings/../../../outside/... resolves to the
        // existing file at <tmp>/outside/Elsewhere/segment_bad.mp4.
        final traversalSegmentPath =
            '${storageDirectory.path}$_sep..$_sep..$_sep..${_sep}outside${_sep}Elsewhere${_sep}segment_bad.mp4';
        expect(await File(traversalSegmentPath).exists(), isTrue);

        final telemetryFile = telemetryFileNamed('segment_good');
        await telemetryFile.writeAsString(
          jsonEncode(
            _ridePayload(
              segmentPaths: <String>[goodSegment.path, traversalSegmentPath],
              storageDirectory: storageDirectory.path,
            ),
          ),
        );
        final before = await telemetryFile.readAsString();

        final ride = await RideRecord.fromTelemetryFile(telemetryFile);
        expect(ride, isNotNull);
        expect(ride!.integrity.status, RideIntegrityStatus.modified);
        expect(ride.hasQuarantinedSegments, isTrue);
        expect(ride.quarantinedSegmentPaths, <String>[traversalSegmentPath]);
        expect(ride.segmentPaths, <String>[goodSegment.path]);

        expect(await ride.setLockState(true), isFalse);
        final after = await telemetryFile.readAsString();
        expect(after, before);
      },
    );

    test(
      'does not trust a storageDirectory declared by the JSON itself',
      () async {
        final foreignDirectory = Directory('${tempRoot.path}${_sep}foreign');
        await foreignDirectory.create(recursive: true);
        final foreignVideo = File('${foreignDirectory.path}${_sep}foreign.mp4');
        await foreignVideo.writeAsString('foreign-data');

        final telemetryFile = telemetryFileNamed('crafted');
        await _writeRide(
          telemetryFile: telemetryFile,
          payload: _ridePayload(
            segmentPaths: <String>[foreignVideo.path],
            storageDirectory: foreignDirectory.path,
          ),
          envelope: _Envelope.bound,
        );

        final ride = await RideRecord.fromTelemetryFile(telemetryFile);
        expect(ride, isNull, reason: 'no trusted video path remains');

        final goodSegment = await createSegment('own.mp4', 'own-data');
        await _writeRide(
          telemetryFile: telemetryFile,
          payload: _ridePayload(
            segmentPaths: <String>[goodSegment.path, foreignVideo.path],
            storageDirectory: foreignDirectory.path,
          ),
          envelope: _Envelope.bound,
        );
        final mixed = await RideRecord.fromTelemetryFile(telemetryFile);
        expect(mixed!.quarantinedSegmentPaths, <String>[foreignVideo.path]);
        expect(mixed.integrity.status, RideIntegrityStatus.modified);
      },
    );

    test(
      'relocates segments whose recorded directory no longer exists',
      () async {
        final first = await createSegment('REC1.mp4', 'first-data');
        final second = await createSegment('REC2.mp4', 'second-data');
        final staleDirectory =
            '${tempRoot.path}${_sep}OldContainer${_sep}Documents';
        final staleFirst = '$staleDirectory${_sep}REC1.mp4';
        final staleSecond = '$staleDirectory${_sep}REC2.mp4';

        final payload = _ridePayload(
          segmentPaths: <String>[staleFirst, staleSecond],
          lockedSegmentPaths: <String>[staleSecond],
          storageDirectory: staleDirectory,
          timeline: <Map<String, dynamic>>[
            <String, dynamic>{
              'path': staleSecond,
              'startMs': 1000,
              'endMs': 2000,
            },
            <String, dynamic>{
              'path': staleFirst,
              'startMs': -50,
              'endMs': 1000,
            },
          ],
        );
        final telemetryFile = telemetryFileNamed('relocated');
        await telemetryFile.writeAsString(
          jsonEncode(<String, dynamic>{
            ...payload,
            'integrity': buildIntegrityEnvelope(
              payload: payload,
              segmentHashes: <String, String>{
                staleFirst: (await hashFileSha256(first.path))!,
                staleSecond: (await hashFileSha256(second.path))!,
              },
              segmentCount: 2,
            ),
          }),
        );

        final ride = await RideRecord.fromTelemetryFile(
          telemetryFile,
          verifySegments: true,
        );
        expect(ride, isNotNull);
        expect(ride!.segmentPaths, <String>[first.path, second.path]);
        expect(ride.videoPath, second.path);
        expect(ride.lockedSegmentPaths, <String>[second.path]);
        expect(ride.hasQuarantinedSegments, isFalse);
        expect(ride.hasMissingSegments, isFalse);
        expect(ride.integrity.status, RideIntegrityStatus.verified);
        expect(
          ride.segmentTimeline.map((entry) => entry.path).toList(),
          <String>[first.path, second.path],
        );
        expect(ride.segmentTimeline.first.startMs, 0);
      },
    );

    test('resolves plain file names and hashes keyed by file name', () async {
      final segment = await createSegment('REC9.mp4', 'nine-data');
      final payload = _ridePayload(segmentPaths: <String>['REC9.mp4']);
      final telemetryFile = telemetryFileNamed('relative');
      await telemetryFile.writeAsString(
        jsonEncode(<String, dynamic>{
          ...payload,
          'integrity': buildIntegrityEnvelope(
            payload: payload,
            segmentHashes: <String, String>{
              'REC9.mp4': (await hashFileSha256(segment.path))!,
            },
            segmentCount: 1,
          ),
        }),
      );

      final ride = await RideRecord.fromTelemetryFile(
        telemetryFile,
        verifySegments: true,
      );
      expect(ride!.segmentPaths, <String>[segment.path]);
      expect(ride.integrity.status, RideIntegrityStatus.verified);
    });

    test(
      'a segment hash edited without re-sealing fails the payload check',
      () async {
        final segment = await createSegment('seg.mp4', 'original');
        final telemetryFile = telemetryFileNamed('forged');
        await _writeRide(
          telemetryFile: telemetryFile,
          payload: _ridePayload(segmentPaths: <String>[segment.path]),
          envelope: _Envelope.bound,
        );

        await segment.writeAsString('replaced');
        final json =
            jsonDecode(await telemetryFile.readAsString())
                as Map<String, dynamic>;
        final integrity = json['integrity'] as Map<String, dynamic>;
        (integrity['segmentHashes'] as Map<String, dynamic>)[segment.path] =
            await hashFileSha256(segment.path);
        await telemetryFile.writeAsString(jsonEncode(json));

        final ride = await RideRecord.fromTelemetryFile(telemetryFile);
        expect(ride!.integrity.status, RideIntegrityStatus.modified);
        expect(ride.integrity.issues, contains('payload-hash-mismatch'));
      },
    );

    test(
      'a replaced segment file is reported only by full verification',
      () async {
        final segment = await createSegment('seg.mp4', 'original');
        final telemetryFile = telemetryFileNamed('swapped');
        await _writeRide(
          telemetryFile: telemetryFile,
          payload: _ridePayload(segmentPaths: <String>[segment.path]),
          envelope: _Envelope.bound,
        );
        await segment.writeAsString('replaced');

        final lazy = await RideRecord.fromTelemetryFile(telemetryFile);
        expect(lazy!.integrity.status, RideIntegrityStatus.verified);

        final full = await lazy.verifySegmentIntegrity();
        expect(full.integrity.status, RideIntegrityStatus.modified);
        expect(full.integrity.issues, <String>[
          'segment-hash-mismatch:${segment.path}',
        ]);
      },
    );

    test(
      'a missing segment file makes the ride incomplete, not modified',
      () async {
        final first = await createSegment('a.mp4', 'a-data');
        final second = await createSegment('b.mp4', 'b-data');
        final telemetryFile = telemetryFileNamed('incomplete');
        await _writeRide(
          telemetryFile: telemetryFile,
          payload: _ridePayload(
            segmentPaths: <String>[first.path, second.path],
          ),
          envelope: _Envelope.bound,
        );
        await first.delete();

        final ride = await RideRecord.fromTelemetryFile(
          telemetryFile,
          verifySegments: true,
        );
        expect(ride!.integrity.status, RideIntegrityStatus.verified);
        expect(ride.missingSegmentPaths, <String>[first.path]);
        expect(ride.hasMissingSegments, isTrue);
        expect(ride.availableSegmentCount, 1);
      },
    );

    test(
      'fails closed when a completed schema-3 ride has no envelope or it is invalid',
      () async {
        final segment = await createSegment('seg.mp4', 'data');
        final telemetryFile = telemetryFileNamed('no_envelope');

        await telemetryFile.writeAsString(
          jsonEncode(
            _ridePayload(
              segmentPaths: <String>[segment.path],
              schemaVersion: 2,
            ),
          ),
        );
        final legacy = await RideRecord.fromTelemetryFile(telemetryFile);
        expect(legacy!.integrity.status, RideIntegrityStatus.unknown);

        await telemetryFile.writeAsString(
          jsonEncode(
            _ridePayload(
              segmentPaths: <String>[segment.path],
              schemaVersion: 3,
            ),
          ),
        );
        final stripped = await RideRecord.fromTelemetryFile(telemetryFile);
        expect(stripped!.integrity.status, RideIntegrityStatus.modified);
        expect(stripped.integrity.issues, <String>['missing-integrity']);

        await telemetryFile.writeAsString(
          jsonEncode(<String, dynamic>{
            ..._ridePayload(
              segmentPaths: <String>[segment.path],
              schemaVersion: 2,
            ),
            'integrity': 'not-a-map',
          }),
        );
        final invalid = await RideRecord.fromTelemetryFile(telemetryFile);
        expect(invalid!.integrity.status, RideIntegrityStatus.modified);
        expect(invalid.integrity.issues, <String>['invalid-integrity']);

        await telemetryFile.writeAsString(
          jsonEncode(<String, dynamic>{
            ..._ridePayload(
              segmentPaths: <String>[segment.path],
              schemaVersion: 3,
            ),
            'sessionComplete': false,
          }),
        );
        final unsealed = await RideRecord.fromTelemetryFile(telemetryFile);
        expect(unsealed!.integrity.status, RideIntegrityStatus.unknown);
        expect(unsealed.isSessionComplete, isFalse);

        await _writeRide(
          telemetryFile: telemetryFile,
          payload: _ridePayload(
            segmentPaths: <String>[segment.path],
            schemaVersion: 3,
          ),
          envelope: _Envelope.legacy,
        );
        final legacyEnvelope = await RideRecord.fromTelemetryFile(
          telemetryFile,
        );
        expect(legacyEnvelope!.integrity.status, RideIntegrityStatus.verified);

        await telemetryFile.writeAsString(
          jsonEncode(<String, dynamic>{
            ..._ridePayload(
              segmentPaths: <String>[segment.path],
              schemaVersion: 3,
            ),
            'integrity': <String, dynamic>{
              'algo': 'sha256',
              'envelopeVersion': 99,
              'payloadHash': 'x',
            },
          }),
        );
        final future = await RideRecord.fromTelemetryFile(telemetryFile);
        expect(
          future!.integrity.issues,
          contains('unsupported-integrity-version:99'),
        );
      },
    );

    test('reports algorithm, payload-hash and orphan-hash issues', () async {
      final segment = await createSegment('seg.mp4', 'data');
      final telemetryFile = telemetryFileNamed('issues');
      final payload = _ridePayload(segmentPaths: <String>[segment.path]);
      await telemetryFile.writeAsString(
        jsonEncode(<String, dynamic>{
          ...payload,
          'integrity': <String, dynamic>{
            'algo': 'md5',
            'segmentHashes': <String, String>{
              segment.path: (await hashFileSha256(segment.path))!,
              '${storageDirectory.path}${_sep}gone.mp4': 'abc',
            },
          },
        }),
      );

      final ride = await RideRecord.fromTelemetryFile(telemetryFile);
      expect(ride!.integrity.status, RideIntegrityStatus.modified);
      expect(ride.integrity.issues, <String>[
        'unsupported-integrity-algorithm:md5',
        'missing-payload-hash',
        'orphan-integrity-hash:${storageDirectory.path}${_sep}gone.mp4',
      ]);
    });

    test(
      'setLockState unlocks a verified ride and keeps it verified',
      () async {
        final segment = await createSegment('locked.mp4', 'locked-data');
        final telemetryFile = telemetryFileNamed('locked');
        await _writeRide(
          telemetryFile: telemetryFile,
          payload: _ridePayload(
            segmentPaths: <String>[segment.path],
            lockedSegmentPaths: <String>[segment.path],
          ),
          envelope: _Envelope.legacy,
        );
        final originalHashes =
            ((jsonDecode(await telemetryFile.readAsString())
                    as Map)['integrity']
                as Map)['segmentHashes'];

        final ride = await RideRecord.fromTelemetryFile(telemetryFile);
        expect(ride!.isLocked, isTrue);
        expect(await ride.setLockState(false), isTrue);

        final json =
            jsonDecode(await telemetryFile.readAsString())
                as Map<String, dynamic>;
        expect(json['lockedSegmentPaths'], isEmpty);
        final integrity = json['integrity'] as Map<String, dynamic>;
        expect(integrity['segmentHashes'], originalHashes);
        expect(integrity['envelopeVersion'], boundIntegrityEnvelopeVersion);

        final reloaded = await RideRecord.fromTelemetryFile(
          telemetryFile,
          verifySegments: true,
        );
        expect(reloaded!.isLocked, isFalse);
        expect(reloaded.integrity.status, RideIntegrityStatus.verified);

        expect(await reloaded.setLockState(true), isTrue);
        final relocked = await RideRecord.fromTelemetryFile(
          telemetryFile,
          verifySegments: true,
        );
        expect(relocked!.lockedSegmentPaths, <String>[segment.path]);
        expect(relocked.integrity.status, RideIntegrityStatus.verified);
      },
    );

    test(
      'setLockState refuses to re-seal a ride whose segment changed',
      () async {
        final segment = await createSegment('tampered.mp4', 'original');
        final telemetryFile = telemetryFileNamed('tampered');
        await _writeRide(
          telemetryFile: telemetryFile,
          payload: _ridePayload(
            segmentPaths: <String>[segment.path],
            lockedSegmentPaths: <String>[segment.path],
          ),
          envelope: _Envelope.bound,
        );
        await segment.writeAsString('replaced');
        final before = await telemetryFile.readAsString();

        final ride = await RideRecord.fromTelemetryFile(telemetryFile);
        expect(ride!.integrity.status, RideIntegrityStatus.verified);
        expect(await ride.setLockState(false), isFalse);
        expect(await telemetryFile.readAsString(), before);
      },
    );

    test(
      'setLockState on a ride without an envelope does not create one',
      () async {
        final segment = await createSegment('old.mp4', 'old-data');
        final telemetryFile = telemetryFileNamed('old');
        await telemetryFile.writeAsString(
          jsonEncode(
            _ridePayload(
              segmentPaths: <String>[segment.path],
              lockedSegmentPaths: <String>[segment.path],
            ),
          ),
        );

        final ride = await RideRecord.fromTelemetryFile(telemetryFile);
        expect(ride!.integrity.status, RideIntegrityStatus.unknown);
        expect(await ride.setLockState(false), isTrue);

        final json =
            jsonDecode(await telemetryFile.readAsString())
                as Map<String, dynamic>;
        expect(json.containsKey('integrity'), isFalse);
        final reloaded = await RideRecord.fromTelemetryFile(telemetryFile);
        expect(reloaded!.isLocked, isFalse);
        expect(reloaded.integrity.status, RideIntegrityStatus.unknown);
      },
    );

    test(
      'fromVideoFile builds a video-only ride when no telemetry exists',
      () async {
        final video = await createSegment('REC77.mp4', 'orphan-data');
        final ride = await RideRecord.fromVideoFile(video);
        expect(ride.telemetryPath, isNull);
        expect(ride.segmentPaths, <String>[video.path]);
        expect(ride.integrity.status, RideIntegrityStatus.unknown);
        expect(ride.samples, isEmpty);
      },
    );

    test(
      'fromVideoFile uses a sibling ride JSON only when it references the video',
      () async {
        final video = await createSegment('REC5.mp4', 'five-data');
        final sibling = telemetryFileNamed('REC5');
        await _writeRide(
          telemetryFile: sibling,
          payload: _ridePayload(segmentPaths: <String>[video.path]),
          envelope: _Envelope.bound,
        );
        final linked = await RideRecord.fromVideoFile(video);
        expect(linked.telemetryPath, sibling.path);

        final other = await createSegment('REC6.mp4', 'six-data');
        await _writeRide(
          telemetryFile: sibling,
          payload: _ridePayload(segmentPaths: <String>[other.path]),
          envelope: _Envelope.bound,
        );
        final unlinked = await RideRecord.fromVideoFile(video);
        expect(unlinked.telemetryPath, isNull);
        expect(unlinked.segmentPaths, <String>[video.path]);
      },
    );

    test('sampleForPosition interpolates between samples', () async {
      final segment = await createSegment('interp.mp4', 'data');
      final payload = _ridePayload(segmentPaths: <String>[segment.path])
        ..['samples'] = <Map<String, dynamic>>[
          _sample(elapsedMs: 0, speed: 10, distanceKm: 0),
          _sample(elapsedMs: 1000, speed: 20, distanceKm: 1),
        ];
      final telemetryFile = telemetryFileNamed('interp');
      await telemetryFile.writeAsString(jsonEncode(payload));

      final ride = await RideRecord.fromTelemetryFile(telemetryFile);
      final mid = ride!.sampleForPosition(const Duration(milliseconds: 500));
      expect(mid.speed, closeTo(15, 1e-9));
      expect(mid.distanceKm, closeTo(0.5, 1e-9));
      expect(ride.sampleForPosition(const Duration(seconds: 5)).speed, 20);
      expect(ride.duration, const Duration(seconds: 1));
    });

    test(
      'sampleForPosition never interpolates position across a no-fix sample',
      () async {
        final segment = await createSegment('nofix.mp4', 'data');
        final payload = _ridePayload(segmentPaths: <String>[segment.path])
          ..['samples'] = <Map<String, dynamic>>[
            _sample(elapsedMs: 0)
              ..['latitude'] = 0.0
              ..['longitude'] = 0.0
              ..['hasFix'] = false,
            _sample(elapsedMs: 1000)
              ..['latitude'] = 10.0
              ..['longitude'] = 20.0
              ..['hasFix'] = true,
          ];
        final telemetryFile = telemetryFileNamed('nofix');
        await telemetryFile.writeAsString(jsonEncode(payload));

        final ride = await RideRecord.fromTelemetryFile(telemetryFile);
        final mid = ride!.sampleForPosition(const Duration(milliseconds: 300));
        expect(mid.latitude, 10.0);
        expect(mid.longitude, 20.0);
        expect(mid.hasFix, isTrue);
      },
    );

    test(
      'reads startedAt as local time, incidents and mockLocationDetected',
      () async {
        final segment = await createSegment('extras.mp4', 'data');
        final payload = _ridePayload(segmentPaths: <String>[segment.path])
          ..['incidents'] = <Map<String, dynamic>>[
            <String, dynamic>{
              'elapsedMs': 5000,
              'timestamp': '2026-05-03T10:00:05.000Z',
              'gForce': 4.2,
              'triggerGForce': 3.5,
              'reason': 'auto-crash',
            },
            <String, dynamic>{'elapsedMs': 'bad'},
            <String, dynamic>{'elapsedMs': 1000},
          ]
          ..['mockLocationDetected'] = true;
        final telemetryFile = telemetryFileNamed('extras');
        await _writeRide(
          telemetryFile: telemetryFile,
          payload: payload,
          envelope: _Envelope.bound,
        );

        final ride = await RideRecord.fromTelemetryFile(telemetryFile);
        expect(ride, isNotNull);
        expect(ride!.createdAt.isUtc, isFalse);
        expect(
          ride.createdAt,
          DateTime.parse('2026-05-03T10:00:00.000Z').toLocal(),
        );
        expect(ride.mockLocationDetected, isTrue);
        expect(ride.incidents!.map((i) => i.elapsedMs), <int>[1000, 5000]);
        expect(ride.incidents!.last.gForce, 4.2);
        expect(ride.incidents!.last.reason, 'auto-crash');
        expect(ride.integrity.status, RideIntegrityStatus.verified);

        final verified = await ride.verifySegmentIntegrity();
        expect(verified.incidents, hasLength(2));
        expect(verified.mockLocationDetected, isTrue);
      },
    );

    test('rides without the incidents key keep incidents null', () async {
      final segment = await createSegment('noinc.mp4', 'data');
      final telemetryFile = telemetryFileNamed('noinc');
      await telemetryFile.writeAsString(
        jsonEncode(_ridePayload(segmentPaths: <String>[segment.path])),
      );
      final ride = await RideRecord.fromTelemetryFile(telemetryFile);
      expect(ride!.incidents, isNull);
      expect(ride.mockLocationDetected, isFalse);
    });
  });

  group('RideRecord.interpolateBearing', () {
    test('takes the shortest arc across north', () {
      expect(RideRecord.interpolateBearing(359, 1, 0.5), closeTo(0, 1e-9));
      expect(RideRecord.interpolateBearing(350, 10, 0.25), closeTo(355, 1e-9));
      expect(RideRecord.interpolateBearing(10, 350, 0.5), closeTo(0, 1e-9));
      expect(RideRecord.interpolateBearing(90, 180, 0.5), closeTo(135, 1e-9));
    });

    test('uses the other bearing when one is unavailable (negative)', () {
      expect(RideRecord.interpolateBearing(-1, 120, 0.3), 120);
      expect(RideRecord.interpolateBearing(45, -1, 0.7), 45);
      expect(RideRecord.interpolateBearing(-1, -1, 0.5), -1);
    });
  });
}

enum _Envelope { bound, legacy }

Map<String, dynamic> _sample({
  required int elapsedMs,
  double speed = 0,
  double distanceKm = 0,
}) {
  return <String, dynamic>{
    'timestamp': DateTime.utc(
      2026,
      5,
      3,
      10,
    ).add(Duration(milliseconds: elapsedMs)).toIso8601String(),
    'elapsedMs': elapsedMs,
    'latitude': 37.0,
    'longitude': -122.0,
    'speed': speed,
    'bearing': 0.0,
    'accelerationG': 0.0,
    'distanceKm': distanceKm,
  };
}

Map<String, dynamic> _ridePayload({
  required List<String> segmentPaths,
  List<String> lockedSegmentPaths = const <String>[],
  String? storageDirectory,
  List<Map<String, dynamic>>? timeline,
  int schemaVersion = 2,
}) {
  return <String, dynamic>{
    'schemaVersion': schemaVersion,
    'videoPath': segmentPaths.last,
    'segmentPaths': segmentPaths,
    'lockedSegmentPaths': lockedSegmentPaths,
    'segmentTimeline':
        timeline ??
        <Map<String, dynamic>>[
          for (var index = 0; index < segmentPaths.length; index++)
            <String, dynamic>{
              'path': segmentPaths[index],
              'startMs': index * 1200,
              'endMs': (index + 1) * 1200,
            },
        ],
    'storageDirectory': ?storageDirectory,
    'rideSessionId': 'session-test',
    'sessionComplete': true,
    'distanceKm': 1.25,
    'maxSpeedKmh': 42.0,
    'averageSpeedKmh': 28.4,
    'startedAt': '2026-05-03T10:00:00.000Z',
    'endedAt': '2026-05-03T10:02:00.000Z',
    'samples': <Map<String, dynamic>>[_sample(elapsedMs: 0)],
  };
}

/// Seals [payload] the way the app does (bound envelope) or the way builds
/// before envelope version 2 did (legacy), and writes it to [telemetryFile].
Future<void> _writeRide({
  required File telemetryFile,
  required Map<String, dynamic> payload,
  required _Envelope envelope,
}) async {
  final segmentPaths = (payload['segmentPaths'] as List).cast<String>();
  final segmentHashes = <String, String>{};
  for (final path in segmentPaths) {
    final hash = await hashFileSha256(path);
    if (hash != null) {
      segmentHashes[path] = hash;
    }
  }

  final Map<String, dynamic> integrity;
  switch (envelope) {
    case _Envelope.bound:
      integrity = buildIntegrityEnvelope(
        payload: payload,
        segmentHashes: segmentHashes,
        segmentCount: segmentPaths.length,
      );
    case _Envelope.legacy:
      integrity = <String, dynamic>{
        'algo': 'sha256',
        'payloadHash': hashJsonCanonical(payload),
        'segmentCount': segmentPaths.length,
        'hashedSegmentCount': segmentHashes.length,
        'segmentHashes': segmentHashes,
        'generatedAt': '2026-05-03T12:00:00.000Z',
      };
  }

  await telemetryFile.writeAsString(
    jsonEncode(<String, dynamic>{...payload, 'integrity': integrity}),
  );
}
