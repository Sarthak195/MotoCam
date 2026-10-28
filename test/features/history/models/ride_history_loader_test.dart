import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/core/ride_file/ride_telemetry_codec.dart';
import 'package:motocam/core/utils/integrity_utils.dart';
import 'package:motocam/features/history/models/ride_history_loader.dart';
import 'package:motocam/features/history/models/ride_record.dart';

void main() {
  late Directory directory;
  final sep = Platform.pathSeparator;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('motocam_history_');
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

  Future<File> writeRide(
    String id,
    List<File> segments,
    String startedAt,
  ) async {
    final payload = <String, dynamic>{
      'schemaVersion': 2,
      'videoPath': segments.last.path,
      'segmentPaths': segments.map((file) => file.path).toList(),
      'lockedSegmentPaths': <String>[],
      'startedAt': startedAt,
      'samples': <Map<String, dynamic>>[],
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

  test(
    'lists telemetry rides and surfaces unreferenced videos, newest first',
    () async {
      final first = await writeFile('REC1.mp4', 'one');
      final second = await writeFile('REC2.mp4', 'two');
      final orphan = await writeFile('REC3.mp4', 'three');
      await orphan.setLastModified(DateTime.utc(2027, 1, 1));
      final telemetry = await writeRide('a', <File>[
        first,
        second,
      ], '2026-05-03T10:00:00.000Z');
      final broken = await writeFile('ride_b.telemetry.json', '{not json');
      final temp = await writeFile('ride_a.telemetry.json.1-2-3.tmp', 'x');

      final paths = <String>[
        first.path,
        second.path,
        orphan.path,
        telemetry.path,
        broken.path,
        temp.path,
      ];
      final rides = await loadRideHistory(paths);

      expect(rides, hasLength(2));
      expect(rides.first.videoPath, orphan.path);
      expect(rides.first.telemetryPath, isNull);
      expect(rides.last.telemetryPath, telemetry.path);
      expect(rides.last.integrity.status, RideIntegrityStatus.verified);
    },
  );

  test('loads on a background isolate', () async {
    final video = await writeFile('REC1.mp4', 'one');
    await writeRide('a', <File>[video], '2026-05-03T10:00:00.000Z');
    final paths = directory.listSync().map((entity) => entity.path).toList();

    final rides = await Isolate.run(() => loadRideHistory(paths));
    expect(rides, hasLength(1));
    expect(rides.single.segmentPaths, <String>[video.path]);
  });

  test('findOrphanVideoPaths ignores referenced and non-video files', () async {
    final referenced = await writeFile('REC1.mp4', 'one');
    final ride = await RideRecord.fromVideoFile(referenced);
    final orphans = findOrphanVideoPaths(
      recordingPaths: <String>[
        referenced.path,
        '${directory.path}${sep}REC2.MOV',
        '${directory.path}${sep}REC2.MOV',
        '${directory.path}${sep}notes.txt',
      ],
      rides: <RideRecord>[ride],
    );
    expect(orphans, <String>['${directory.path}${sep}REC2.MOV']);
  });
}
