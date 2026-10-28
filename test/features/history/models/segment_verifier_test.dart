import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/core/ride_file/ride_telemetry_codec.dart';
import 'package:motocam/core/utils/integrity_utils.dart';
import 'package:motocam/features/history/models/ride_index.dart';
import 'package:motocam/features/history/models/ride_record.dart';
import 'package:motocam/features/history/models/segment_verifier.dart';

void main() {
  final sep = Platform.pathSeparator;
  late Directory directory;
  late File indexFile;
  late Map<String, RideFileStamp> stamps;
  late List<String> hashCalls;

  // Stamps come from this map, never from the OS.
  Future<RideFileStamp?> fakeStat(String path) async {
    if (!File(path).existsSync()) {
      return null;
    }
    return stamps[path] ??
        const RideFileStamp(size: 1, modifiedUs: 10, changedUs: 20);
  }

  Future<String?> countingHasher(String path) async {
    hashCalls.add(path);
    return hashFileSha256(path);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('motocam_verify_');
    indexFile = File('${directory.path}${sep}index${sep}ride_index.json');
    stamps = <String, RideFileStamp>{};
    hashCalls = <String>[];
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  Future<File> writeFile(String name, String content) async {
    final file = File('${directory.path}$sep$name');
    await file.writeAsString(content);
    return file;
  }

  Future<List<SegmentCheckTarget>> targetsFor(List<File> files) async => [
    for (final file in files)
      SegmentCheckTarget(
        path: file.path,
        expectedHash: (await hashFileSha256(file.path))!,
      ),
  ];

  SegmentVerifier verifierWith(RideIndexStore? store) =>
      SegmentVerifier(store: store, hasher: countingHasher, stat: fakeStat);

  group('orderSegmentsForCheck', () {
    test('puts the segment about to play first, then timeline order', () {
      final targets = orderSegmentsForCheck(
        timelineOrder: <String>['a', 'b', 'c', 'd'],
        expectedHashes: <String, String>{
          'd': 'hd',
          'c': 'hc',
          'a': 'ha',
          'b': 'hb',
          'e': 'he',
        },
        missing: <String>{'b'},
        first: 'c',
      );
      expect(targets.map((target) => target.path), <String>[
        'c',
        'a',
        'd',
        'e',
      ]);
      expect(targets.first.expectedHash, 'hc');
    });

    test('skips segments without a recorded hash', () {
      final targets = orderSegmentsForCheck(
        timelineOrder: <String>['a', 'b'],
        expectedHashes: <String, String>{'b': 'hb'},
        first: 'a',
      );
      expect(targets.map((target) => target.path), <String>['b']);
    });
  });

  group('SegmentVerifier', () {
    test('hashes each segment once, persists the results and reuses them '
        'after a restart', () async {
      final files = <File>[
        await writeFile('a.mp4', 'one'),
        await writeFile('b.mp4', 'two'),
        await writeFile('c.mp4', 'three'),
      ];
      final targets = await targetsFor(files);

      final seen = <String>[];
      final results = await verifierWith(
        RideIndexStore(indexFile),
      ).verify(targets, onResult: (result) => seen.add(result.path));
      expect(hashCalls, files.map((file) => file.path));
      expect(seen, files.map((file) => file.path));
      expect(
        results.map((result) => result.outcome),
        everyElement(SegmentCheckOutcome.verified),
      );

      // A new store reads the persisted results, as after an app restart.
      hashCalls.clear();
      final again = await verifierWith(
        RideIndexStore(indexFile),
      ).verify(targets);
      expect(hashCalls, isEmpty);
      expect(again.every((result) => result.fromCache), isTrue);
      expect(
        again.map((result) => result.outcome),
        everyElement(SegmentCheckOutcome.verified),
      );
    });

    test('hashes again only a segment whose stamp or expected hash '
        'changed', () async {
      final files = <File>[
        await writeFile('a.mp4', 'one'),
        await writeFile('b.mp4', 'two'),
        await writeFile('c.mp4', 'three'),
      ];
      final targets = await targetsFor(files);
      final store = RideIndexStore(indexFile);
      await verifierWith(store).verify(targets);
      hashCalls.clear();

      stamps[files[0].path] = const RideFileStamp(
        size: 1,
        modifiedUs: 10,
        changedUs: 99,
      );
      final changedTargets = <SegmentCheckTarget>[
        targets[0],
        SegmentCheckTarget(path: files[1].path, expectedHash: 'f' * 64),
        targets[2],
      ];
      final results = await verifierWith(store).verify(changedTargets);
      expect(hashCalls, <String>[files[0].path, files[1].path]);
      expect(results.map((result) => result.outcome), <SegmentCheckOutcome>[
        SegmentCheckOutcome.verified,
        SegmentCheckOutcome.mismatch,
        SegmentCheckOutcome.verified,
      ]);
      expect(results[1].issue, 'segment-hash-mismatch:${files[1].path}');
    });

    test('a stored mismatch stays a failure without hashing', () async {
      final file = await writeFile('a.mp4', 'one');
      final target = SegmentCheckTarget(path: file.path, expectedHash: 'bad');
      final store = RideIndexStore(indexFile);
      await verifierWith(store).verify(<SegmentCheckTarget>[target]);
      hashCalls.clear();

      final result = (await verifierWith(
        store,
      ).verify(<SegmentCheckTarget>[target])).single;
      expect(hashCalls, isEmpty);
      expect(result.outcome, SegmentCheckOutcome.mismatch);
      expect(result.fromCache, isTrue);
    });

    test('ignoreCache hashes every segment again', () async {
      final files = <File>[
        await writeFile('a.mp4', 'one'),
        await writeFile('b.mp4', 'two'),
      ];
      final targets = await targetsFor(files);
      final store = RideIndexStore(indexFile);
      await verifierWith(store).verify(targets);
      hashCalls.clear();

      await verifierWith(store).verify(targets, ignoreCache: true);
      expect(hashCalls, files.map((file) => file.path));
    });

    test('cancelling stops after the segment in flight, whose result is '
        'still stored', () async {
      final files = <File>[
        await writeFile('a.mp4', 'one'),
        await writeFile('b.mp4', 'two'),
        await writeFile('c.mp4', 'three'),
      ];
      final targets = await targetsFor(files);
      final token = SegmentCheckToken();
      final store = RideIndexStore(indexFile);
      final verifier = SegmentVerifier(
        store: store,
        stat: fakeStat,
        hasher: (path) async {
          hashCalls.add(path);
          // The screen is left while the first segment is being hashed.
          token.cancel();
          return hashFileSha256(path);
        },
      );

      final results = await verifier.verify(targets, token: token);
      expect(hashCalls, <String>[files[0].path]);
      expect(results, hasLength(1));
      final stored = RideIndex.parse(await indexFile.readAsString());
      expect(stored.segmentHashes.keys, <String>[rideIndexKey(files[0].path)]);
    });

    test('missing and unreadable segments', () async {
      final present = await writeFile('a.mp4', 'one');
      final verifier = SegmentVerifier(
        store: null,
        stat: fakeStat,
        hasher: (path) async => null,
      );
      final results = await verifier.verify(<SegmentCheckTarget>[
        SegmentCheckTarget(path: present.path, expectedHash: 'x'),
        SegmentCheckTarget(
          path: '${directory.path}${sep}gone.mp4',
          expectedHash: 'y',
        ),
      ]);
      expect(results.map((result) => result.outcome), <SegmentCheckOutcome>[
        SegmentCheckOutcome.unreadable,
        SegmentCheckOutcome.missing,
      ]);
      expect(results.first.issue, 'unreadable-segment-file:${present.path}');
      expect(results.last.issue, isNull);
    });
  });

  group('ride video check', () {
    RideRecord rideWith(
      Map<String, String> expected, {
      RideIntegrityStatus status = RideIntegrityStatus.verified,
      List<String> missing = const <String>[],
    }) => RideRecord(
      videoPath: expected.keys.last,
      segmentPaths: expected.keys.toList(),
      lockedSegmentPaths: const <String>[],
      createdAt: DateTime(2026),
      telemetryPath: '${directory.path}${sep}ride.telemetry.json',
      rideSessionId: null,
      isSessionComplete: true,
      distanceKm: 0,
      maxSpeedKmh: 0,
      averageSpeedKmh: 0,
      segmentTimeline: const <RideSegmentTimelineEntry>[],
      samples: const [],
      samplesLoaded: false,
      integrity: status == RideIntegrityStatus.verified
          ? const RideIntegrityReport.verified()
          : RideIntegrityReport.modified(const <String>['x']),
      quarantinedSegmentPaths: const <String>[],
      missingSegmentPaths: missing,
      expectedSegmentHashes: expected,
    );

    test('follows the stored results and the history text', () async {
      final files = <File>[
        await writeFile('a.mp4', 'one'),
        await writeFile('b.mp4', 'two'),
      ];
      final targets = await targetsFor(files);
      final ride = rideWith(<String, String>{
        for (final target in targets) target.path: target.expectedHash,
      });
      final store = RideIndexStore(indexFile);

      Future<RideVideoCheck> check() async => videoCheckFromIndex(
        ride: ride,
        index: await store.read(),
        stat: fakeStat,
      );

      var state = await check();
      expect(
        describeVideoCheck(state),
        'Videos not checked yet (open the '
        'ride to check)',
      );

      await verifierWith(store).verify(targets.sublist(0, 1));
      state = await check();
      expect(
        describeVideoCheck(state),
        'Videos: 1 of 2 segments checked, no failure so far (open the ride '
        'to finish)',
      );

      await verifierWith(store).verify(targets);
      state = await check();
      expect(state.isVerified, isTrue);
      expect(
        describeVideoCheck(state),
        'Videos verified: unmodified since recording',
      );

      // A segment changed since its check: no longer counted as checked.
      stamps[files[1].path] = const RideFileStamp(
        size: 2,
        modifiedUs: 10,
        changedUs: 20,
      );
      state = await check();
      expect(state.checked, 1);
      expect(state.isVerified, isFalse);

      await verifierWith(store).verify(<SegmentCheckTarget>[
        SegmentCheckTarget(path: files[1].path, expectedHash: 'bad'),
      ]);
      final failing = await videoCheckFromIndex(
        ride: rideWith(<String, String>{
          files[0].path: targets[0].expectedHash,
          files[1].path: 'bad',
        }),
        index: await store.read(),
        stat: fakeStat,
      );
      expect(
        describeVideoCheck(failing),
        'Videos: 1 of 2 segment(s) failed the check',
      );
    });

    test('says nothing for rides without hashes or with failed data', () async {
      final file = await writeFile('a.mp4', 'one');
      final index = RideIndex();
      for (final ride in <RideRecord>[
        rideWith(<String, String>{file.path: 'h'}, missing: [file.path]),
        rideWith(<String, String>{
          file.path: 'h',
        }, status: RideIntegrityStatus.modified),
      ]) {
        final state = await videoCheckFromIndex(
          ride: ride,
          index: index,
          stat: fakeStat,
        );
        expect(describeVideoCheck(state), isNull);
      }
    });
  });

  group('setLockState with stored segment results', () {
    late Directory rides;

    setUp(() async {
      rides = Directory('${directory.path}${sep}rides');
      await rides.create();
    });

    Future<File> writeSegment(String name, String content) async {
      final file = File('${rides.path}$sep$name');
      await file.writeAsString(content);
      return file;
    }

    Future<RideRecord> writeLockedRide(List<File> segments) async {
      final payload = <String, dynamic>{
        'schemaVersion': 3,
        'sessionComplete': true,
        'videoPath': segments.last.path,
        'segmentPaths': segments.map((file) => file.path).toList(),
        'lockedSegmentPaths': segments.map((file) => file.path).toList(),
        'startedAt': '2026-05-03T10:00:00.000Z',
        'samples': <Map<String, dynamic>>[],
      };
      final telemetry = File('${rides.path}${sep}ride_a.telemetry.json');
      await telemetry.writeAsString(
        jsonEncode(<String, dynamic>{
          ...payload,
          'integrity': buildIntegrityEnvelope(
            payload: payload,
            segmentHashes: <String, String>{
              for (final file in segments)
                file.path: (await hashFileSha256(file.path))!,
            },
            segmentCount: segments.length,
          ),
        }),
      );
      return (await RideRecord.fromTelemetryFile(
        telemetry,
        loadSamples: false,
      ))!;
    }

    test('reuses valid results and hashes only segments without one', () async {
      final segments = <File>[
        await writeSegment('a.mp4', 'one'),
        await writeSegment('b.mp4', 'two'),
        await writeSegment('c.mp4', 'three'),
      ];
      final ride = await writeLockedRide(segments);
      final store = RideIndexStore(indexFile);
      await verifierWith(
        store,
      ).verify(await targetsFor(segments.sublist(0, 2)));
      hashCalls.clear();

      var progress = 0;
      final unlocked = await ride.setLockState(
        false,
        hashSegment: verifierWith(
          store,
        ).lockHasher(onChecked: () => progress++),
      );
      expect(unlocked, isTrue);
      expect(hashCalls, <String>[segments[2].path]);
      expect(progress, 3);

      final reloaded = await RideRecord.fromTelemetryFile(
        File(ride.telemetryPath!),
      );
      expect(reloaded!.isLocked, isFalse);
      expect(reloaded.integrity.status, RideIntegrityStatus.verified);
    });

    test('still refuses a ride whose segment changed', () async {
      final segments = <File>[
        await writeSegment('a.mp4', 'one'),
        await writeSegment('b.mp4', 'two'),
      ];
      final ride = await writeLockedRide(segments);
      final store = RideIndexStore(indexFile);
      await verifierWith(store).verify(await targetsFor(segments));
      final before = await File(ride.telemetryPath!).readAsString();

      // The edit changes the stamp, so the stored result no longer applies.
      await segments[1].writeAsString('edited');
      stamps[segments[1].path] = const RideFileStamp(
        size: 6,
        modifiedUs: 10,
        changedUs: 30,
      );
      hashCalls.clear();
      expect(
        await ride.setLockState(
          false,
          hashSegment: verifierWith(store).lockHasher(),
        ),
        isFalse,
      );
      expect(hashCalls, <String>[segments[1].path]);
      expect(await File(ride.telemetryPath!).readAsString(), before);

      // The mismatch is now stored: a second attempt refuses without
      // hashing.
      hashCalls.clear();
      expect(
        await ride.setLockState(
          false,
          hashSegment: verifierWith(store).lockHasher(),
        ),
        isFalse,
      );
      expect(hashCalls, isEmpty);
    });
  });
}
