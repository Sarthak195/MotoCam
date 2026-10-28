import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/core/ride_file/ride_telemetry_codec.dart';
import 'package:motocam/core/utils/integrity_utils.dart';
import 'package:motocam/features/history/models/ride_history_loader.dart';
import 'package:motocam/features/history/models/ride_index.dart';
import 'package:motocam/features/history/models/ride_record.dart';

void main() {
  late Directory directory;
  final sep = Platform.pathSeparator;

  // Stamps come from this map, never from the OS, so the tests do not
  // depend on how a platform reports modification or change times.
  late Map<String, RideFileStamp> stamps;
  late List<String> statCalls;

  Future<RideFileStamp?> fakeStat(String path) async {
    statCalls.add(path);
    if (!File(path).existsSync()) {
      return null;
    }
    return stamps[path] ??
        const RideFileStamp(size: 1, modifiedUs: 10, changedUs: 20);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('motocam_index_');
    stamps = <String, RideFileStamp>{};
    statCalls = <String>[];
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

  Future<File> writeRide(String id, List<File> segments) async {
    final payload = <String, dynamic>{
      'schemaVersion': 3,
      'rideSessionId': id,
      'sessionComplete': true,
      'videoPath': segments.last.path,
      'segmentPaths': segments.map((file) => file.path).toList(),
      'lockedSegmentPaths': <String>[segments.first.path],
      'segmentTimeline': <Map<String, dynamic>>[
        for (var i = 0; i < segments.length; i++)
          <String, dynamic>{
            'path': segments[i].path,
            'startMs': i * 1000,
            'endMs': (i + 1) * 1000,
          },
      ],
      'startedAt': '2026-05-03T10:00:00.000Z',
      'distanceKm': 1.5,
      'maxSpeedKmh': 40.0,
      'averageSpeedKmh': 20.0,
      'mockLocationDetected': false,
      'incidents': <Map<String, dynamic>>[
        <String, dynamic>{
          'elapsedMs': 1500,
          'timestamp': '2026-05-03T10:00:01.500Z',
          'gForce': 3.2,
          'reason': 'auto-crash',
        },
      ],
      'samples': <Map<String, dynamic>>[
        <String, dynamic>{'elapsedMs': 0, 'timestamp': '2026-05-03T10:00:00Z'},
        <String, dynamic>{
          'elapsedMs': 1900,
          'timestamp': '2026-05-03T10:00:01Z',
        },
      ],
    };
    final hashes = <String, String>{
      for (final file in segments)
        file.path: (await hashFileSha256(file.path))!,
    };
    return writeFile(
      'ride_$id.telemetry.json',
      jsonEncode(<String, dynamic>{
        ...payload,
        'integrity': buildIntegrityEnvelope(
          payload: payload,
          segmentHashes: hashes,
          segmentCount: segments.length,
        ),
      }),
    );
  }

  List<String> listing() =>
      directory.listSync().map((entity) => entity.path).toList()..sort();

  RideIndex indexOf(RideHistoryLoad load) =>
      RideIndex(rides: Map<String, RideIndexEntry>.of(load.rideEntries));

  group('ride index loading', () {
    test('a miss decodes the file and a hit reuses the entry without '
        'reading it', () async {
      final a = await writeFile('REC1.mp4', 'one');
      final b = await writeFile('REC2.mp4', 'two');
      final telemetry = await writeRide('a', <File>[a, b]);

      final first = await loadRideHistoryIndexed(listing(), stat: fakeStat);
      expect(first.decodedPaths, <String>[telemetry.path]);
      final decoded = first.rides.single;
      expect(decoded.samplesLoaded, isFalse);
      expect(decoded.sampleCount, 2);

      // The stamp stays the same, so the file must not be read again: even
      // garbage content is not noticed.
      await telemetry.writeAsString('{not json');
      statCalls.clear();
      final second = await loadRideHistoryIndexed(
        listing(),
        index: indexOf(first),
        stat: fakeStat,
      );
      expect(second.decodedPaths, isEmpty);
      // One stat for the ride file, one per segment.
      expect(statCalls.where((path) => path == telemetry.path), hasLength(1));

      final cached = second.rides.single;
      expect(cached.samplesLoaded, isFalse);
      expect(cached.samples, isEmpty);
      expect(cached.telemetryPath, telemetry.path);
      expect(cached.videoPath, decoded.videoPath);
      expect(cached.segmentPaths, decoded.segmentPaths);
      expect(cached.lockedSegmentPaths, decoded.lockedSegmentPaths);
      expect(cached.missingSegmentPaths, decoded.missingSegmentPaths);
      expect(cached.createdAt, decoded.createdAt);
      expect(cached.sampleCount, 2);
      expect(cached.duration, const Duration(milliseconds: 1900));
      expect(cached.integrity.status, RideIntegrityStatus.verified);
      expect(cached.expectedSegmentHashes, decoded.expectedSegmentHashes);
      expect(cached.incidents!.single.reason, 'auto-crash');
      expect(cached.segmentTimeline.last.endMs, 2000);
    });

    test('the index survives a JSON round trip', () async {
      final a = await writeFile('REC1.mp4', 'one');
      await writeRide('a', <File>[a]);
      final first = await loadRideHistoryIndexed(listing(), stat: fakeStat);

      final parsed = RideIndex.parse(jsonEncode(indexOf(first).toJson()));
      final again = await loadRideHistoryIndexed(
        listing(),
        index: parsed,
        stat: fakeStat,
      );
      expect(again.decodedPaths, isEmpty);
      final ride = again.rides.single;
      final original = first.rides.single;
      expect(ride.createdAt, original.createdAt);
      expect(ride.distanceKm, original.distanceKm);
      expect(ride.rideSessionId, original.rideSessionId);
      expect(ride.isSessionComplete, original.isSessionComplete);
      expect(ride.incidents!.single.gForce, 3.2);
      expect(
        ride.incidents!.single.timestamp,
        original.incidents!.single.timestamp,
      );
    });

    for (final change in <String, RideFileStamp>{
      'size': const RideFileStamp(size: 2, modifiedUs: 10, changedUs: 20),
      'modified time': const RideFileStamp(
        size: 1,
        modifiedUs: 11,
        changedUs: 20,
      ),
      'changed time': const RideFileStamp(
        size: 1,
        modifiedUs: 10,
        changedUs: 21,
      ),
    }.entries) {
      test('an entry whose ${change.key} differs is decoded again', () async {
        final a = await writeFile('REC1.mp4', 'one');
        final telemetry = await writeRide('a', <File>[a]);
        final first = await loadRideHistoryIndexed(listing(), stat: fakeStat);

        stamps[telemetry.path] = change.value;
        final second = await loadRideHistoryIndexed(
          listing(),
          index: indexOf(first),
          stat: fakeStat,
        );
        expect(second.decodedPaths, <String>[telemetry.path]);
        expect(
          second.rideEntries[rideIndexKey(telemetry.path)]!.stamp,
          change.value,
        );
      });
    }

    test('a segment that disappeared makes the entry stale', () async {
      final a = await writeFile('REC1.mp4', 'one');
      final b = await writeFile('REC2.mp4', 'two');
      final telemetry = await writeRide('a', <File>[a, b]);
      final first = await loadRideHistoryIndexed(listing(), stat: fakeStat);

      await a.delete();
      final second = await loadRideHistoryIndexed(
        listing(),
        index: indexOf(first),
        stat: fakeStat,
      );
      expect(second.decodedPaths, <String>[telemetry.path]);
      expect(second.rides.single.missingSegmentPaths, <String>[a.path]);
    });

    test('entries of vanished ride files are dropped', () async {
      final a = await writeFile('REC1.mp4', 'one');
      final b = await writeFile('REC2.mp4', 'two');
      final kept = await writeRide('a', <File>[a]);
      final gone = await writeRide('b', <File>[b]);
      final paths = listing();
      final first = await loadRideHistoryIndexed(paths, stat: fakeStat);
      expect(first.rideEntries.keys, hasLength(2));

      await gone.delete();
      // The listing still names the file (it vanished after the listing).
      final second = await loadRideHistoryIndexed(
        paths,
        index: indexOf(first),
        stat: fakeStat,
      );
      expect(second.rideEntries.keys, <String>[rideIndexKey(kept.path)]);
      // REC2.mp4 is now an orphan video.
      expect(
        second.rides.map((ride) => ride.telemetryPath),
        unorderedEquals(<String?>[kept.path, null]),
      );
    });

    test('a corrupt or older-format index is ignored and rebuilt', () async {
      final a = await writeFile('REC1.mp4', 'one');
      final telemetry = await writeRide('a', <File>[a]);
      final first = await loadRideHistoryIndexed(listing(), stat: fakeStat);
      final valid = indexOf(first).toJson();

      final indexDir = await Directory.systemTemp.createTemp('motocam_idx_');
      addTearDown(() => indexDir.delete(recursive: true));
      final indexFile = File('${indexDir.path}${sep}ride_index.json');

      for (final content in <String>[
        '{not json',
        '[]',
        '',
        jsonEncode(<String, dynamic>{...valid, 'format': 0}),
        jsonEncode(<String, dynamic>{...valid, 'format': '1'}),
        jsonEncode(<String, dynamic>{...valid, 'rides': 'nope'}),
      ]) {
        await indexFile.writeAsString(content);
        expect(RideIndex.parse(content).rides, isEmpty);
        final load = await loadRideHistoryIndexed(
          listing(),
          indexFilePath: indexFile.path,
          stat: fakeStat,
        );
        expect(load.decodedPaths, <String>[telemetry.path], reason: content);
        expect(load.rides, hasLength(1));
      }

      // A malformed entry is skipped; the others are kept.
      final mixed = <String, dynamic>{
        ...valid,
        'rides': <String, dynamic>{
          ...valid['rides'] as Map<String, dynamic>,
          'other': <String, dynamic>{'path': 3},
        },
        'segmentHashes': <String, dynamic>{
          'x': <String, dynamic>{'size': 'big'},
        },
      };
      final parsed = RideIndex.parse(jsonEncode(mixed));
      expect(parsed.rides.keys, <String>[rideIndexKey(telemetry.path)]);
      expect(parsed.segmentHashes, isEmpty);

      // A missing file is an empty index too.
      expect(
        (await RideIndex.readFile('${indexDir.path}${sep}none.json')).rides,
        isEmpty,
      );
    });

    test('a populated index crosses into a background isolate', () async {
      final a = await writeFile('REC1.mp4', 'one');
      await writeRide('a', <File>[a]);
      final paths = listing();
      final first = await loadRideHistoryIndexed(paths);
      final parsed = RideIndex.parse(jsonEncode(indexOf(first).toJson()));

      final load = await Isolate.run(
        () => loadRideHistoryIndexed(paths, index: parsed),
      );
      expect(load.decodedPaths, isEmpty);
      expect(load.rides.single.createdAt, first.rides.single.createdAt);
      expect(load.videoChecks.values.single.total, 1);
      expect(load.videoChecks.values.single.checked, 0);
    });

    test('loading reads the index file but never writes it', () async {
      final a = await writeFile('REC1.mp4', 'one');
      await writeRide('a', <File>[a]);
      final first = await loadRideHistoryIndexed(listing(), stat: fakeStat);
      final indexDir = await Directory.systemTemp.createTemp('motocam_idx_');
      addTearDown(() => indexDir.delete(recursive: true));
      final indexFile = File('${indexDir.path}${sep}ride_index.json');
      final content = jsonEncode(indexOf(first).toJson());
      await indexFile.writeAsString(content);

      final load = await loadRideHistoryIndexed(
        listing(),
        indexFilePath: indexFile.path,
        stat: fakeStat,
      );
      expect(load.decodedPaths, isEmpty);
      expect(await indexFile.readAsString(), content);
      expect(indexDir.listSync(), hasLength(1));
    });
  });

  group('RideIndexStore', () {
    late Directory indexDir;
    late File indexFile;

    setUp(() async {
      indexDir = await Directory.systemTemp.createTemp('motocam_store_');
      indexFile = File('${indexDir.path}${sep}ride_index${sep}ride_index.json');
    });

    tearDown(() async {
      if (await indexDir.exists()) {
        await indexDir.delete(recursive: true);
      }
    });

    SegmentHashEntry hashEntry(String sha) => SegmentHashEntry(
      stamp: const RideFileStamp(size: 1, modifiedUs: 2, changedUs: 3),
      expectedHash: sha,
      sha256: sha,
    );

    test('concurrent updates are all written by the one store', () async {
      final store = RideIndexStore(indexFile);
      await Future.wait(<Future<void>>[
        for (var i = 0; i < 5; i++)
          store.update(
            (index) => index.segmentHashes['seg$i'] = hashEntry('h$i'),
          ),
      ]);

      final reread = await RideIndexStore(indexFile).read();
      expect(reread.segmentHashes.keys, <String>[
        'seg0',
        'seg1',
        'seg2',
        'seg3',
        'seg4',
      ]);
      // Only the index file is left; every temp file was renamed away.
      expect(indexFile.parent.listSync(), hasLength(1));
      expect(
        (jsonDecode(await indexFile.readAsString()) as Map)['format'],
        rideIndexFormatVersion,
      );
    });

    test('an adopted index is used instead of reading the file', () async {
      await indexFile.parent.create(recursive: true);
      await indexFile.writeAsString(
        jsonEncode(
          RideIndex(
            segmentHashes: <String, SegmentHashEntry>{'old': hashEntry('o')},
          ).toJson(),
        ),
      );
      final adopted = RideIndex(
        segmentHashes: <String, SegmentHashEntry>{'new': hashEntry('n')},
      );
      final store = RideIndexStore(indexFile);
      expect(identical(await store.read(adopt: adopted), adopted), isTrue);
      // Once loaded, a later adoption does not replace the memory copy.
      expect(identical(await store.read(adopt: RideIndex()), adopted), isTrue);
    });

    test('the first read removes stale temp files of the index', () async {
      await indexFile.parent.create(recursive: true);
      final stale = File('${indexFile.path}.1-2-3.tmp');
      final fresh = File('${indexFile.path}.4-5-6.tmp');
      final other = File('${indexFile.parent.path}${sep}other.tmp');
      for (final file in <File>[stale, fresh, other]) {
        await file.writeAsString('x');
      }
      await stale.setLastModified(
        DateTime.now().subtract(const Duration(hours: 1)),
      );
      await other.setLastModified(
        DateTime.now().subtract(const Duration(hours: 1)),
      );

      await RideIndexStore(indexFile).read();
      // The prune runs alongside the read; give it a moment to finish.
      for (var i = 0; i < 50 && stale.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(stale.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
      expect(other.existsSync(), isTrue);
    });

    test('a corrupt index file starts an empty index', () async {
      await indexFile.parent.create(recursive: true);
      await indexFile.writeAsString('garbage');
      final store = RideIndexStore(indexFile);
      expect((await store.read()).rides, isEmpty);
      await store.update((index) => index.segmentHashes['a'] = hashEntry('x'));
      expect(
        RideIndex.parse(await indexFile.readAsString()).segmentHashes.keys,
        <String>['a'],
      );
    });

    test('pruneSegmentHashes keeps only segments of indexed rides', () {
      final ride = RideRecord(
        videoPath: '${sep}r${sep}a.mp4',
        segmentPaths: <String>['${sep}r${sep}a.mp4'],
        lockedSegmentPaths: const <String>[],
        createdAt: DateTime(2026),
        telemetryPath: '${sep}r${sep}a.telemetry.json',
        rideSessionId: null,
        isSessionComplete: true,
        distanceKm: 0,
        maxSpeedKmh: 0,
        averageSpeedKmh: 0,
        segmentTimeline: const <RideSegmentTimelineEntry>[],
        samples: const [],
        samplesLoaded: false,
        integrity: const RideIntegrityReport.unknown(),
        quarantinedSegmentPaths: const <String>[],
      );
      final index = RideIndex(
        rides: <String, RideIndexEntry>{
          'r': RideIndexEntry(
            path: ride.telemetryPath!,
            stamp: const RideFileStamp(size: 1, modifiedUs: 1, changedUs: 1),
            ride: ride,
          ),
        },
        segmentHashes: <String, SegmentHashEntry>{
          rideIndexKey('${sep}r${sep}a.mp4'): hashEntry('a'),
          rideIndexKey('${sep}r${sep}gone.mp4'): hashEntry('b'),
        },
      );
      index.pruneSegmentHashes();
      expect(index.segmentHashes.keys, <String>[
        rideIndexKey('${sep}r${sep}a.mp4'),
      ]);
    });
  });
}
