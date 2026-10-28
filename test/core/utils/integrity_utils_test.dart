import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/core/utils/integrity_utils.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('motocam_integrity_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('hashJsonCanonical', () {
    test('is independent of key order at every level', () {
      final a = <String, dynamic>{
        'b': 1,
        'a': <String, dynamic>{'y': true, 'x': null},
        'c': <dynamic>[
          <String, dynamic>{'k2': 'v', 'k1': 2.5},
        ],
      };
      final b = <String, dynamic>{
        'c': <dynamic>[
          <String, dynamic>{'k1': 2.5, 'k2': 'v'},
        ],
        'a': <String, dynamic>{'x': null, 'y': true},
        'b': 1,
      };
      expect(hashJsonCanonical(a), hashJsonCanonical(b));
      expect(
        hashJsonCanonical(a),
        isNot(hashJsonCanonical(<String, dynamic>{...a, 'b': 2})),
      );
    });
  });

  group('integrity envelope', () {
    final payload = <String, dynamic>{
      'schemaVersion': 3,
      'distanceKm': 1.5,
      'segmentPaths': <String>['a.mp4'],
    };

    test('bound envelope hash covers the segment hashes', () {
      final envelope = buildIntegrityEnvelope(
        payload: payload,
        segmentHashes: const <String, String>{'a.mp4': 'aaaa'},
        segmentCount: 1,
        generatedAt: DateTime.utc(2026, 1, 1),
      );
      expect(envelope['algo'], integrityAlgorithmSha256);
      expect(envelope['envelopeVersion'], boundIntegrityEnvelopeVersion);
      expect(envelope['hashedSegmentCount'], 1);

      final ride = <String, dynamic>{...payload, 'integrity': envelope};
      expect(computeRidePayloadHash(ride), envelope['payloadHash']);

      final forged = <String, dynamic>{
        ...payload,
        'integrity': <String, dynamic>{
          ...envelope,
          'segmentHashes': const <String, String>{'a.mp4': 'bbbb'},
        },
      };
      expect(computeRidePayloadHash(forged), isNot(envelope['payloadHash']));
    });

    test('legacy envelope hash covers only the payload', () {
      final legacy = <String, dynamic>{
        ...payload,
        'integrity': <String, dynamic>{
          'algo': 'sha256',
          'payloadHash': 'ignored',
          'segmentHashes': const <String, String>{'a.mp4': 'anything'},
        },
      };
      expect(computeRidePayloadHash(legacy), hashJsonCanonical(payload));
      expect(integrityEnvelopeVersionOf(legacy['integrity'] as Map), 1);
    });

    test('resealIntegrityEnvelope keeps segment hashes and re-hashes', () {
      final ride = <String, dynamic>{
        ...payload,
        'integrity': <String, dynamic>{
          'algo': 'sha256',
          'payloadHash': hashJsonCanonical(payload),
          'segmentHashes': const <String, String>{'a.mp4': 'aaaa'},
        },
      };
      ride['lockedSegmentPaths'] = <String>[];
      resealIntegrityEnvelope(ride);

      final envelope = ride['integrity'] as Map<String, dynamic>;
      expect(envelope['segmentHashes'], const <String, String>{
        'a.mp4': 'aaaa',
      });
      expect(envelope['envelopeVersion'], boundIntegrityEnvelopeVersion);
      expect(computeRidePayloadHash(ride), envelope['payloadHash']);
    });

    test('resealIntegrityEnvelope throws without an envelope', () {
      expect(
        () => resealIntegrityEnvelope(Map<String, dynamic>.from(payload)),
        throwsStateError,
      );
    });
  });

  group('hashFileSha256', () {
    test(
      'hashes file contents and returns null for missing or empty paths',
      () async {
        final file = File('${tempDir.path}${Platform.pathSeparator}a.bin');
        await file.writeAsString('abc');
        expect(
          await hashFileSha256(file.path),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        );
        expect(
          await hashFileSha256('${tempDir.path}${Platform.pathSeparator}none'),
          isNull,
        );
        expect(await hashFileSha256('  '), isNull);
      },
    );
  });

  group('writeTelemetryAtomically', () {
    test('replaces an existing file and leaves no temp file', () async {
      final target = File(
        '${tempDir.path}${Platform.pathSeparator}ride_x.telemetry.json',
      );
      await target.writeAsString('old');
      await writeTelemetryAtomically(telemetryFile: target, content: 'new');

      expect(await target.readAsString(), 'new');
      final names = tempDir.listSync().map((entity) => entity.path).toList();
      expect(names, <String>[target.path]);
    });

    test('concurrent writes never lose the target file', () async {
      final target = File(
        '${tempDir.path}${Platform.pathSeparator}nested${Platform.pathSeparator}ride_y.telemetry.json',
      );
      final contents = List<String>.generate(40, (index) => 'content-$index');

      for (var round = 0; round < 5; round++) {
        await Future.wait(
          contents.map(
            (content) => writeTelemetryAtomically(
              telemetryFile: target,
              content: content,
            ),
          ),
        );
        expect(await target.exists(), isTrue);
        expect(contents, contains(await target.readAsString()));
      }

      final leftovers = target.parent
          .listSync()
          .where((entity) => entity.path != target.path)
          .toList();
      expect(leftovers, isEmpty);
    });
  });

  group('runExclusiveForPath', () {
    test('runs actions for the same path one at a time, in order', () async {
      final log = <String>[];
      Future<int> step(String name, int delayMs) async {
        log.add('start $name');
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        log.add('end $name');
        return delayMs;
      }

      final results = await Future.wait(<Future<int>>[
        runExclusiveForPath('p', () => step('a', 30)),
        runExclusiveForPath('p', () => step('b', 1)),
      ]);
      expect(results, <int>[30, 1]);
      expect(log, <String>['start a', 'end a', 'start b', 'end b']);
    });

    test('a failing action does not block later ones', () async {
      await expectLater(
        runExclusiveForPath<void>('q', () async => throw StateError('boom')),
        throwsStateError,
      );
      expect(await runExclusiveForPath('q', () async => 7), 7);
    });
  });

  group('telemetry temp files', () {
    test('recognises current and legacy temp names only', () {
      expect(isTelemetryTempFilePath('/r/ride_1.telemetry.json.tmp'), isTrue);
      expect(
        isTelemetryTempFilePath('/r/ride_1.telemetry.json.12-345-0.tmp'),
        isTrue,
      );
      expect(isTelemetryTempFilePath('/r/ride_1.telemetry.json'), isFalse);
      expect(isTelemetryTempFilePath('/r/video.tmp'), isFalse);
    });

    test('pruneStaleTelemetryTempFiles deletes only old temp files', () async {
      final sep = Platform.pathSeparator;
      final stale = File(
        '${tempDir.path}${sep}ride_1.telemetry.json.1-2-3.tmp',
      );
      final fresh = File(
        '${tempDir.path}${sep}ride_2.telemetry.json.4-5-6.tmp',
      );
      final ride = File('${tempDir.path}${sep}ride_1.telemetry.json');
      for (final file in <File>[stale, fresh, ride]) {
        await file.writeAsString('x');
      }
      await stale.setLastModified(
        DateTime.now().subtract(const Duration(hours: 1)),
      );

      expect(await pruneStaleTelemetryTempFiles(tempDir), 1);
      expect(await stale.exists(), isFalse);
      expect(await fresh.exists(), isTrue);
      expect(await ride.exists(), isTrue);
    });
  });
}
