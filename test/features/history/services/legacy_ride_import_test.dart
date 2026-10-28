import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/ride_file/ride_telemetry_codec.dart';
import 'package:motocam/core/services/legacy_recordings_access.dart';
import 'package:motocam/core/utils/path_utils.dart' as path_utils;
import 'package:motocam/features/history/models/ride_record.dart';
import 'package:motocam/features/history/services/legacy_ride_import.dart';

final String _sep = Platform.pathSeparator;

/// The picked folder, backed by a real directory (the fake public folder).
class _FakeSource implements LegacyRideDocumentSource {
  _FakeSource(this.folder);

  final Directory folder;
  final List<String> copied = <String>[];
  final List<String> deleted = <String>[];
  final Set<String> failCopy = <String>{};
  final Set<String> failDelete = <String>{};
  final Map<String, int> reportedSizes = <String, int>{};
  bool _cancel = false;
  void Function(String name)? onCopyChunk;

  @override
  Future<List<LegacyRideDocument>> list() async => <LegacyRideDocument>[
    for (final entity
        in folder.listSync()..sort((a, b) => a.path.compareTo(b.path)))
      if (entity is File)
        LegacyRideDocument(
          uri: 'content://tree/${path_utils.fileNameFromPath(entity.path)}',
          name: path_utils.fileNameFromPath(entity.path),
          size:
              reportedSizes[path_utils.fileNameFromPath(entity.path)] ??
              entity.lengthSync(),
        ),
  ];

  @override
  Future<int> copyTo(LegacyRideDocument document, String targetPath) async {
    _cancel = false;
    if (failCopy.contains(document.name)) {
      throw const FileSystemException('injected copy failure');
    }
    final bytes = File('${folder.path}$_sep${document.name}').readAsBytesSync();
    final output = File(targetPath).openSync(mode: FileMode.write);
    try {
      for (var offset = 0; offset < bytes.length; offset += 64) {
        onCopyChunk?.call(document.name);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (_cancel) {
          throw const LegacyCopyCancelled();
        }
        final end = offset + 64 > bytes.length ? bytes.length : offset + 64;
        output.writeFromSync(bytes, offset, end);
      }
    } finally {
      output.closeSync();
    }
    copied.add(document.name);
    return bytes.length;
  }

  @override
  Future<void> cancelCopy() async {
    _cancel = true;
  }

  @override
  Future<List<String>> delete(List<LegacyRideDocument> documents) async {
    final failed = <String>[];
    for (final document in documents) {
      if (failDelete.contains(document.name)) {
        failed.add(document.uri);
        continue;
      }
      File('${folder.path}$_sep${document.name}').deleteSync();
      deleted.add(document.name);
    }
    return failed;
  }
}

void main() {
  late Directory temp;
  late Directory public;
  late Directory root;
  late String work;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('motocam_import_');
    public = await Directory(
      '${temp.path}${_sep}storage${_sep}Movies${_sep}MotoCam${_sep}Recordings',
    ).create(recursive: true);
    root = await Directory(
      '${temp.path}${_sep}files${_sep}MotoCam Recordings',
    ).create(recursive: true);
    work = '${temp.path}${_sep}files${_sep}ride_import';
    debugLegacyPublicRecordingsDirectoryOverride = public.path;
  });

  tearDown(() async {
    debugLegacyPublicRecordingsDirectoryOverride = null;
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  File writePublic(String name, String content) =>
      File('${public.path}$_sep$name')..writeAsStringSync(content);

  /// A v0.1.12 ride: schema 2, absolute public paths, no envelope.
  File writeV012Ride(
    String id,
    List<String> segments, {
    List<String> locked = const <String>[],
    List<String> missing = const <String>[],
  }) {
    for (final name in segments) {
      if (!missing.contains(name)) {
        writePublic(name, 'video:$name:${'x' * 20}');
      }
    }
    String declared(String name) => '${public.path}$_sep$name';
    final json = <String, Object?>{
      'schemaVersion': 2,
      'rideSessionId': id,
      'sessionComplete': true,
      'storagePolicy': 'public-folder-only',
      'storageDirectory': public.path,
      'videoPath': declared(segments.last),
      'segmentPaths': <String>[for (final s in segments) declared(s)],
      'lockedSegmentPaths': <String>[for (final s in locked) declared(s)],
      'segmentTimeline': <Object?>[],
      'startedAt': '2026-05-01T08:00:00.000',
      'endedAt': '2026-05-01T08:10:00.000',
      'distanceKm': 3.5,
      'maxSpeedKmh': 60.0,
      'averageSpeedKmh': 30.0,
      'samples': <Object?>[
        <String, Object?>{
          'latitude': 12.97,
          'longitude': 77.59,
          'speed': 10.0,
          'bearing': 0.0,
          'accelerationG': 0.1,
          'elapsedMs': 0,
          'distanceKm': 0.0,
          'timestamp': '2026-05-01T08:00:00.000',
        },
      ],
    };
    return writePublic('ride_$id.telemetry.json', jsonEncode(json));
  }

  LegacyRideImporter importer(
    _FakeSource source, {
    bool Function()? shouldPause,
    Future<int?> Function(String path)? freeBytes,
  }) => LegacyRideImporter(
    source: source,
    recordingsRoot: root.path,
    workDirectory: work,
    freeBytes: freeBytes ?? (_) async => null,
    reserveBytes: 10,
    shouldPause: shouldPause,
    pollInterval: const Duration(milliseconds: 1),
  );

  List<String> rootNames() =>
      root.listSync().map((e) => path_utils.fileNameFromPath(e.path)).toList()
        ..sort();

  test('imports rides (videos, then the JSON byte for byte) and lone '
      'videos', () async {
    final json = writeV012Ride('r1', <String>['a.mp4', 'b.mp4']);
    writePublic('lone.mp4', 'lone video');
    writePublic('notes.txt', 'ignored');
    final source = _FakeSource(public);

    final summary = await importer(source).run();

    expect(summary.outcome, LegacyImportOutcome.completed);
    expect(summary.total, 2);
    expect(summary.imported, 2);
    expect(summary.skipped, isEmpty);
    expect(rootNames(), <String>[
      'a.mp4',
      'b.mp4',
      'lone.mp4',
      'ride_r1.telemetry.json',
    ]);
    // The planning copy of the JSON comes first; the ride's own copy is
    // the last of its files.
    expect(source.copied, <String>[
      'ride_r1.telemetry.json',
      'a.mp4',
      'b.mp4',
      'ride_r1.telemetry.json',
      'lone.mp4',
    ]);
    expect(
      File('${root.path}${_sep}ride_r1.telemetry.json').readAsBytesSync(),
      json.readAsBytesSync(),
    );
    expect(summary.importedDocuments.map((d) => d.name).toSet(), <String>{
      'a.mp4',
      'b.mp4',
      'ride_r1.telemetry.json',
      'lone.mp4',
    });
    // Sources are never touched and staging is empty.
    expect(public.listSync(), hasLength(5));
    expect(Directory('$work${_sep}staging').existsSync(), isFalse);
    expect(summary.message, 'Imported 2 rides.');
  });

  test(
    'an imported ride reads the same with or without the originals',
    () async {
      writeV012Ride(
        'r2',
        <String>['s1.mp4', 's2.mp4', 'gone.mp4'],
        locked: <String>['s2.mp4'],
        missing: <String>['gone.mp4'],
      );
      final source = _FakeSource(public);
      await importer(source).run();
      final imported = File('${root.path}${_sep}ride_r2.telemetry.json');

      Future<Map<String, Object?>> read() async {
        final ride = await RideRecord.fromTelemetryFile(imported);
        String name(String path) => path_utils.fileNameFromPath(path);
        return <String, Object?>{
          'segments': ride!.segmentPaths.map(name).toList(),
          'inRoot': ride.segmentPaths.every(
            (p) => path_utils.isPathInsideDirectory(p, root.path),
          ),
          'missing': ride.missingSegmentPaths.map(name).toList(),
          'quarantined': ride.quarantinedSegmentPaths,
          'locked': ride.lockedSegmentPaths.map(name).toList(),
          'status': ride.integrity.status,
          'video': name(ride.videoPath),
          'samples': ride.samples.length,
        };
      }

      final withOriginals = await read();
      expect(withOriginals, <String, Object?>{
        'segments': <String>['s1.mp4', 's2.mp4', 'gone.mp4'],
        'inRoot': true,
        'missing': <String>['gone.mp4'],
        'quarantined': <String>[],
        'locked': <String>['s2.mp4'],
        'status': RideIntegrityStatus.unknown,
        'video': 'gone.mp4',
        'samples': 1,
      });

      final failed = await deleteImportedOriginals(
        source,
        (await source.list()).toList(),
      );
      expect(failed, isEmpty);
      expect(public.listSync(), isEmpty);
      expect(await read(), withOriginals);

      // Also with the real public path (which does not exist here).
      debugLegacyPublicRecordingsDirectoryOverride = null;
      final realJson = jsonDecode(imported.readAsStringSync()) as Map;
      realJson['segmentPaths'] = <String>[
        for (final n in <String>['s1.mp4', 's2.mp4', 'gone.mp4'])
          '$legacyPublicRecordingsDirectory/$n',
      ];
      realJson['videoPath'] = '$legacyPublicRecordingsDirectory/gone.mp4';
      realJson['lockedSegmentPaths'] = <String>[
        '$legacyPublicRecordingsDirectory/s2.mp4',
      ];
      imported.writeAsStringSync(jsonEncode(realJson));
      expect(await read(), withOriginals);
    },
  );

  test('same name and size counts as imported; a different file skips the '
      'whole ride', () async {
    writeV012Ride('r3', <String>['c.mp4', 'd.mp4']);
    writeV012Ride('r4', <String>['e.mp4']);
    final source = _FakeSource(public);
    // c.mp4 is already there (same size); e.mp4 is a different file.
    File(
      '${root.path}${_sep}c.mp4',
    ).writeAsBytesSync(File('${public.path}${_sep}c.mp4').readAsBytesSync());
    File('${root.path}${_sep}e.mp4').writeAsStringSync('another clip');

    final summary = await importer(source).run();
    expect(summary.imported, 1);
    expect(summary.collisions, 1);
    expect(summary.skipped.single.name, 'ride_r4.telemetry.json');
    expect(rootNames(), <String>[
      'c.mp4',
      'd.mp4',
      'e.mp4',
      'ride_r3.telemetry.json',
    ]);
    expect(source.copied, isNot(contains('c.mp4')));
    expect(
      summary.importedDocuments.map((d) => d.name),
      isNot(contains('e.mp4')),
    );
    expect(summary.message, contains('1 ride skipped'));

    // A second run finds everything in place.
    final again = await importer(_FakeSource(public)).run();
    expect(again.imported, 0);
    expect(again.alreadyImported, 1);
    expect(again.collisions, 1);
  });

  test('a JSON of the same size but other bytes is a collision', () async {
    final json = writeV012Ride('r5', <String>['f.mp4']);
    final bytes = json.readAsBytesSync().toList();
    // Same length, one byte changed.
    final index = bytes.lastIndexOf('7'.codeUnitAt(0));
    bytes[index] = '8'.codeUnitAt(0);
    File('${root.path}${_sep}ride_r5.telemetry.json').writeAsBytesSync(bytes);

    final summary = await importer(_FakeSource(public)).run();
    expect(summary.collisions, 1);
    expect(File('${root.path}${_sep}f.mp4').existsSync(), isFalse);
  });

  test('a size that does not match the provider fails the ride', () async {
    writeV012Ride('r6', <String>['g.mp4']);
    final source = _FakeSource(public)..reportedSizes['g.mp4'] = 9999;
    final summary = await importer(source).run();
    expect(summary.failed, 1);
    expect(rootNames(), isEmpty);
    expect(summary.message, contains('1 ride failed'));
  });

  test('a failed copy fails the ride and keeps the others', () async {
    writeV012Ride('r7', <String>['h.mp4']);
    writeV012Ride('r8', <String>['i.mp4']);
    final source = _FakeSource(public)..failCopy.add('h.mp4');
    final summary = await importer(source).run();
    expect(summary.failed, 1);
    expect(summary.imported, 1);
    expect(rootNames(), <String>['i.mp4', 'ride_r8.telemetry.json']);
  });

  test('recording starting cancels the copy in flight and pauses', () async {
    writeV012Ride('r9', <String>['j.mp4', 'k.mp4']);
    final source = _FakeSource(public);
    var pause = false;
    source.onCopyChunk = (name) {
      if (name == 'k.mp4') {
        pause = true;
      }
    };
    final summary = await importer(source, shouldPause: () => pause).run();
    expect(summary.outcome, LegacyImportOutcome.paused);
    expect(summary.remaining, 1);
    // j.mp4 is in place; k.mp4 never reached the root, the JSON did not
    // either, and staging was discarded.
    expect(rootNames(), <String>['j.mp4']);
    expect(Directory('$work${_sep}staging').existsSync(), isFalse);
    final journal =
        jsonDecode(
              File('$work$_sep$legacyImportJournalFileName').readAsStringSync(),
            )
            as Map;
    expect((journal['ride'] as Map)['name'], 'ride_r9.telemetry.json');

    // The next run rolls forward.
    final resumed = await importer(_FakeSource(public)).run();
    expect(resumed.outcome, LegacyImportOutcome.completed);
    expect(resumed.imported, 1);
    expect(rootNames(), <String>['j.mp4', 'k.mp4', 'ride_r9.telemetry.json']);
  });

  test('stops when the copies do not fit the free space', () async {
    writeV012Ride('ra', <String>['l.mp4']);
    final summary = await importer(
      _FakeSource(public),
      freeBytes: (_) async => 5,
    ).run();
    expect(summary.outcome, LegacyImportOutcome.lowStorage);
    expect(summary.remaining, 1);
    expect(rootNames(), isEmpty);
  });

  test('deleting the originals goes JSON first and reports failures', () async {
    writeV012Ride('rb', <String>['m.mp4']);
    final source = _FakeSource(public)..failDelete.add('m.mp4');
    final summary = await importer(source).run();
    final failed = await deleteImportedOriginals(
      source,
      summary.importedDocuments,
    );
    expect(source.deleted, <String>['ride_rb.telemetry.json']);
    expect(failed.map((d) => d.name), <String>['m.mp4']);
  });

  test('the controller reports progress and the idle signal', () async {
    writeV012Ride('rc', <String>['n.mp4']);
    final controller = LegacyRideImportController();
    final banners = <String?>[];
    controller.addListener(() => banners.add(controller.bannerText));
    expect(controller.isIdle, isTrue);
    final future = controller.run(importer(_FakeSource(public)));
    expect(controller.isRunning, isTrue);
    expect(await controller.run(importer(_FakeSource(public))), isNull);
    final summary = await future;
    expect(summary!.imported, 1);
    expect(controller.isIdle, isTrue);
    expect(controller.inFlightPaths, isEmpty);
    expect(banners, contains('Importing rides from the old folder (1 of 1)'));
  });
}
