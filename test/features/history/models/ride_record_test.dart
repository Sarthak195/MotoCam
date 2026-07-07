import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/features/history/models/ride_record.dart';

void main() {
  group('RideRecord', () {
    test('fromTelemetryFile returns verified ride when integrity matches', () async {
      final tempRoot = await Directory.systemTemp.createTemp('motocam_ride_record_verified_');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final storageDirectory = Directory(
        '${tempRoot.path}${Platform.pathSeparator}storage${Platform.pathSeparator}MotoCam${Platform.pathSeparator}Recordings',
      );
      await storageDirectory.create(recursive: true);

      final segmentFile = File(
        '${storageDirectory.path}${Platform.pathSeparator}segment_01.mp4',
      );
      await segmentFile.writeAsString('segment-one-data');

      final telemetryFile = File(
        '${storageDirectory.path}${Platform.pathSeparator}segment_01.telemetry.json',
      );

      final payload = <String, dynamic>{
        'videoPath': segmentFile.path,
        'segmentPaths': <String>[segmentFile.path],
        'lockedSegmentPaths': <String>[segmentFile.path],
        'segmentTimeline': <Map<String, dynamic>>[
          <String, dynamic>{'path': segmentFile.path, 'startMs': 0, 'endMs': 1200},
        ],
        'storageDirectory': storageDirectory.path,
        'rideSessionId': 'session-verified',
        'sessionComplete': true,
        'distanceKm': 1.25,
        'maxSpeedKmh': 42.0,
        'averageSpeedKmh': 28.4,
        'startedAt': '2026-05-03T10:00:00.000Z',
        'endedAt': '2026-05-03T10:02:00.000Z',
        'samples': <Map<String, dynamic>>[
          <String, dynamic>{
            'timestamp': '2026-05-03T10:00:01.000Z',
            'elapsedMs': 0,
            'latitude': 37.0,
            'longitude': -122.0,
            'speed': 0.0,
            'bearing': 0.0,
            'accelerationG': 0.0,
            'distanceKm': 0.0,
          },
        ],
      };
      final integrity = await _buildIntegrityMetadata(
        payload: payload,
        segmentPaths: <String>[segmentFile.path],
      );

      await telemetryFile.writeAsString(
        jsonEncode(<String, dynamic>{
          ...payload,
          'integrity': integrity,
        }),
      );

      final rideLazy = await RideRecord.fromTelemetryFile(telemetryFile);
      expect(rideLazy, isNotNull);
      expect(rideLazy!.integrity.status, RideIntegrityStatus.verified);
      expect(rideLazy.hasQuarantinedSegments, isFalse);
      expect(rideLazy.segmentPaths, <String>[segmentFile.path]);
      expect(rideLazy.integrity.isVerified, isTrue);

      final rideFull = await RideRecord.fromTelemetryFile(telemetryFile, verifySegments: true);
      expect(rideFull, isNotNull);
      expect(rideFull!.integrity.status, RideIntegrityStatus.verified);
      expect(rideFull.integrity.isVerified, isTrue);

      final rideVerifiedOnDemand = await rideLazy.verifySegmentIntegrity();
      expect(rideVerifiedOnDemand.integrity.status, RideIntegrityStatus.verified);
      expect(rideVerifiedOnDemand.integrity.isVerified, isTrue);
    });

    test('quarantines out-of-scope paths and blocks lock-state updates', () async {
      final tempRoot = await Directory.systemTemp.createTemp('motocam_ride_record_quarantine_');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final storageDirectory = Directory(
        '${tempRoot.path}${Platform.pathSeparator}storage${Platform.pathSeparator}MotoCam${Platform.pathSeparator}Recordings',
      );
      await storageDirectory.create(recursive: true);

      final outsideDirectory = Directory(
        '${tempRoot.path}${Platform.pathSeparator}outside${Platform.pathSeparator}Elsewhere',
      );
      await outsideDirectory.create(recursive: true);

      final goodSegment = File(
        '${storageDirectory.path}${Platform.pathSeparator}segment_good.mp4',
      );
      await goodSegment.writeAsString('good-segment-data');

      final quarantinedSegment = File(
        '${outsideDirectory.path}${Platform.pathSeparator}segment_bad.mp4',
      );
      await quarantinedSegment.writeAsString('bad-segment-data');

      final traversalSegmentPath =
          '${storageDirectory.path}${Platform.pathSeparator}..${Platform.pathSeparator}outside${Platform.pathSeparator}Elsewhere${Platform.pathSeparator}segment_bad.mp4';

      final telemetryFile = File(
        '${storageDirectory.path}${Platform.pathSeparator}segment_good.telemetry.json',
      );
      final telemetryPayload = <String, dynamic>{
        'videoPath': goodSegment.path,
        'segmentPaths': <String>[goodSegment.path, traversalSegmentPath],
        'lockedSegmentPaths': <String>[],
        'segmentTimeline': <Map<String, dynamic>>[
          <String, dynamic>{'path': goodSegment.path, 'startMs': 0, 'endMs': 1200},
          <String, dynamic>{'path': traversalSegmentPath, 'startMs': 1200, 'endMs': 2400},
        ],
        'storageDirectory': storageDirectory.path,
        'rideSessionId': 'session-quarantine',
        'sessionComplete': true,
        'distanceKm': 1.75,
        'maxSpeedKmh': 50.0,
        'averageSpeedKmh': 31.0,
        'startedAt': '2026-05-03T11:00:00.000Z',
        'endedAt': '2026-05-03T11:05:00.000Z',
        'samples': <Map<String, dynamic>>[
          <String, dynamic>{
            'timestamp': '2026-05-03T11:00:01.000Z',
            'elapsedMs': 0,
            'latitude': 37.0,
            'longitude': -122.0,
            'speed': 0.0,
            'bearing': 0.0,
            'accelerationG': 0.0,
            'distanceKm': 0.0,
          },
        ],
      };

      await telemetryFile.writeAsString(jsonEncode(telemetryPayload));
      final before = await telemetryFile.readAsString();

      final ride = await RideRecord.fromTelemetryFile(telemetryFile);
      expect(ride, isNotNull);
      expect(ride!.integrity.status, RideIntegrityStatus.modified);
      expect(ride.hasQuarantinedSegments, isTrue);
      expect(ride.quarantinedSegmentPaths, <String>[traversalSegmentPath]);
      expect(ride.segmentPaths, <String>[goodSegment.path]);

      await ride.setLockState(true);
      final after = await telemetryFile.readAsString();
      expect(after, before);
    });
  });
}

Future<Map<String, dynamic>> _buildIntegrityMetadata({
  required Map<String, dynamic> payload,
  required List<String> segmentPaths,
}) async {
  final payloadWithoutIntegrity = Map<String, dynamic>.from(payload)
    ..remove('integrity');

  final segmentHashes = <String, String>{};
  for (final segmentPath in segmentPaths) {
    final hash = await _hashFileSha256(segmentPath);
    if (hash != null) {
      segmentHashes[segmentPath] = hash;
    }
  }

  return <String, dynamic>{
    'algo': 'sha256',
    'payloadHash': _hashJsonCanonical(payloadWithoutIntegrity),
    'segmentCount': segmentPaths.length,
    'hashedSegmentCount': segmentHashes.length,
    'segmentHashes': segmentHashes,
    'generatedAt': '2026-05-03T12:00:00.000Z',
  };
}

String _hashJsonCanonical(Map<String, dynamic> payload) {
  final canonical = _canonicalizeJsonValue(payload);
  final encoded = utf8.encode(jsonEncode(canonical));
  return sha256.convert(encoded).toString();
}

Object? _canonicalizeJsonValue(Object? value) {
  if (value is Map) {
    final normalizedEntries = value.entries
        .map((entry) => MapEntry(entry.key.toString(), entry.value))
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    final normalized = <String, Object?>{};
    for (final entry in normalizedEntries) {
      normalized[entry.key] = _canonicalizeJsonValue(entry.value);
    }
    return normalized;
  }

  if (value is List) {
    return value.map(_canonicalizeJsonValue).toList(growable: false);
  }

  if (value == null || value is String || value is num || value is bool) {
    return value;
  }

  return value.toString();
}

Future<String?> _hashFileSha256(String path) async {
  final file = File(path);
  if (!await file.exists()) {
    return null;
  }

  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}
