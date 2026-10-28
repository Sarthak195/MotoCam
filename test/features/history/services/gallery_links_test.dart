import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/features/history/models/ride_record.dart';
import 'package:motocam/features/history/services/gallery_links.dart';

final String _sep = Platform.pathSeparator;

GalleryLink _link(String? id, String name, {String? uri}) => GalleryLink(
  rideSessionId: id,
  fileName: name,
  contentUri: uri ?? 'content://media/external/video/media/$name',
  displayName: name,
  relativePath: 'Movies/MotoCam/Recordings',
  exportedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
);

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('motocam_gallery_links_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  File storeFile() =>
      File('${temp.path}${_sep}gallery_links$_sep$galleryLinksFileName');

  test('keys use the ride id and file name, or the file name alone', () {
    expect(galleryLinkKey(rideSessionId: 'r1', fileName: 'a.mp4'), 'r1|a.mp4');
    expect(galleryLinkKey(rideSessionId: null, fileName: 'a.mp4'), 'a.mp4');
    expect(galleryLinkKey(rideSessionId: '  ', fileName: 'a.mp4'), 'a.mp4');
  });

  test('round trip through the file in a new store', () async {
    final store = GalleryLinkStore(storeFile());
    final pending = PendingGalleryExport(
      rideSessionId: 'r1',
      fileName: 'b.mp4',
      sourcePath: '/x/b.mp4',
      queuedAt: DateTime.fromMillisecondsSinceEpoch(1700000001000),
      attempts: 2,
    );
    final written = await store.update((data) {
      data.links['r1|a.mp4'] = _link('r1', 'a.mp4');
      data.links['lone.mp4'] = _link(null, 'lone.mp4');
      data.pending[pending.key] = pending;
    });
    expect(written, isTrue);

    final reread = await GalleryLinkStore(storeFile()).read();
    expect(reread.links.keys, <String>['r1|a.mp4', 'lone.mp4']);
    final link = reread.links['r1|a.mp4']!;
    expect(link.contentUri, 'content://media/external/video/media/a.mp4');
    expect(link.relativePath, 'Movies/MotoCam/Recordings');
    expect(link.exportedAt.millisecondsSinceEpoch, 1700000000000);
    expect(reread.links['lone.mp4']!.rideSessionId, isNull);
    final entry = reread.pending['r1|b.mp4']!;
    expect(entry.sourcePath, '/x/b.mp4');
    expect(entry.attempts, 2);
    expect(entry.queuedAt.millisecondsSinceEpoch, 1700000001000);
  });

  test('a corrupt or foreign file reads as empty and is replaced', () async {
    final file = storeFile();
    await file.parent.create(recursive: true);
    for (final content in <String>[
      'not json {',
      '[]',
      jsonEncode(<String, Object?>{'format': 99, 'links': <String, Object?>{}}),
    ]) {
      await file.writeAsString(content);
      final data = await GalleryLinkStore(file).read();
      expect(data.links, isEmpty, reason: content);
      expect(data.pending, isEmpty, reason: content);
    }

    final store = GalleryLinkStore(file);
    await store.update((data) => data.links['r|a.mp4'] = _link('r', 'a.mp4'));
    expect(
      GalleryLinkData.parse(await file.readAsString()).links.keys,
      <String>['r|a.mp4'],
    );
  });

  test('a malformed entry is skipped and entries are re-keyed', () {
    final data = GalleryLinkData.parse(
      jsonEncode(<String, Object?>{
        'format': galleryLinksFormatVersion,
        'links': <String, Object?>{
          'wrong key': _link('r', 'a.mp4').toJson(),
          'bad': <String, Object?>{'fileName': 'b.mp4'},
          'worse': 7,
        },
        'pending': <String, Object?>{
          'p': <String, Object?>{
            'rideSessionId': 'r',
            'fileName': 'c.mp4',
            'sourcePath': '/c.mp4',
            'queuedAtMs': 1,
            // An extra field from a newer version is ignored.
            'future': true,
          },
          'q': <String, Object?>{'fileName': 'd.mp4'},
        },
      }),
    );
    expect(data.links.keys, <String>['r|a.mp4']);
    expect(data.pending.keys, <String>['r|c.mp4']);
    expect(data.pending['r|c.mp4']!.attempts, 0);
  });

  test('a missing file reads as empty', () async {
    final data = await GalleryLinkStore(storeFile()).read();
    expect(data.links, isEmpty);
    expect(data.pending, isEmpty);
  });

  group('galleryKeysOfRide', () {
    RideRecord ride({
      required String root,
      String? id = 'r1',
      List<String> quarantined = const <String>[],
    }) => RideRecord(
      videoPath: '$root${_sep}b.mp4',
      segmentPaths: <String>['$root${_sep}a.mp4', '$root${_sep}b.mp4'],
      lockedSegmentPaths: const <String>[],
      createdAt: DateTime(2026),
      telemetryPath: '$root${_sep}ride_r1.telemetry.json',
      rideSessionId: id,
      isSessionComplete: true,
      distanceKm: 0,
      maxSpeedKmh: 0,
      averageSpeedKmh: 0,
      segmentTimeline: const <RideSegmentTimelineEntry>[],
      samples: const [],
      integrity: const RideIntegrityReport.unknown(),
      quarantinedSegmentPaths: quarantined,
    );

    test('lists the videos, never the telemetry JSON', () {
      final keys = galleryKeysOfRide(ride(root: temp.path));
      expect(keys.keys, <String>['r1|a.mp4', 'r1|b.mp4']);
      expect(keys['r1|a.mp4'], '${temp.path}${_sep}a.mp4');
    });

    test('leaves out quarantined paths', () {
      final keys = galleryKeysOfRide(
        ride(
          root: temp.path,
          quarantined: <String>['${temp.path}${_sep}a.mp4'],
        ),
      );
      expect(keys.keys, <String>['r1|b.mp4']);
    });

    test('links of a ride are found by id and file name', () {
      final data = GalleryLinkData()
        ..links['r1|a.mp4'] = _link('r1', 'a.mp4')
        ..links['r2|b.mp4'] = _link('r2', 'b.mp4');
      expect(
        data.linksOfRide(ride(root: temp.path)).map((link) => link.key),
        <String>['r1|a.mp4'],
      );
    });
  });
}
