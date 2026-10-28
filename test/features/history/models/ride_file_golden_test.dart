// Golden tests for the ride telemetry file format.
//
// Each fixture under test/fixtures/ride_files is a ride JSON written in one
// of the shapes MotoCam has produced (legacy without an envelope, envelope
// version 1, envelope version 2, checkpoints, relocated and quarantined
// paths) or a malformed variant. The expected values below were recorded
// with the code as it was before the ride-file codec existed, and they must
// not change: they guard that hashing, verification, segment resolution and
// timeline normalisation read every existing file exactly as before. The
// fixture files were sealed once with that code; never regenerate them.
//
// Paths in the fixtures are plain file names or fixed fake absolute paths,
// so the payload hashes do not depend on where the test runs. Resolved
// paths in the expectations are written as `<dir>/<name>`.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/core/ride_file/ride_telemetry_codec.dart';
import 'package:motocam/features/history/models/ride_record.dart';

const String _fixtureDirectory = 'test/fixtures/ride_files';

/// Segment files created next to each fixture; every file holds
/// `video:<name>`. Declared segments not listed here are missing on disk.
const Map<String, List<String>> _segmentsOnDisk = <String, List<String>>{
  'legacy_no_envelope': <String>[
    'legacy_a.mp4',
    'legacy_b.mp4',
    'legacy_c.mp4',
  ],
  'schema1_video_only': <String>['s1_ride.mp4'],
  'edge_empty_video_path': <String>['edge_1.mp4'],
  'envelope_v1': <String>['v1_a.mp4', 'v1_b.mp4'],
  'envelope_v2': <String>['v2_a.mp4', 'v2_b.mp4'],
  'envelope_v2_tampered': <String>['t_a.mp4', 't_b.mp4', 't_c.mp4'],
  'checkpoint': <String>['cp_a.mp4', 'cp_b.mp4'],
  'checkpoint_no_envelope': <String>['cpn_a.mp4'],
  'schema3_missing_integrity': <String>['mi_a.mp4'],
  'invalid_integrity': <String>['ii_a.mp4'],
  'envelope_bad_version': <String>['bv_a.mp4'],
  'relocated': <String>['rel_a.mp4', 'rel_b.mp4'],
  'quarantined': <String>['q_in.mp4'],
  'legacy_recover': <String>['legacy_recover.mp4'],
  'bad_number_type': <String>['bn_a.mp4'],
  'bad_timeline_type': <String>['bt_a.mp4'],
};

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('motocam_ride_golden_');
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  Map<String, dynamic> readFixture(String name) =>
      jsonDecode(
            File('$_fixtureDirectory/$name.telemetry.json').readAsStringSync(),
          )
          as Map<String, dynamic>;

  /// Copies the fixture and its segment files into a fresh directory and
  /// returns the telemetry file.
  Future<File> materialize(String name) async {
    final directory = Directory(
      '${tempRoot.path}${Platform.pathSeparator}$name',
    );
    await directory.create(recursive: true);
    for (final segment in _segmentsOnDisk[name]!) {
      await File(
        '${directory.path}${Platform.pathSeparator}$segment',
      ).writeAsString('video:$segment', flush: true);
    }
    final telemetryFile = File(
      '${directory.path}${Platform.pathSeparator}$name.telemetry.json',
    );
    await File(
      '$_fixtureDirectory/$name.telemetry.json',
    ).copy(telemetryFile.path);
    return telemetryFile;
  }

  group('ride file golden values', () {
    test('payload hashes of every fixture are unchanged', () {
      final actual = <String, String>{
        for (final name in _segmentsOnDisk.keys)
          name: computeRidePayloadHash(readFixture(name)),
      };
      expect(actual, _expectedPayloadHashes);
    });

    for (final name in _segmentsOnDisk.keys) {
      test('$name reads exactly as recorded', () async {
        final telemetryFile = await materialize(name);
        final directory = telemetryFile.parent.path;
        final startedAt = readFixture(name)['startedAt'] as String;
        final lazy = await RideRecord.fromTelemetryFile(telemetryFile);
        final deep = await RideRecord.fromTelemetryFile(
          telemetryFile,
          verifySegments: true,
        );
        final actual = <String, Object?>{
          'ride': _describeRide(lazy, directory, startedAt),
          'deepIntegrity': deep == null
              ? null
              : _describeReport(deep.integrity, directory),
          'onDemandIntegrity': lazy == null
              ? null
              : _describeReport(
                  (await lazy.verifySegmentIntegrity()).integrity,
                  directory,
                ),
        };
        // Hashing the segments changes only the integrity report.
        expect(
          _describeRide(deep, directory, startedAt)?..remove('integrity'),
          _describeRide(lazy, directory, startedAt)?..remove('integrity'),
        );
        expect(actual, _expectedReads[name]);
      });
    }

    for (final entry in _lockCases.entries) {
      test('${entry.key} lock-state rewrite is unchanged', () async {
        final telemetryFile = await materialize(entry.key);
        final directory = telemetryFile.parent.path;
        final ride = await RideRecord.fromTelemetryFile(telemetryFile);
        final saved = await ride!.setLockState(entry.value);
        final rewritten =
            jsonDecode(await telemetryFile.readAsString())
                as Map<String, dynamic>;
        final integrity = rewritten['integrity'];
        final reloaded = await RideRecord.fromTelemetryFile(
          telemetryFile,
          verifySegments: true,
        );
        final actual = <String, Object?>{
          'saved': saved,
          'keys': rewritten.keys.toList(),
          'lockedSegmentPaths': rewritten['lockedSegmentPaths'],
          'envelope': integrity is Map
              ? <String, Object?>{
                  'keys': integrity.keys.toList(),
                  'envelopeVersion': integrity['envelopeVersion'],
                  'payloadHash': integrity['payloadHash'],
                  'generatedAt': integrity['generatedAt'],
                  'segmentCount': integrity['segmentCount'],
                }
              : integrity,
          'fileSha256': sha256
              .convert(utf8.encode(jsonEncode(rewritten)))
              .toString(),
          'reloaded': _describeReport(reloaded!.integrity, directory),
          'reloadedLocked': _relative(reloaded.lockedSegmentPaths, directory),
        };
        expect(actual, _expectedLockRewrites[entry.key]);
      });
    }
  });
}

/// Lock-state rewrites recorded for these fixtures (`true` locks every
/// segment, `false` unlocks).
const Map<String, bool> _lockCases = <String, bool>{
  'legacy_no_envelope': false,
  'envelope_v1': false,
  'envelope_v2': false,
  'checkpoint': false,
  'relocated': true,
  'quarantined': false,
};

String _relativePath(String path, String directory) {
  final prefix = '$directory${Platform.pathSeparator}';
  return path.startsWith(prefix)
      ? '<dir>/${path.substring(prefix.length)}'
      : path;
}

List<String> _relative(List<String> paths, String directory) => <String>[
  for (final path in paths) _relativePath(path, directory),
];

String _relativeIssue(String issue, String directory) {
  final separator = issue.indexOf(':');
  if (separator < 0) {
    return issue;
  }
  return '${issue.substring(0, separator + 1)}'
      '${_relativePath(issue.substring(separator + 1), directory)}';
}

Map<String, Object?> _describeReport(
  RideIntegrityReport report,
  String directory,
) => <String, Object?>{
  'status': report.status.name,
  'hasMetadata': report.hasMetadata,
  'issues': <String>[
    for (final issue in report.issues) _relativeIssue(issue, directory),
  ],
};

Map<String, Object?>? _describeRide(
  RideRecord? ride,
  String directory,
  String startedAt,
) {
  if (ride == null) {
    return null;
  }
  return <String, Object?>{
    'integrity': _describeReport(ride.integrity, directory),
    'videoPath': _relativePath(ride.videoPath, directory),
    'segmentPaths': _relative(ride.segmentPaths, directory),
    'missingSegmentPaths': _relative(ride.missingSegmentPaths, directory),
    'quarantinedSegmentPaths': _relative(
      ride.quarantinedSegmentPaths,
      directory,
    ),
    'lockedSegmentPaths': _relative(ride.lockedSegmentPaths, directory),
    'timeline': <List<Object>>[
      for (final entry in ride.segmentTimeline)
        <Object>[
          _relativePath(entry.path, directory),
          entry.startMs,
          entry.endMs,
        ],
    ],
    'createdAtIsLocal': !ride.createdAt.isUtc,
    // Offset-less timestamps parse as local time, so compare instants
    // instead of recording a time-zone dependent value.
    'createdAtMatchesStartedAt': ride.createdAt.isAtSameMomentAs(
      DateTime.parse(startedAt),
    ),
    'rideSessionId': ride.rideSessionId,
    'isSessionComplete': ride.isSessionComplete,
    'distanceKm': ride.distanceKm,
    'maxSpeedKmh': ride.maxSpeedKmh,
    'averageSpeedKmh': ride.averageSpeedKmh,
    'mockLocationDetected': ride.mockLocationDetected,
    'incidents': ride.incidents == null
        ? null
        : <List<Object?>>[
            for (final incident in ride.incidents!)
              <Object?>[
                incident.elapsedMs,
                incident.timestamp?.toUtc().toIso8601String(),
                incident.gForce,
                incident.triggerGForce,
                incident.reason,
              ],
          ],
    'samples': <List<Object?>>[
      for (final sample in ride.samples)
        <Object?>[
          sample.elapsedMs,
          sample.latitude,
          sample.speed,
          sample.hasFix,
          sample.fixAgeMs,
        ],
    ],
    'telemetryFileName': ride.telemetryPath == null
        ? null
        : _relativePath(ride.telemetryPath!, directory),
  };
}

const Map<String, String> _expectedPayloadHashes = <String, String>{
  'legacy_no_envelope':
      '0069574b2ee26f16109d2f53a549ee3a849e8cb7a06dd5d38cef7fdaeadaafb2',
  'schema1_video_only':
      '03ac602d6fb149d7c39553ff3ad7d8a8973ec57ce94d93ac7412295e18f07c62',
  'edge_empty_video_path':
      '81f77602101bac0b289f6cf37ece9b3199dc4735b7aa52739fe1cad88d048571',
  'envelope_v1':
      'a33522d9a7afb7508c77959e3e62ace9c104d4b3373b65861cab27c887330765',
  'envelope_v2':
      '31726352c60cafdff4787d35b120c3f7703f02767354e4fd6a7073c49bf73e44',
  'envelope_v2_tampered':
      'f8516e0f54bffe81d014fbc3a95f38bc07a42d5eec45799cc30b893b68c907de',
  'checkpoint':
      'f0a19c12de3fa79115494f6112b565e261e95de0e2cdbb99086e6b640b9acea0',
  'checkpoint_no_envelope':
      'a4da444e48c430d31472d6ea38da0c398fb9319ea10af90d298679c834f431ba',
  'schema3_missing_integrity':
      'c7dd123b01ffbdb269dea964fd63ed3f52142cbd1c88e98eeb2ca5c0fa0c1340',
  'invalid_integrity':
      '1d8a21e46e84436b9e80f9887a3da348ebca9ed1a7200d629a5caa141f88e7f7',
  'envelope_bad_version':
      'd2e6da6747f7e6a7be4effba1480e9f3617230496010832a5a593db64909fe94',
  'relocated':
      'cf1ab5d395f8e94721de20559ab7770242f6aca1246b632ebd83ee1eb8f45119',
  'quarantined':
      '38a4240ab901531e73ea8b12e7df0a50325b1931b083fcf17d85536c433f8c6e',
  'legacy_recover':
      '85e61ea1827843e6280d3b323149bf8d739ca2be629ca4d3049c6e13562e7b10',
  'bad_number_type':
      '4205c6cf0a8e10b92f640240cca073b6729ba3d16830900c7afb56bb4e57f7f9',
  'bad_timeline_type':
      'e825077bb7549b9dc797f7781fa2fdd4849cc2fc1fb2f10cfcaaba88ab06e0b1',
};

const Map<String, Object?> _expectedReads = <String, Object?>{
  'legacy_no_envelope': {
    'ride': {
      'integrity': {'status': 'unknown', 'hasMetadata': false, 'issues': []},
      'videoPath': '<dir>/legacy_c.mp4',
      'segmentPaths': [
        '<dir>/legacy_a.mp4',
        '<dir>/legacy_b.mp4',
        '<dir>/legacy_c.mp4',
      ],
      'missingSegmentPaths': [],
      'quarantinedSegmentPaths': [],
      'lockedSegmentPaths': ['<dir>/legacy_a.mp4'],
      'timeline': [
        ['<dir>/legacy_a.mp4', 0, 4800],
        ['<dir>/legacy_b.mp4', 5000, 9000],
        ['<dir>/legacy_c.mp4', 9500, 9500],
      ],
      'createdAtIsLocal': true,
      'createdAtMatchesStartedAt': true,
      'rideSessionId': null,
      'isSessionComplete': true,
      'distanceKm': 3.5,
      'maxSpeedKmh': 70.0,
      'averageSpeedKmh': 40.25,
      'mockLocationDetected': false,
      'incidents': null,
      'samples': [
        [0, 0.0, 0.0, false, null],
        [5000, 12.5, 33.3, true, null],
      ],
      'telemetryFileName': '<dir>/legacy_no_envelope.telemetry.json',
    },
    'deepIntegrity': {'status': 'unknown', 'hasMetadata': false, 'issues': []},
    'onDemandIntegrity': {
      'status': 'unknown',
      'hasMetadata': false,
      'issues': [],
    },
  },
  'schema1_video_only': {
    'ride': {
      'integrity': {'status': 'unknown', 'hasMetadata': false, 'issues': []},
      'videoPath': '<dir>/s1_ride.mp4',
      'segmentPaths': ['<dir>/s1_ride.mp4'],
      'missingSegmentPaths': [],
      'quarantinedSegmentPaths': [],
      'lockedSegmentPaths': [],
      'timeline': [],
      'createdAtIsLocal': true,
      'createdAtMatchesStartedAt': true,
      'rideSessionId': null,
      'isSessionComplete': true,
      'distanceKm': 0.8,
      'maxSpeedKmh': 20.5,
      'averageSpeedKmh': 10.0,
      'mockLocationDetected': false,
      'incidents': null,
      'samples': [
        [1000, 1.0, 5.0, true, null],
      ],
      'telemetryFileName': '<dir>/schema1_video_only.telemetry.json',
    },
    'deepIntegrity': {'status': 'unknown', 'hasMetadata': false, 'issues': []},
    'onDemandIntegrity': {
      'status': 'unknown',
      'hasMetadata': false,
      'issues': [],
    },
  },
  'edge_empty_video_path': {
    'ride': {
      'integrity': {'status': 'unknown', 'hasMetadata': false, 'issues': []},
      'videoPath': '<dir>/edge_1.mp4',
      'segmentPaths': ['<dir>/edge_1.mp4', '<dir>/edge_2.mp4'],
      'missingSegmentPaths': ['<dir>/edge_2.mp4'],
      'quarantinedSegmentPaths': [],
      'lockedSegmentPaths': [],
      'timeline': [],
      'createdAtIsLocal': true,
      'createdAtMatchesStartedAt': true,
      'rideSessionId': 'edge-session',
      'isSessionComplete': false,
      'distanceKm': 0.0,
      'maxSpeedKmh': 12.0,
      'averageSpeedKmh': 0.0,
      'mockLocationDetected': true,
      'incidents': [],
      'samples': [],
      'telemetryFileName': '<dir>/edge_empty_video_path.telemetry.json',
    },
    'deepIntegrity': {'status': 'unknown', 'hasMetadata': false, 'issues': []},
    'onDemandIntegrity': {
      'status': 'unknown',
      'hasMetadata': false,
      'issues': [],
    },
  },
  'envelope_v1': {
    'ride': {
      'integrity': {'status': 'verified', 'hasMetadata': true, 'issues': []},
      'videoPath': '<dir>/v1_b.mp4',
      'segmentPaths': ['<dir>/v1_a.mp4', '<dir>/v1_b.mp4'],
      'missingSegmentPaths': [],
      'quarantinedSegmentPaths': [],
      'lockedSegmentPaths': ['<dir>/v1_a.mp4'],
      'timeline': [
        ['<dir>/v1_a.mp4', 0, 60012],
        ['<dir>/v1_b.mp4', 61130, 95380],
      ],
      'createdAtIsLocal': true,
      'createdAtMatchesStartedAt': true,
      'rideSessionId': '1783000000000_00aa11bb22cc33dd',
      'isSessionComplete': true,
      'distanceKm': 2.0,
      'maxSpeedKmh': 55.5,
      'averageSpeedKmh': 31.75,
      'mockLocationDetected': false,
      'incidents': null,
      'samples': [
        [0, 12.9716, 0.0, true, null],
        [1000, 12.9726, 1.0, true, null],
      ],
      'telemetryFileName': '<dir>/envelope_v1.telemetry.json',
    },
    'deepIntegrity': {'status': 'verified', 'hasMetadata': true, 'issues': []},
    'onDemandIntegrity': {
      'status': 'verified',
      'hasMetadata': true,
      'issues': [],
    },
  },
  'envelope_v2': {
    'ride': {
      'integrity': {'status': 'verified', 'hasMetadata': true, 'issues': []},
      'videoPath': '<dir>/v2_c.mp4',
      'segmentPaths': ['<dir>/v2_a.mp4', '<dir>/v2_b.mp4', '<dir>/v2_c.mp4'],
      'missingSegmentPaths': ['<dir>/v2_c.mp4'],
      'quarantinedSegmentPaths': [],
      'lockedSegmentPaths': ['<dir>/v2_a.mp4'],
      'timeline': [
        ['<dir>/v2_a.mp4', 0, 60000],
        ['<dir>/v2_b.mp4', 61000, 121000],
        ['<dir>/v2_c.mp4', 122000, 182000],
      ],
      'createdAtIsLocal': true,
      'createdAtMatchesStartedAt': true,
      'rideSessionId': '1792483200000_0a1b2c3d1e5f6a7b',
      'isSessionComplete': true,
      'distanceKm': 1.42,
      'maxSpeedKmh': 61.3,
      'averageSpeedKmh': 38.9,
      'mockLocationDetected': false,
      'incidents': [
        [42310, '2026-10-20T08:00:42.310Z', 5.0, 3.5, 'auto-crash'],
        [90000, '2026-10-20T08:01:30.000Z', 4.12, 3.5, 'auto-crash'],
      ],
      'samples': [
        [0, 12.9716, 0.0, false, null],
        [1000, 12.9726, 1.0, true, 412],
        [2000, 12.973600000000001, 2.0, true, 20],
      ],
      'telemetryFileName': '<dir>/envelope_v2.telemetry.json',
    },
    'deepIntegrity': {'status': 'verified', 'hasMetadata': true, 'issues': []},
    'onDemandIntegrity': {
      'status': 'verified',
      'hasMetadata': true,
      'issues': [],
    },
  },
  'envelope_v2_tampered': {
    'ride': {
      'integrity': {
        'status': 'modified',
        'hasMetadata': true,
        'issues': [
          'payload-hash-mismatch',
          'missing-segment-hash:<dir>/t_c.mp4',
          'orphan-integrity-hash:gone.mp4',
        ],
      },
      'videoPath': '<dir>/t_c.mp4',
      'segmentPaths': ['<dir>/t_a.mp4', '<dir>/t_b.mp4', '<dir>/t_c.mp4'],
      'missingSegmentPaths': [],
      'quarantinedSegmentPaths': [],
      'lockedSegmentPaths': [],
      'timeline': [
        ['<dir>/t_a.mp4', 0, 60000],
        ['<dir>/t_b.mp4', 61000, 121000],
        ['<dir>/t_c.mp4', 122000, 182000],
      ],
      'createdAtIsLocal': true,
      'createdAtMatchesStartedAt': true,
      'rideSessionId': '1792483200001_ffeeddccbbaa9988',
      'isSessionComplete': true,
      'distanceKm': 99.9,
      'maxSpeedKmh': 61.3,
      'averageSpeedKmh': 38.9,
      'mockLocationDetected': false,
      'incidents': [],
      'samples': [
        [0, 12.9716, 0.0, false, null],
        [1000, 12.9726, 1.0, true, 412],
        [2000, 12.973600000000001, 2.0, true, 20],
      ],
      'telemetryFileName': '<dir>/envelope_v2_tampered.telemetry.json',
    },
    'deepIntegrity': {
      'status': 'modified',
      'hasMetadata': true,
      'issues': [
        'payload-hash-mismatch',
        'segment-hash-mismatch:<dir>/t_b.mp4',
        'missing-segment-hash:<dir>/t_c.mp4',
        'orphan-integrity-hash:gone.mp4',
      ],
    },
    'onDemandIntegrity': {
      'status': 'modified',
      'hasMetadata': true,
      'issues': [
        'payload-hash-mismatch',
        'segment-hash-mismatch:<dir>/t_b.mp4',
        'missing-segment-hash:<dir>/t_c.mp4',
        'orphan-integrity-hash:gone.mp4',
      ],
    },
  },
  'checkpoint': {
    'ride': {
      'integrity': {'status': 'verified', 'hasMetadata': true, 'issues': []},
      'videoPath': '<dir>/cp_b.mp4',
      'segmentPaths': ['<dir>/cp_a.mp4', '<dir>/cp_b.mp4'],
      'missingSegmentPaths': [],
      'quarantinedSegmentPaths': [],
      'lockedSegmentPaths': ['<dir>/cp_b.mp4'],
      'timeline': [
        ['<dir>/cp_a.mp4', 0, 60000],
        ['<dir>/cp_b.mp4', 61000, 121000],
      ],
      'createdAtIsLocal': true,
      'createdAtMatchesStartedAt': true,
      'rideSessionId': '1792483200002_0011223344556677',
      'isSessionComplete': false,
      'distanceKm': 1.42,
      'maxSpeedKmh': 61.3,
      'averageSpeedKmh': 38.9,
      'mockLocationDetected': false,
      'incidents': [],
      'samples': [
        [0, 12.9716, 0.0, false, null],
        [1000, 12.9726, 1.0, true, 412],
        [2000, 12.973600000000001, 2.0, true, 20],
      ],
      'telemetryFileName': '<dir>/checkpoint.telemetry.json',
    },
    'deepIntegrity': {'status': 'verified', 'hasMetadata': true, 'issues': []},
    'onDemandIntegrity': {
      'status': 'verified',
      'hasMetadata': true,
      'issues': [],
    },
  },
  'checkpoint_no_envelope': {
    'ride': {
      'integrity': {'status': 'unknown', 'hasMetadata': false, 'issues': []},
      'videoPath': '<dir>/cpn_a.mp4',
      'segmentPaths': ['<dir>/cpn_a.mp4'],
      'missingSegmentPaths': [],
      'quarantinedSegmentPaths': [],
      'lockedSegmentPaths': [],
      'timeline': [
        ['<dir>/cpn_a.mp4', 0, 60000],
      ],
      'createdAtIsLocal': true,
      'createdAtMatchesStartedAt': true,
      'rideSessionId': '1792483200003_8899aabbccddeeff',
      'isSessionComplete': false,
      'distanceKm': 1.42,
      'maxSpeedKmh': 61.3,
      'averageSpeedKmh': 38.9,
      'mockLocationDetected': false,
      'incidents': [],
      'samples': [
        [0, 12.9716, 0.0, false, null],
        [1000, 12.9726, 1.0, true, 412],
        [2000, 12.973600000000001, 2.0, true, 20],
      ],
      'telemetryFileName': '<dir>/checkpoint_no_envelope.telemetry.json',
    },
    'deepIntegrity': {'status': 'unknown', 'hasMetadata': false, 'issues': []},
    'onDemandIntegrity': {
      'status': 'unknown',
      'hasMetadata': false,
      'issues': [],
    },
  },
  'schema3_missing_integrity': {
    'ride': {
      'integrity': {
        'status': 'modified',
        'hasMetadata': false,
        'issues': ['missing-integrity'],
      },
      'videoPath': '<dir>/mi_a.mp4',
      'segmentPaths': ['<dir>/mi_a.mp4'],
      'missingSegmentPaths': [],
      'quarantinedSegmentPaths': [],
      'lockedSegmentPaths': [],
      'timeline': [
        ['<dir>/mi_a.mp4', 0, 60000],
      ],
      'createdAtIsLocal': true,
      'createdAtMatchesStartedAt': true,
      'rideSessionId': '1792483200004_1122334455667788',
      'isSessionComplete': true,
      'distanceKm': 1.42,
      'maxSpeedKmh': 61.3,
      'averageSpeedKmh': 38.9,
      'mockLocationDetected': false,
      'incidents': [],
      'samples': [
        [0, 12.9716, 0.0, false, null],
        [1000, 12.9726, 1.0, true, 412],
        [2000, 12.973600000000001, 2.0, true, 20],
      ],
      'telemetryFileName': '<dir>/schema3_missing_integrity.telemetry.json',
    },
    'deepIntegrity': {
      'status': 'modified',
      'hasMetadata': false,
      'issues': ['missing-integrity'],
    },
    'onDemandIntegrity': {
      'status': 'modified',
      'hasMetadata': false,
      'issues': ['missing-integrity'],
    },
  },
  'invalid_integrity': {
    'ride': {
      'integrity': {
        'status': 'modified',
        'hasMetadata': false,
        'issues': ['invalid-integrity'],
      },
      'videoPath': '<dir>/ii_a.mp4',
      'segmentPaths': ['<dir>/ii_a.mp4'],
      'missingSegmentPaths': [],
      'quarantinedSegmentPaths': [],
      'lockedSegmentPaths': [],
      'timeline': [
        ['<dir>/ii_a.mp4', 0, 60000],
      ],
      'createdAtIsLocal': true,
      'createdAtMatchesStartedAt': true,
      'rideSessionId': '1792483200005_2233445566778899',
      'isSessionComplete': true,
      'distanceKm': 1.42,
      'maxSpeedKmh': 61.3,
      'averageSpeedKmh': 38.9,
      'mockLocationDetected': false,
      'incidents': [],
      'samples': [
        [0, 12.9716, 0.0, false, null],
        [1000, 12.9726, 1.0, true, 412],
        [2000, 12.973600000000001, 2.0, true, 20],
      ],
      'telemetryFileName': '<dir>/invalid_integrity.telemetry.json',
    },
    'deepIntegrity': {
      'status': 'modified',
      'hasMetadata': false,
      'issues': ['invalid-integrity'],
    },
    'onDemandIntegrity': {
      'status': 'modified',
      'hasMetadata': false,
      'issues': ['invalid-integrity'],
    },
  },
  'envelope_bad_version': {
    'ride': {
      'integrity': {
        'status': 'modified',
        'hasMetadata': true,
        'issues': ['unsupported-integrity-version:2', 'payload-hash-mismatch'],
      },
      'videoPath': '<dir>/bv_a.mp4',
      'segmentPaths': ['<dir>/bv_a.mp4'],
      'missingSegmentPaths': [],
      'quarantinedSegmentPaths': [],
      'lockedSegmentPaths': [],
      'timeline': [
        ['<dir>/bv_a.mp4', 0, 60000],
      ],
      'createdAtIsLocal': true,
      'createdAtMatchesStartedAt': true,
      'rideSessionId': '1792483200006_33445566778899aa',
      'isSessionComplete': true,
      'distanceKm': 1.42,
      'maxSpeedKmh': 61.3,
      'averageSpeedKmh': 38.9,
      'mockLocationDetected': false,
      'incidents': [],
      'samples': [
        [0, 12.9716, 0.0, false, null],
        [1000, 12.9726, 1.0, true, 412],
        [2000, 12.973600000000001, 2.0, true, 20],
      ],
      'telemetryFileName': '<dir>/envelope_bad_version.telemetry.json',
    },
    'deepIntegrity': {
      'status': 'modified',
      'hasMetadata': true,
      'issues': ['unsupported-integrity-version:2', 'payload-hash-mismatch'],
    },
    'onDemandIntegrity': {
      'status': 'modified',
      'hasMetadata': true,
      'issues': ['unsupported-integrity-version:2', 'payload-hash-mismatch'],
    },
  },
  'relocated': {
    'ride': {
      'integrity': {'status': 'verified', 'hasMetadata': true, 'issues': []},
      'videoPath': '<dir>/rel_b.mp4',
      'segmentPaths': ['<dir>/rel_a.mp4', '<dir>/rel_b.mp4'],
      'missingSegmentPaths': [],
      'quarantinedSegmentPaths': [],
      'lockedSegmentPaths': ['<dir>/rel_b.mp4'],
      'timeline': [
        ['<dir>/rel_a.mp4', 0, 60000],
        ['<dir>/rel_b.mp4', 61000, 120000],
      ],
      'createdAtIsLocal': true,
      'createdAtMatchesStartedAt': true,
      'rideSessionId': '1792483200007_445566778899aabb',
      'isSessionComplete': true,
      'distanceKm': 1.42,
      'maxSpeedKmh': 61.3,
      'averageSpeedKmh': 38.9,
      'mockLocationDetected': false,
      'incidents': [],
      'samples': [
        [0, 12.9716, 0.0, false, null],
        [1000, 12.9726, 1.0, true, 412],
        [2000, 12.973600000000001, 2.0, true, 20],
      ],
      'telemetryFileName': '<dir>/relocated.telemetry.json',
    },
    'deepIntegrity': {'status': 'verified', 'hasMetadata': true, 'issues': []},
    'onDemandIntegrity': {
      'status': 'verified',
      'hasMetadata': true,
      'issues': [],
    },
  },
  'quarantined': {
    'ride': {
      'integrity': {
        'status': 'modified',
        'hasMetadata': true,
        'issues': [
          'orphan-integrity-hash:/nonexistent-root/elsewhere/q_out.mp4',
          'quarantined-segment-paths:1',
        ],
      },
      'videoPath': '<dir>/q_in.mp4',
      'segmentPaths': ['<dir>/q_in.mp4'],
      'missingSegmentPaths': [],
      'quarantinedSegmentPaths': ['/nonexistent-root/elsewhere/q_out.mp4'],
      'lockedSegmentPaths': [],
      'timeline': [
        ['<dir>/q_in.mp4', 0, 60000],
      ],
      'createdAtIsLocal': true,
      'createdAtMatchesStartedAt': true,
      'rideSessionId': '1792483200008_5566778899aabbcc',
      'isSessionComplete': true,
      'distanceKm': 1.42,
      'maxSpeedKmh': 61.3,
      'averageSpeedKmh': 38.9,
      'mockLocationDetected': false,
      'incidents': [],
      'samples': [
        [0, 12.9716, 0.0, false, null],
        [1000, 12.9726, 1.0, true, 412],
        [2000, 12.973600000000001, 2.0, true, 20],
      ],
      'telemetryFileName': '<dir>/quarantined.telemetry.json',
    },
    'deepIntegrity': {
      'status': 'modified',
      'hasMetadata': true,
      'issues': [
        'orphan-integrity-hash:/nonexistent-root/elsewhere/q_out.mp4',
        'quarantined-segment-paths:1',
      ],
    },
    'onDemandIntegrity': {
      'status': 'modified',
      'hasMetadata': true,
      'issues': [
        'orphan-integrity-hash:/nonexistent-root/elsewhere/q_out.mp4',
        'quarantined-segment-paths:1',
      ],
    },
  },
  'legacy_recover': {
    'ride': {
      'integrity': {'status': 'unknown', 'hasMetadata': false, 'issues': []},
      'videoPath': '<dir>/legacy_recover.mp4',
      'segmentPaths': ['<dir>/legacy_recover.mp4'],
      'missingSegmentPaths': [],
      'quarantinedSegmentPaths': [],
      'lockedSegmentPaths': [],
      'timeline': [],
      'createdAtIsLocal': true,
      'createdAtMatchesStartedAt': true,
      'rideSessionId': null,
      'isSessionComplete': true,
      'distanceKm': 0.0,
      'maxSpeedKmh': 0.0,
      'averageSpeedKmh': 0.0,
      'mockLocationDetected': false,
      'incidents': null,
      'samples': [],
      'telemetryFileName': '<dir>/legacy_recover.telemetry.json',
    },
    'deepIntegrity': {'status': 'unknown', 'hasMetadata': false, 'issues': []},
    'onDemandIntegrity': {
      'status': 'unknown',
      'hasMetadata': false,
      'issues': [],
    },
  },
  'bad_number_type': {
    'ride': null,
    'deepIntegrity': null,
    'onDemandIntegrity': null,
  },
  'bad_timeline_type': {
    'ride': null,
    'deepIntegrity': null,
    'onDemandIntegrity': null,
  },
};

const Map<String, Object?> _expectedLockRewrites = <String, Object?>{
  'legacy_no_envelope': {
    'saved': true,
    'keys': [
      'schemaVersion',
      'sampleRateMs',
      'videoPath',
      'videoFileName',
      'segmentPaths',
      'lockedSegmentPaths',
      'segmentTimeline',
      'startedAt',
      'endedAt',
      'distanceKm',
      'maxSpeedKmh',
      'averageSpeedKmh',
      'samples',
    ],
    'lockedSegmentPaths': [],
    'envelope': null,
    'fileSha256':
        '4d6ffe83cbe51adba9d5226efc83ac0dedd71f7e88bba627bc0b85cbb2ed0a7d',
    'reloaded': {'status': 'unknown', 'hasMetadata': false, 'issues': []},
    'reloadedLocked': [],
  },
  'envelope_v1': {
    'saved': true,
    'keys': [
      'schemaVersion',
      'rideSessionId',
      'sessionComplete',
      'storagePolicy',
      'publicExportRelativePath',
      'storageDirectory',
      'sampleRateMs',
      'videoPath',
      'videoFileName',
      'segmentPaths',
      'lockedSegmentPaths',
      'segmentTimeline',
      'recordingSettings',
      'startedAt',
      'endedAt',
      'distanceKm',
      'maxSpeedKmh',
      'averageSpeedKmh',
      'samples',
      'integrity',
    ],
    'lockedSegmentPaths': [],
    'envelope': {
      'keys': [
        'algo',
        'segmentCount',
        'hashedSegmentCount',
        'segmentHashes',
        'generatedAt',
        'envelopeVersion',
        'payloadHash',
      ],
      'envelopeVersion': 2,
      'payloadHash':
          '27300f786bc4343daaea8cc198bcf76325cd4d7d99f5e96635f62e0f220114ae',
      'generatedAt': '2026-07-07T18:01:36.000',
      'segmentCount': 2,
    },
    'fileSha256':
        '1b2b68c2e51124fb272687fbe4dbabad5604cd3ae3f42e079df5d521f22d2049',
    'reloaded': {'status': 'verified', 'hasMetadata': true, 'issues': []},
    'reloadedLocked': [],
  },
  'envelope_v2': {
    'saved': true,
    'keys': [
      'schemaVersion',
      'rideSessionId',
      'sessionComplete',
      'storagePolicy',
      'publicExportRelativePath',
      'storageDirectory',
      'sampleRateMs',
      'videoPath',
      'videoFileName',
      'segmentPaths',
      'lockedSegmentPaths',
      'segmentTimeline',
      'recordingSettings',
      'startedAt',
      'endedAt',
      'distanceKm',
      'maxSpeedKmh',
      'averageSpeedKmh',
      'mockLocationDetected',
      'incidents',
      'samples',
      'integrity',
    ],
    'lockedSegmentPaths': [],
    'envelope': {
      'keys': [
        'algo',
        'envelopeVersion',
        'segmentCount',
        'hashedSegmentCount',
        'segmentHashes',
        'generatedAt',
        'payloadHash',
      ],
      'envelopeVersion': 2,
      'payloadHash':
          'f9a6409f5d56e68702e4f72163ee85179ca6485f3cfeaf67ff6640b8e8061ca6',
      'generatedAt': '2026-10-20T08:03:06.120Z',
      'segmentCount': 3,
    },
    'fileSha256':
        'b4678241629b56c9cceac95cd33aefe37cac8a0ee79f2a01dcfb2765d2ba91bb',
    'reloaded': {'status': 'verified', 'hasMetadata': true, 'issues': []},
    'reloadedLocked': [],
  },
  'checkpoint': {
    'saved': true,
    'keys': [
      'schemaVersion',
      'rideSessionId',
      'sessionComplete',
      'storagePolicy',
      'publicExportRelativePath',
      'storageDirectory',
      'sampleRateMs',
      'videoPath',
      'videoFileName',
      'segmentPaths',
      'lockedSegmentPaths',
      'segmentTimeline',
      'recordingSettings',
      'startedAt',
      'endedAt',
      'distanceKm',
      'maxSpeedKmh',
      'averageSpeedKmh',
      'mockLocationDetected',
      'incidents',
      'samples',
      'integrity',
    ],
    'lockedSegmentPaths': [],
    'envelope': {
      'keys': [
        'algo',
        'envelopeVersion',
        'segmentCount',
        'hashedSegmentCount',
        'segmentHashes',
        'generatedAt',
        'payloadHash',
      ],
      'envelopeVersion': 2,
      'payloadHash':
          '6fb994f91ef5365c35a254316eabcb058b5581b6b298b1195c9163bb5cbfc357',
      'generatedAt': '2026-10-20T08:03:06.120Z',
      'segmentCount': 2,
    },
    'fileSha256':
        'bb3e6e692e8556e3b201e2a025aa170538abf4012d2b0948e0a1af7ebe351618',
    'reloaded': {'status': 'verified', 'hasMetadata': true, 'issues': []},
    'reloadedLocked': [],
  },
  'relocated': {
    'saved': true,
    'keys': [
      'schemaVersion',
      'rideSessionId',
      'sessionComplete',
      'storagePolicy',
      'publicExportRelativePath',
      'storageDirectory',
      'sampleRateMs',
      'videoPath',
      'videoFileName',
      'segmentPaths',
      'lockedSegmentPaths',
      'segmentTimeline',
      'recordingSettings',
      'startedAt',
      'endedAt',
      'distanceKm',
      'maxSpeedKmh',
      'averageSpeedKmh',
      'mockLocationDetected',
      'incidents',
      'samples',
      'integrity',
    ],
    'lockedSegmentPaths': [
      '/nonexistent-root/old-container/MotoCam Recordings/rel_a.mp4',
      '/nonexistent-root/old-container/MotoCam Recordings/rel_b.mp4',
    ],
    'envelope': {
      'keys': [
        'algo',
        'envelopeVersion',
        'segmentCount',
        'hashedSegmentCount',
        'segmentHashes',
        'generatedAt',
        'payloadHash',
      ],
      'envelopeVersion': 2,
      'payloadHash':
          '2633824e544a8813bd140ae6c58c6fa938696cf530146edca8c865c5a8e92ace',
      'generatedAt': '2026-10-20T08:03:06.120Z',
      'segmentCount': 2,
    },
    'fileSha256':
        '8307dfc0adf0c3162443a645ab863c3d585d2becda76a68e95e3709d010af916',
    'reloaded': {'status': 'verified', 'hasMetadata': true, 'issues': []},
    'reloadedLocked': ['<dir>/rel_a.mp4', '<dir>/rel_b.mp4'],
  },
  'quarantined': {
    'saved': false,
    'keys': [
      'schemaVersion',
      'rideSessionId',
      'sessionComplete',
      'storagePolicy',
      'publicExportRelativePath',
      'storageDirectory',
      'sampleRateMs',
      'videoPath',
      'videoFileName',
      'segmentPaths',
      'lockedSegmentPaths',
      'segmentTimeline',
      'recordingSettings',
      'startedAt',
      'endedAt',
      'distanceKm',
      'maxSpeedKmh',
      'averageSpeedKmh',
      'mockLocationDetected',
      'incidents',
      'samples',
      'integrity',
    ],
    'lockedSegmentPaths': ['/nonexistent-root/elsewhere/q_out.mp4'],
    'envelope': {
      'keys': [
        'algo',
        'envelopeVersion',
        'segmentCount',
        'hashedSegmentCount',
        'segmentHashes',
        'generatedAt',
        'payloadHash',
      ],
      'envelopeVersion': 2,
      'payloadHash':
          '38a4240ab901531e73ea8b12e7df0a50325b1931b083fcf17d85536c433f8c6e',
      'generatedAt': '2026-10-20T08:03:06.120Z',
      'segmentCount': 2,
    },
    'fileSha256':
        '63f3b0935515cc1f1d676ba9994190e861959698209b9bbac688e8bc0a14aa91',
    'reloaded': {
      'status': 'modified',
      'hasMetadata': true,
      'issues': [
        'orphan-integrity-hash:/nonexistent-root/elsewhere/q_out.mp4',
        'quarantined-segment-paths:1',
      ],
    },
    'reloadedLocked': [],
  },
};
