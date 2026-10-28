import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/ride_file/ride_telemetry_codec.dart';
import 'package:motocam/core/services/ride_signing_service.dart';
import 'package:motocam/features/history/models/ride_index.dart';
import 'package:motocam/features/history/models/ride_record.dart';
import 'package:motocam/features/history/services/gallery_links.dart';
import 'package:motocam/features/history/services/ride_deletion.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/test_signing_key.dart';

final String _sep = Platform.pathSeparator;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late Directory root;
  late Directory outside;
  late RideIndexStore store;
  final phone = TestSigningKey.generate(1);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = await Directory.systemTemp.createTemp('motocam_ride_delete_');
    root = Directory('${temp.path}${_sep}MotoCam Recordings')..createSync();
    outside = Directory('${temp.path}${_sep}elsewhere')..createSync();
    store = RideIndexStore(File('${temp.path}${_sep}index${_sep}index.json'));
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  File write(Directory dir, String name, [String content = 'video']) =>
      File('${dir.path}$_sep$name')..writeAsStringSync(content);

  Future<RideRecord> writeRide(
    String sessionId,
    List<String> segmentPaths, {
    String? fileName,
  }) async {
    final json = File(
      '${root.path}$_sep${fileName ?? rideTelemetryFileNameFor(sessionId)}',
    );
    await json.writeAsString(
      jsonEncode(<String, Object?>{
        'schemaVersion': 3,
        'rideSessionId': sessionId,
        'sessionComplete': true,
        'videoPath': segmentPaths.last,
        'segmentPaths': segmentPaths,
        'lockedSegmentPaths': <String>[],
        'startedAt': '2026-10-20T08:00:00.000Z',
        'samples': <Object?>[],
      }),
    );
    return (await RideRecord.fromTelemetryFile(json, loadSamples: false))!;
  }

  test('deletes the trusted files, the JSON last, and drops the index entry '
      'and the registration', () async {
    final a = write(root, 'a.mp4');
    final b = write(root, 'b.mp4');
    final ride = await writeRide('ride-1', <String>[a.path, b.path]);
    final registry = SignedRideRegistry();
    await registry.add(phone.publicKeyBase64, 'ride-1');
    await registry.add(phone.publicKeyBase64, 'ride-2');
    await store.update((index) {
      index.rides[rideIndexKey(ride.telemetryPath!)] = RideIndexEntry(
        path: ride.telemetryPath!,
        stamp: const RideFileStamp(size: 1, modifiedUs: 1, changedUs: 1),
        ride: ride,
      );
    });

    final files = filesOfRide(ride);
    expect(files.last, ride.telemetryPath);
    final result = await deleteRideFiles(
      ride,
      indexStore: store,
      galleryLinks: null,
      registry: registry,
    );

    expect(result.failed, 0);
    expect(result.rideFileRemoved, isTrue);
    expect(result.deletedPaths, hasLength(3));
    expect(a.existsSync(), isFalse);
    expect(b.existsSync(), isFalse);
    expect(File(ride.telemetryPath!).existsSync(), isFalse);
    expect((await store.read()).rides, isEmpty);
    expect(await registry.idsFor(phone.publicKeyBase64), <String>{'ride-2'});
  });

  test('never deletes a quarantined or out-of-root path', () async {
    final inside = write(root, 'in.mp4');
    final elsewhere = write(outside, 'out.mp4');
    final ride = await writeRide('ride-q', <String>[
      inside.path,
      elsewhere.path,
    ]);
    expect(ride.quarantinedSegmentPaths, contains(elsewhere.path));
    expect(filesOfRide(ride), isNot(contains(elsewhere.path)));

    // A record that lists the outside file as a segment (a hand-built or
    // stale record) still does not reach outside its JSON's directory.
    final forged = RideRecord(
      videoPath: elsewhere.path,
      segmentPaths: <String>[inside.path, elsewhere.path],
      lockedSegmentPaths: const <String>[],
      createdAt: DateTime(2026),
      telemetryPath: ride.telemetryPath,
      rideSessionId: 'ride-q',
      isSessionComplete: true,
      distanceKm: 0,
      maxSpeedKmh: 0,
      averageSpeedKmh: 0,
      segmentTimeline: const <RideSegmentTimelineEntry>[],
      samples: const [],
      integrity: const RideIntegrityReport.unknown(),
      quarantinedSegmentPaths: const <String>[],
    );
    expect(filesOfRide(forged), isNot(contains(elsewhere.path)));

    await deleteRideFiles(ride, indexStore: null, galleryLinks: null);
    expect(inside.existsSync(), isFalse);
    expect(elsewhere.existsSync(), isTrue);
  });

  test(
    'a copy carrying another ride\'s id leaves that ride registered',
    () async {
      final a = write(root, 'copy.mp4');
      final copy = await writeRide('ride-1', <String>[
        a.path,
      ], fileName: 'ride_copy.telemetry.json');
      final registry = SignedRideRegistry();
      await registry.add(phone.publicKeyBase64, 'ride-1');

      final result = await deleteRideFiles(
        copy,
        indexStore: store,
        galleryLinks: null,
        registry: registry,
      );
      expect(result.rideFileRemoved, isTrue);
      expect(await registry.idsFor(phone.publicKeyBase64), <String>{'ride-1'});
    },
  );

  test(
    'a video-only ride deletes its video and touches no index entry',
    () async {
      final video = write(root, 'lone.mp4');
      final ride = await RideRecord.fromVideoFile(video, loadSamples: false);
      final other = await writeRide('ride-9', <String>[
        write(root, 'x.mp4').path,
      ]);
      await store.update((index) {
        index.rides[rideIndexKey(other.telemetryPath!)] = RideIndexEntry(
          path: other.telemetryPath!,
          stamp: const RideFileStamp(size: 1, modifiedUs: 1, changedUs: 1),
          ride: other,
        );
      });

      final result = await deleteRideFiles(
        ride,
        indexStore: store,
        galleryLinks: null,
      );
      expect(result.deletedPaths, <String>[video.path]);
      expect(result.rideFileRemoved, isTrue);
      expect((await store.read()).rides.keys, <String>[
        rideIndexKey(other.telemetryPath!),
      ]);
    },
  );

  test(
    'drops the deleted ride\'s gallery links and pending exports only',
    () async {
      final a = write(root, 'ga.mp4');
      final b = write(root, 'gb.mp4');
      final ride = await writeRide('ride-g', <String>[a.path, b.path]);
      final links = GalleryLinkStore(
        File('${temp.path}${_sep}links${_sep}gallery_links.json'),
      );
      GalleryLink link(String? id, String name) => GalleryLink(
        rideSessionId: id,
        fileName: name,
        contentUri: 'content://media/external/video/media/$name',
        displayName: name,
        relativePath: 'Movies/MotoCam/Recordings',
        exportedAt: DateTime(2026),
      );
      await links.update((data) {
        data.links[galleryLinkKey(
          rideSessionId: 'ride-g',
          fileName: 'ga.mp4',
        )] = link(
          'ride-g',
          'ga.mp4',
        );
        data.links[galleryLinkKey(rideSessionId: 'other', fileName: 'ga.mp4')] =
            link('other', 'ga.mp4');
        final pending = PendingGalleryExport(
          rideSessionId: 'ride-g',
          fileName: 'gb.mp4',
          sourcePath: b.path,
          queuedAt: DateTime(2026),
        );
        data.pending[pending.key] = pending;
      });

      final result = await deleteRideFiles(
        ride,
        indexStore: null,
        galleryLinks: links,
      );
      expect(result.rideFileRemoved, isTrue);
      final data = await links.read();
      expect(data.links.keys, <String>['other|ga.mp4']);
      expect(data.pending, isEmpty);
      // The file was written, so a new process sees the same.
      final reread = GalleryLinkData.parse(await links.file.readAsString());
      expect(reread.links.keys, <String>['other|ga.mp4']);
    },
  );
}
