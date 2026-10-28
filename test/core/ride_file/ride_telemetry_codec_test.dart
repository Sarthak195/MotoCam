import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/core/ride_file/ride_telemetry_codec.dart';
import 'package:motocam/core/utils/integrity_utils.dart';
import 'package:motocam/features/history/models/ride_record.dart';

final String _sep = Platform.pathSeparator;

void main() {
  test('the legacy public folder is a fixed literal', () {
    // The v0.1.11 and v0.1.12 location; it must not follow the gallery
    // export path.
    expect(
      legacyPublicRecordingsDirectory,
      '/storage/emulated/0/Movies/MotoCam/Recordings',
    );
  });

  group('segment-list and timeline rules', () {
    test('normalizeSegmentPathList trims, de-duplicates and appends', () {
      expect(
        normalizeSegmentPathList(<Object?>[' a.mp4', 'b.mp4', '', 'a.mp4']),
        <String>['a.mp4', 'b.mp4'],
      );
      expect(
        normalizeSegmentPathList(<String>['a.mp4'], videoPath: ' c.mp4 '),
        <String>['a.mp4', 'c.mp4'],
      );
      expect(
        normalizeSegmentPathList(<String>['a.mp4'], videoPath: 'a.mp4'),
        <String>['a.mp4'],
      );
    });

    test('normalizeTimelineSpan clamps the start and raises the end', () {
      expect(normalizeTimelineSpan(-5, 100), (startMs: 0, endMs: 100));
      expect(normalizeTimelineSpan(200, 100), (startMs: 200, endMs: 200));
      expect(normalizeTimelineSpan(-5, null), (startMs: 0, endMs: 0));
    });

    test('decodeRideFileSummary ignores the samples', () {
      final summary = decodeRideFileSummary(<String, dynamic>{
        'schemaVersion': '3',
        'rideSessionId': ' id ',
        'distanceKm': 2,
        'samples': 'not parsed here',
      });
      expect(summary.schemaVersion, 3);
      expect(summary.rideSessionId, 'id');
      expect(summary.sessionComplete, isTrue);
      expect(summary.distanceKm, 2.0);
      expect(summary.incidents, isNull);
    });
  });

  group('writer to reader round trip', () {
    late Directory tempRoot;
    late Directory recordings;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('motocam_codec_');
      recordings = Directory('${tempRoot.path}${_sep}MotoCam Recordings');
      await recordings.create(recursive: true);
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Future<String> createSegment(String name, String content) async {
      final file = File('${recordings.path}$_sep$name');
      await file.writeAsString(content, flush: true);
      return file.path;
    }

    /// Runs the writer path TelemetryProvider uses: resolve the files,
    /// encode the payload, hash the segments, seal and write atomically.
    Future<String> writeRide({
      required RideFileInput input,
      required RideFileSnapshot ride,
      required bool sessionComplete,
      Set<String>? onlySegments,
    }) async {
      var files = await resolveRideFileContent(input);
      if (onlySegments != null) {
        files = files.restrictedTo(onlySegments);
      }
      final hashes = <String, String>{};
      for (final path in files.segmentPaths) {
        hashes[path] = (await hashFileSha256(path))!;
      }
      final sealed = await sealRidePayload(
        encodeRidePayload(
          ride: ride,
          files: files,
          sessionComplete: sessionComplete,
          sampleRateMs: 1000,
        ),
        segmentHashes: hashes,
        segmentCount: files.segmentPaths.length,
        generatedAt: DateTime.now().toUtc(),
      );
      final telemetryPath = rideTelemetryPathFor(
        rideSessionId: ride.sessionId,
        videoPath: files.videoPath,
        segmentPaths: files.segmentPaths,
      );
      await writeTelemetryAtomically(
        telemetryFile: File(telemetryPath),
        content: encodeRideFileJson(sealed),
      );
      return telemetryPath;
    }

    RideFileSnapshot snapshot() => RideFileSnapshot(
      sessionId: '1792483200000_0a1b2c3d1e5f6a7b',
      startedAt: DateTime.utc(2026, 10, 20, 8),
      endedAt: DateTime.utc(2026, 10, 20, 8, 3),
      samples: <Map<String, dynamic>>[
        for (final ms in <int>[0, 1000, 2000])
          <String, dynamic>{
            'latitude': 12.97,
            'longitude': 77.59,
            'speed': ms / 100.0,
            'bearing': 90.0,
            'accelerationG': 0.1,
            'elapsedMs': ms,
            'distanceKm': ms / 1e5,
            'timestamp': DateTime.utc(
              2026,
              10,
              20,
              8,
            ).add(Duration(milliseconds: ms)).toIso8601String(),
            'hasFix': ms > 0,
          },
      ],
      incidents: <Map<String, dynamic>>[
        <String, dynamic>{
          'elapsedMs': 1500,
          'timestamp': '2026-10-20T08:00:01.500Z',
          'gForce': 4.2,
          'triggerGForce': 3.5,
          'reason': 'auto-crash',
        },
      ],
      distanceKm: 1.42,
      maxSpeedKmh: double.nan,
      averageSpeedKmh: 38.9,
      mockLocationDetected: false,
    );

    test(
      'a sealed final save reads back verified with the same data',
      () async {
        final a = await createSegment('REC_a.mp4', 'video-a');
        final b = await createSegment('REC_b.mp4', 'video-b');
        final c = await createSegment('REC_c.mp4', 'video-c');
        final missing = '${recordings.path}${_sep}REC_gone.mp4';
        final outside = await File(
          '${tempRoot.path}${_sep}outside.mp4',
        ).writeAsString('x');

        final path = await writeRide(
          input: RideFileInput(
            videoPath: c,
            segmentPaths: <String>[' $a ', a, missing, outside.path, b],
            lockedSegmentPaths: <String>[b, missing, b],
            segmentTimeline: <Map<String, dynamic>>[
              <String, dynamic>{'path': c, 'startMs': 130000, 'endMs': 125000},
              <String, dynamic>{'path': a, 'startMs': -40, 'endMs': 60000},
              <String, dynamic>{'path': b, 'startMs': 61000, 'endMs': 121000},
              <String, dynamic>{'path': a, 'startMs': 5, 'endMs': 6},
              <String, dynamic>{'path': missing, 'startMs': 0, 'endMs': 1},
            ],
            recordingSettings: <String, dynamic>{' appliedFps ': 30, '': 1},
          ),
          ride: snapshot(),
          sessionComplete: true,
        );

        expect(
          path,
          '${recordings.path}${_sep}ride_1792483200000_0a1b2c3d1e5f6a7b'
          '.telemetry.json',
        );
        final ride = await RideRecord.fromTelemetryFile(
          File(path),
          verifySegments: true,
        );
        expect(ride, isNotNull);
        expect(
          ride!.integrity.status,
          RideIntegrityStatus.verified,
          reason: ride.integrity.issues.join(', '),
        );
        expect(ride.segmentPaths, <String>[a, b, c]);
        expect(ride.videoPath, c);
        expect(ride.missingSegmentPaths, isEmpty);
        expect(ride.quarantinedSegmentPaths, isEmpty);
        expect(ride.lockedSegmentPaths, <String>[b]);
        expect(
          <List<Object>>[
            for (final entry in ride.segmentTimeline)
              <Object>[entry.path, entry.startMs, entry.endMs],
          ],
          <List<Object>>[
            <Object>[a, 0, 60000],
            <Object>[b, 61000, 121000],
            <Object>[c, 130000, 130000],
          ],
        );
        expect(ride.rideSessionId, '1792483200000_0a1b2c3d1e5f6a7b');
        expect(ride.isSessionComplete, isTrue);
        expect(
          ride.createdAt.isAtSameMomentAs(DateTime.utc(2026, 10, 20, 8)),
          isTrue,
        );
        expect(ride.distanceKm, 1.42);
        expect(ride.maxSpeedKmh, 0);
        expect(ride.averageSpeedKmh, 38.9);
        expect(ride.mockLocationDetected, isFalse);
        expect(ride.incidents, hasLength(1));
        expect(ride.incidents!.single.elapsedMs, 1500);
        expect(ride.samples.map((sample) => sample.elapsedMs), <int>[
          0,
          1000,
          2000,
        ]);
        expect(ride.samples.first.hasFix, isFalse);

        final json = await readRideFileJson(File(path));
        expect(json!['recordingSettings'], <String, dynamic>{'appliedFps': 30});
        expect(json['maxSpeedKmh'], isNull);
        expect(json['schemaVersion'], rideFileSchemaVersion);
      },
    );

    test(
      'a checkpoint restricted to hashed segments reads back verified',
      () async {
        final a = await createSegment('REC_a.mp4', 'video-a');
        final b = await createSegment('REC_b.mp4', 'video-b');

        final path = await writeRide(
          input: RideFileInput(
            videoPath: b,
            segmentPaths: <String>[a, b],
            lockedSegmentPaths: <String>[a, b],
            segmentTimeline: <Map<String, dynamic>>[
              <String, dynamic>{'path': a, 'startMs': 0, 'endMs': 60000},
              <String, dynamic>{'path': b, 'startMs': 61000, 'endMs': 90000},
            ],
            recordingSettings: const <String, dynamic>{},
          ),
          ride: snapshot(),
          sessionComplete: false,
          onlySegments: <String>{a},
        );

        final ride = await RideRecord.fromTelemetryFile(
          File(path),
          verifySegments: true,
        );
        expect(ride!.integrity.status, RideIntegrityStatus.verified);
        expect(ride.isSessionComplete, isFalse);
        expect(ride.segmentPaths, <String>[a]);
        expect(ride.videoPath, a);
        expect(ride.lockedSegmentPaths, <String>[a]);
        expect(ride.segmentTimeline.single.endMs, 60000);
      },
    );
  });
}
