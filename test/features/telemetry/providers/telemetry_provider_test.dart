import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:motocam/core/ride_file/ride_telemetry_codec.dart' as ride_codec;
import 'package:motocam/core/services/ride_signing_service.dart';
import 'package:motocam/features/history/models/ride_record.dart';
import 'package:motocam/features/telemetry/providers/telemetry_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/ride_sim.dart';
import '../../../support/test_signing_key.dart';

final String _sep = Platform.pathSeparator;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Position createMockPosition({
    required double latitude,
    required double longitude,
    required double speed, // in m/s
    required double accuracy,
    required double heading,
    required DateTime timestamp,
    bool isMocked = false,
  }) {
    return Position(
      latitude: latitude,
      longitude: longitude,
      timestamp: timestamp,
      accuracy: accuracy,
      altitude: 0.0,
      heading: heading,
      speed: speed,
      speedAccuracy: 0.0,
      altitudeAccuracy: 0.0,
      headingAccuracy: 0.0,
      isMocked: isMocked,
    );
  }

  group('TelemetryProvider Tests', () {
    late TelemetryProvider provider;

    setUp(() {
      provider = TelemetryProvider(sampleInterval: const Duration(seconds: 1));
    });

    tearDown(() {
      provider.dispose();
    });

    test('initial state defaults are correct', () {
      expect(provider.isRideActive, isFalse);
      expect(provider.isTracking, isFalse);
      expect(provider.rideDistanceKm, 0.0);
      expect(provider.maxSpeedKmh, 0.0);
      expect(provider.averageSpeedKmh, 0.0);
      expect(provider.currentData.speed, 0.0);
      expect(provider.currentData.distanceKm, 0.0);
      expect(provider.currentData.hasFix, isFalse);
      expect(provider.activeRideSamples, isEmpty);
    });

    test('startRideSession sets active state and clears values', () {
      provider.startRideSession();
      expect(provider.isRideActive, isTrue);
      expect(provider.rideDistanceKm, 0.0);
      expect(provider.maxSpeedKmh, 0.0);
      expect(provider.activeRideSamples.length, 1); // captures the start sample
      expect(provider.activeRideSamples.first.distanceKm, 0.0);
    });

    test('startRideSession uses the given ride zero for elapsedMs', () {
      final startedAt = DateTime.now().subtract(const Duration(seconds: 3));
      provider.startRideSession(startedAt: startedAt);
      expect(
        provider.activeRideSamples.first.elapsedMs,
        greaterThanOrEqualTo(3000),
      );
    });

    test('startRideSession clamps a future ride zero to now', () {
      provider.startRideSession(
        startedAt: DateTime.now().add(const Duration(minutes: 1)),
      );
      expect(provider.activeRideSamples.first.elapsedMs, lessThan(1000));
    });

    test('samples before the first fix are marked as having no fix', () {
      provider.startRideSession();
      final sample = provider.activeRideSamples.first;
      expect(sample.hasFix, isFalse);
      expect(sample.fixAgeMs, isNull);
    });

    test('samples after a recent fix are marked as having a fix', () {
      provider.updateLocationForTesting(
        createMockPosition(
          latitude: 28.6139,
          longitude: 77.2090,
          speed: 0.0,
          accuracy: 4.0,
          heading: 0.0,
          timestamp: DateTime.now(),
        ),
      );
      provider.startRideSession();
      final sample = provider.activeRideSamples.first;
      expect(sample.hasFix, isTrue);
      expect(sample.fixAgeMs, isNotNull);
      expect(sample.latitude, 28.6139);
    });

    test('ignores location updates timestamped before ride start', () {
      final now = DateTime.now();
      provider.startRideSession();

      // Let's create a position that is before the ride start time
      final stalePosition = createMockPosition(
        latitude: 37.7749,
        longitude: -122.4194,
        speed: 10.0, // 36 km/h
        accuracy: 5.0,
        heading: 90.0,
        timestamp: now.subtract(const Duration(minutes: 5)),
      );

      provider.updateLocationForTesting(stalePosition);
      expect(provider.rideDistanceKm, 0.0);
      expect(provider.currentData.latitude, 0.0); // should not be updated
    });

    test('updates location and calculates distance during active ride', () {
      final now = DateTime.now();
      provider.startRideSession();

      // First valid position update (initializes lastRidePosition, no distance added yet)
      final pos1 = createMockPosition(
        latitude: 37.7749,
        longitude: -122.4194,
        speed: 5.0, // 18 km/h
        accuracy: 3.0,
        heading: 90.0,
        timestamp: now.add(const Duration(seconds: 1)),
      );
      provider.updateLocationForTesting(pos1);
      expect(provider.rideDistanceKm, 0.0);
      expect(provider.currentData.latitude, 37.7749);
      expect(provider.currentData.longitude, -122.4194);

      // Second valid position update (100 meters away)
      // Moving from 37.7749, -122.4194 to 37.7749, -122.4183 is ~96.7 meters
      final pos2 = createMockPosition(
        latitude: 37.7749,
        longitude: -122.4183,
        speed: 10.0, // 36 km/h
        accuracy: 3.0,
        heading: 90.0,
        timestamp: now.add(const Duration(seconds: 3)),
      );
      provider.updateLocationForTesting(pos2);
      expect(provider.rideDistanceKm, greaterThan(0.0));
      expect(provider.rideDistanceKm, closeTo(0.096, 0.01));
    });

    test('stationary GPS jitter does not accumulate ride distance', () {
      final start = DateTime.now().add(const Duration(seconds: 1));
      provider.startRideSession();

      // 2 minutes at 2 Hz wandering about +/-2 m around one point.
      for (var i = 0; i < 240; i++) {
        final offsetDegrees = (i.isEven ? 1 : -1) * 0.000018; // ~2 m
        provider.updateLocationForTesting(
          createMockPosition(
            latitude: 28.6139 + offsetDegrees,
            longitude: 77.2090,
            speed: 0.1,
            accuracy: 5.0,
            heading: 0.0,
            timestamp: start.add(Duration(milliseconds: 500 * i)),
          ),
        );
      }

      expect(provider.rideDistanceKm, 0.0);
    });

    test('a fix older than the last accepted fix is ignored', () {
      final now = DateTime.now();
      provider.startRideSession();
      provider.updateLocationForTesting(
        createMockPosition(
          latitude: 37.7749,
          longitude: -122.4194,
          speed: 5.0,
          accuracy: 3.0,
          heading: 90.0,
          timestamp: now.add(const Duration(seconds: 5)),
        ),
      );
      provider.updateLocationForTesting(
        createMockPosition(
          latitude: 37.7800,
          longitude: -122.4100,
          speed: 5.0,
          accuracy: 3.0,
          heading: 90.0,
          timestamp: now.add(const Duration(seconds: 4)),
        ),
      );

      expect(provider.currentData.latitude, 37.7749);
      expect(provider.rideDistanceKm, 0.0);
    });

    test('an invalid (negative) course keeps the previous bearing', () {
      final now = DateTime.now();
      provider.updateLocationForTesting(
        createMockPosition(
          latitude: 37.7749,
          longitude: -122.4194,
          speed: 5.0,
          accuracy: 3.0,
          heading: 90.0,
          timestamp: now,
        ),
      );
      provider.updateLocationForTesting(
        createMockPosition(
          latitude: 37.7750,
          longitude: -122.4194,
          speed: 5.0,
          accuracy: 3.0,
          heading: -1.0,
          timestamp: now.add(const Duration(seconds: 1)),
        ),
      );

      expect(provider.currentData.bearing, 90.0);
    });

    test('mock location fixes during a ride are flagged', () {
      provider.startRideSession();
      expect(provider.mockLocationDetected, isFalse);
      provider.updateLocationForTesting(
        createMockPosition(
          latitude: 37.7749,
          longitude: -122.4194,
          speed: 5.0,
          accuracy: 3.0,
          heading: 90.0,
          timestamp: DateTime.now().add(const Duration(seconds: 1)),
          isMocked: true,
        ),
      );
      expect(provider.mockLocationDetected, isTrue);
    });

    test('stationary detection filters out very slow speed', () {
      final now = DateTime.now();
      provider.startRideSession();

      // Update location with extremely slow speed (less than 0.6 km/h)
      // 0.1 m/s = 0.36 km/h
      final slowPos = createMockPosition(
        latitude: 37.7749,
        longitude: -122.4194,
        speed: 0.1,
        accuracy: 2.0,
        heading: 0.0,
        timestamp: now.add(const Duration(seconds: 1)),
      );

      provider.updateLocationForTesting(slowPos);
      expect(provider.currentData.speed, 0.0); // Filtered to 0
    });

    test('a first fix with poor accuracy does not anchor ride distance', () {
      final now = DateTime.now();
      provider.startRideSession();

      // A wild first fix ~1.1 km away with 500 m accuracy.
      provider.updateLocationForTesting(
        createMockPosition(
          latitude: 37.7849,
          longitude: -122.4194,
          speed: 0.0,
          accuracy: 500.0,
          heading: 0.0,
          timestamp: now.add(const Duration(seconds: 1)),
        ),
      );
      // Good fixes afterwards, ~97 m apart.
      provider.updateLocationForTesting(
        createMockPosition(
          latitude: 37.7749,
          longitude: -122.4194,
          speed: 10.0,
          accuracy: 3.0,
          heading: 90.0,
          timestamp: now.add(const Duration(seconds: 60)),
        ),
      );
      provider.updateLocationForTesting(
        createMockPosition(
          latitude: 37.7749,
          longitude: -122.4183,
          speed: 10.0,
          accuracy: 3.0,
          heading: 90.0,
          timestamp: now.add(const Duration(seconds: 70)),
        ),
      );

      expect(provider.rideDistanceKm, closeTo(0.096, 0.01));
    });

    test('non-finite accelerometer samples are ignored', () {
      provider.updateAccelerometerForTesting(1.0, 0.0, 0.0);
      final before = provider.currentData.accelerationG;
      provider.updateAccelerometerForTesting(double.nan, 0.0, 0.0);
      provider.updateAccelerometerForTesting(double.infinity, 0.0, 0.0);

      expect(provider.currentData.accelerationG, before);
      expect(provider.currentData.accelerationG.isFinite, isTrue);
    });

    test('accelerometer samples do not notify listeners', () {
      // About 100 samples a second used to cost a throttled notify and a
      // Flutter frame each; no live widget shows the acceleration.
      var notifications = 0;
      provider.addListener(() => notifications++);
      final start = DateTime.now();
      for (var i = 0; i < 50; i++) {
        provider.updateAccelerometerForTesting(
          0.1,
          0.0,
          0.0,
          timestamp: start.add(Duration(milliseconds: 10 * i)),
        );
      }

      expect(notifications, 0);
      expect(provider.currentData.accelerationG, greaterThan(0));
    });

    test('a GPS fix inside the UI throttle interval is delivered when the '
        'interval ends', () async {
      provider.setSpeedUiRefreshInterval(const Duration(milliseconds: 300));
      var notifications = 0;
      provider.addListener(() => notifications++);

      provider.updateLocationForTesting(
        createMockPosition(
          latitude: 12.97,
          longitude: 77.59,
          speed: 10.0,
          accuracy: 5.0,
          heading: 90.0,
          timestamp: DateTime.now(),
        ),
      );
      expect(notifications, 0);

      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(notifications, 1);
    });

    test(
      'clearHistory resets ride statistics but keeps the incident count',
      () {
        final now = DateTime.now();
        provider.startRideSession();
        provider.setIncidentDetectionConfig(
          triggerGForce: 2.0,
          debounce: const Duration(seconds: 5),
        );

        final pos = createMockPosition(
          latitude: 37.7749,
          longitude: -122.4194,
          speed: 15.0,
          accuracy: 3.0,
          heading: 90.0,
          timestamp: now.add(const Duration(seconds: 1)),
        );
        provider.updateLocationForTesting(pos);

        recordTipOverIncident(provider);
        expect(provider.incidentCount, 1);

        provider.clearHistory();
        expect(provider.rideDistanceKm, 0.0);
        expect(provider.maxSpeedKmh, 0.0);
        expect(provider.averageSpeedKmh, 0.0);
        // clearHistory() deliberately does not reset the incident count.
        expect(provider.incidentCount, 1);
        expect(provider.currentData.latitude, 0.0); // Reset to empty
      },
    );

    test('pauseTracking is ignored during a ride', () {
      provider.startRideSession();
      provider.pauseTracking();
      expect(provider.isRideActive, isTrue);
    });
  });

  group('TelemetryProvider.shouldAccumulateDistance', () {
    final anchor = DateTime(2026, 1, 1, 12);

    bool accumulate({
      double meters = 10,
      double accuracy = 5,
      double gpsSpeedKmh = 0,
      Duration after = const Duration(seconds: 1),
    }) => TelemetryProvider.shouldAccumulateDistance(
      meters: meters,
      accuracyMeters: accuracy,
      gpsSpeedKmh: gpsSpeedKmh,
      fixTimestamp: anchor.add(after),
      anchorTimestamp: anchor,
    );

    test('accepts real movement', () {
      expect(accumulate(meters: 10, accuracy: 5), isTrue);
    });

    test('rejects displacement below the noise floor without GPS speed', () {
      expect(accumulate(meters: 2, accuracy: 3), isFalse);
      expect(accumulate(meters: 8, accuracy: 20), isFalse);
    });

    test('accepts small displacement when GPS speed shows motion', () {
      expect(accumulate(meters: 2, accuracy: 3, gpsSpeedKmh: 5), isTrue);
    });

    test('rejects fixes with poor accuracy', () {
      expect(accumulate(meters: 60, accuracy: 80), isFalse);
    });

    test('rejects fixes that are not newer than the anchor', () {
      expect(accumulate(after: Duration.zero), isFalse);
      expect(accumulate(after: const Duration(seconds: -1)), isFalse);
    });

    test('rejects implausible jumps', () {
      // 60 m in 0.5 s = 432 km/h.
      expect(
        accumulate(
          meters: 60,
          accuracy: 10,
          after: const Duration(milliseconds: 500),
        ),
        isFalse,
      );
    });

    test('treats unknown accuracy as acceptable', () {
      expect(accumulate(meters: 10, accuracy: 0), isTrue);
      expect(accumulate(meters: 10, accuracy: -1), isTrue);
    });
  });

  group('sanitizeJsonValue', () {
    test('replaces non-finite doubles with null at any depth', () {
      final sanitized = ride_codec.sanitizeJsonValue({
        'a': double.nan,
        'b': [1.5, double.infinity],
        'c': {'d': double.negativeInfinity, 'e': 'x', 'f': 2},
      });
      expect(sanitized, {
        'a': null,
        'b': [1.5, null],
        'c': {'d': null, 'e': 'x', 'f': 2},
      });
      expect(() => jsonEncode(sanitized), returnsNormally);
    });
  });

  group('TelemetryProvider persistence', () {
    late Directory tempRoot;
    late Directory storageDirectory;
    late TelemetryProvider provider;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('motocam_telemetry_');
      storageDirectory = Directory(
        '${tempRoot.path}${_sep}storage${_sep}MotoCam${_sep}Recordings',
      );
      await storageDirectory.create(recursive: true);
      provider = TelemetryProvider(sampleInterval: const Duration(seconds: 1));
    });

    tearDown(() async {
      provider.dispose();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Future<File> createSegment(String name, String content) async {
      final file = File('${storageDirectory.path}$_sep$name');
      await file.writeAsString(content, flush: true);
      return file;
    }

    Future<Map<String, dynamic>> readJson(String path) async =>
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;

    void recordIncident(TelemetryProvider provider) =>
        recordTipOverIncident(provider);

    test('stop writes a sealed ride that RideRecord verifies', () async {
      final segment1 = await createSegment('segment_1.mp4', 'video-one');
      final segment2 = await createSegment('segment_2.mp4', 'video-two');

      provider.startRideSession();
      recordIncident(provider);
      expect(provider.incidentCount, 1);

      final path = await provider.stopRideSessionAndPersist(
        segment2.path,
        segmentPaths: [segment1.path, segment2.path],
        lockedSegmentPaths: [segment1.path],
      );

      expect(path, isNotNull);
      expect(provider.isRideActive, isFalse);
      expect(provider.isPersistingRide, isFalse);
      expect(provider.lastPersistError, isNull);

      final json = await readJson(path!);
      expect(json['schemaVersion'], TelemetryProvider.rideSchemaVersion);
      expect(json['sessionComplete'], isTrue);
      expect(json['startedAt'] as String, endsWith('Z'));
      expect(json['endedAt'] as String, endsWith('Z'));
      expect(json['mockLocationDetected'], isFalse);
      expect(json['segmentPaths'], [segment1.path, segment2.path]);
      expect(json['lockedSegmentPaths'], [segment1.path]);

      final incidents = json['incidents'] as List<dynamic>;
      expect(incidents, hasLength(1));
      final incident = incidents.single as Map<String, dynamic>;
      expect(incident['reason'], 'auto-crash');
      expect(incident['triggerGForce'], 2.0);
      expect((incident['gForce'] as num).toDouble(), greaterThan(2.0));
      expect(incident['timestamp'] as String, endsWith('Z'));

      final samples = json['samples'] as List<dynamic>;
      expect(samples, isNotEmpty);
      expect((samples.first as Map)['timestamp'] as String, endsWith('Z'));

      final integrity = json['integrity'] as Map<String, dynamic>;
      final hashes = integrity['segmentHashes'] as Map<String, dynamic>;
      expect(
        hashes[segment1.path],
        sha256.convert(utf8.encode('video-one')).toString(),
      );
      expect(
        hashes[segment2.path],
        sha256.convert(utf8.encode('video-two')).toString(),
      );
      expect(integrity['segmentCount'], 2);

      final record = await RideRecord.fromTelemetryFile(
        File(path),
        verifySegments: true,
      );
      expect(record, isNotNull);
      expect(
        record!.integrity.isVerified,
        isTrue,
        reason: record.integrity.issues.join(', '),
      );
      expect(record.isSessionComplete, isTrue);
    });

    test(
      'checkpoint writes a sealed incomplete ride that stop completes',
      () async {
        final segment1 = await createSegment('segment_1.mp4', 'video-one');

        provider.startRideSession();
        final checkpointPath = await provider.checkpointRideSession(
          segmentPaths: [segment1.path],
          lockedSegmentPaths: const [],
        );
        expect(checkpointPath, isNotNull);

        final checkpoint = await readJson(checkpointPath!);
        expect(checkpoint['sessionComplete'], isFalse);
        expect(checkpoint['segmentPaths'], [segment1.path]);
        expect(checkpoint['integrity'], isA<Map<String, dynamic>>());

        final recovered = await RideRecord.fromTelemetryFile(
          File(checkpointPath),
          verifySegments: true,
        );
        expect(recovered, isNotNull);
        expect(recovered!.isSessionComplete, isFalse);
        expect(
          recovered.integrity.isVerified,
          isTrue,
          reason: recovered.integrity.issues.join(', '),
        );

        final segment2 = await createSegment('segment_2.mp4', 'video-two');
        final finalPath = await provider.stopRideSessionAndPersist(
          segment2.path,
          segmentPaths: [segment1.path, segment2.path],
        );

        expect(finalPath, checkpointPath);
        final completed = await readJson(finalPath!);
        expect(completed['sessionComplete'], isTrue);
        expect(completed['segmentPaths'], [segment1.path, segment2.path]);
        final telemetryFiles = storageDirectory.listSync().where(
          (entity) => entity.path.endsWith('.telemetry.json'),
        );
        expect(telemetryFiles, hasLength(1));
      },
    );

    test(
      'a checkpoint of one segment and a final save of three verify',
      () async {
        final segmentA = await createSegment('segment_a.mp4', 'video-a');
        provider.startRideSession();
        final checkpointPath = await provider.checkpointRideSession(
          segmentPaths: [segmentA.path],
          lockedSegmentPaths: [segmentA.path],
        );
        expect(checkpointPath, isNotNull);

        final segmentB = await createSegment('segment_b.mp4', 'video-b');
        final segmentC = await createSegment('segment_c.mp4', 'video-c');
        final finalPath = await provider.stopRideSessionAndPersist(
          segmentC.path,
          segmentPaths: [segmentA.path, segmentB.path, segmentC.path],
          lockedSegmentPaths: [segmentA.path],
        );
        expect(finalPath, checkpointPath);

        final json = await readJson(finalPath!);
        expect(json['sessionComplete'], isTrue);
        final integrity = json['integrity'] as Map<String, dynamic>;
        expect(integrity['segmentCount'], 3);
        expect((integrity['segmentHashes'] as Map).keys, [
          segmentA.path,
          segmentB.path,
          segmentC.path,
        ]);

        final record = await RideRecord.fromTelemetryFile(
          File(finalPath),
          verifySegments: true,
        );
        expect(record, isNotNull);
        expect(
          record!.integrity.isVerified,
          isTrue,
          reason: record.integrity.issues.join(', '),
        );
        expect(record.isSessionComplete, isTrue);
        expect(record.segmentPaths, [
          segmentA.path,
          segmentB.path,
          segmentC.path,
        ]);
        expect(record.missingSegmentPaths, isEmpty);
        expect(record.lockedSegmentPaths, [segmentA.path]);
      },
    );

    test(
      'the final save is signed and registered; checkpoints are not',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final phone = TestSigningKey.generate(1);
        final signedHashes = <String>[];
        final registry = SignedRideRegistry();
        final signing = TelemetryProvider(
          rideSigner: (payloadHash) async {
            signedHashes.add(payloadHash);
            return phone.sign(payloadHash);
          },
          signedRideRegistry: registry,
        );
        addTearDown(signing.dispose);

        final segmentA = await createSegment('signed_a.mp4', 'video-a');
        signing.startRideSession();
        final checkpointPath = await signing.checkpointRideSession(
          segmentPaths: [segmentA.path],
          lockedSegmentPaths: const [],
        );
        final checkpoint = await readJson(checkpointPath!);
        expect((checkpoint['integrity'] as Map)['envelopeVersion'], 2);
        expect(signedHashes, isEmpty);

        final path = await signing.stopRideSessionAndPersist(
          segmentA.path,
          segmentPaths: [segmentA.path],
        );
        final json = await readJson(path!);
        final integrity = json['integrity'] as Map<String, dynamic>;
        expect(integrity['envelopeVersion'], 3);
        expect(signedHashes, [integrity['payloadHash']]);
        expect(
          (integrity['signature'] as Map)['publicKey'],
          phone.publicKeyBase64,
        );

        final record = await RideRecord.fromTelemetryFile(
          File(path),
          verifySegments: true,
        );
        expect(record!.integrity.isVerified, isTrue);
        expect(await registry.idsFor(phone.publicKeyBase64), {
          json['rideSessionId'],
        });
        expect(
          (await registry.registrationsFor(
            phone.publicKeyBase64,
          )).segmentFileNames,
          {'signed_a.mp4'},
        );
      },
    );

    test('a failed signature saves the ride as version 2', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final registry = SignedRideRegistry();
      final signing = TelemetryProvider(
        rideSigner: (_) async => throw StateError('keystore'),
        signedRideRegistry: registry,
      );
      addTearDown(signing.dispose);

      final segment = await createSegment('unsigned_a.mp4', 'video-a');
      signing.startRideSession();
      final path = await signing.stopRideSessionAndPersist(
        segment.path,
        segmentPaths: [segment.path],
      );
      expect(path, isNotNull);
      expect(signing.lastPersistError, isNull);
      final json = await readJson(path!);
      final integrity = json['integrity'] as Map<String, dynamic>;
      expect(integrity['envelopeVersion'], 2);
      expect(integrity.containsKey('signature'), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SignedRideRegistry.prefsKey), isNull);
    });

    test('checkpoint does nothing without an active ride', () async {
      final segment1 = await createSegment('segment_1.mp4', 'video-one');
      final path = await provider.checkpointRideSession(
        segmentPaths: [segment1.path],
      );
      expect(path, isNull);
    });

    test('a failed save keeps the ride for a retry', () async {
      final segment1 = await createSegment('segment_1.mp4', 'video-one');
      provider.startRideSession();
      final checkpointPath = await provider.checkpointRideSession(
        segmentPaths: [segment1.path],
      );
      expect(checkpointPath, isNotNull);

      // Block the target path with a directory so every write fails.
      await File(checkpointPath!).delete();
      final blocker = Directory(checkpointPath);
      await blocker.create();

      final failedPath = await provider.stopRideSessionAndPersist(
        segment1.path,
        segmentPaths: [segment1.path],
      );
      expect(failedPath, isNull);
      expect(provider.lastPersistError, isNotNull);
      expect(provider.hasPendingPersist, isTrue);

      await blocker.delete(recursive: true);
      final retriedPath = await provider.retryPendingPersist();
      expect(retriedPath, checkpointPath);
      expect(provider.lastPersistError, isNull);
      expect(provider.hasPendingPersist, isFalse);
      final json = await readJson(retriedPath!);
      expect(json['sessionComplete'], isTrue);
    });

    test(
      'a ride started while the previous one is saving is not affected',
      () async {
        final segment1 = await createSegment('segment_1.mp4', 'video-one');
        // A long sample interval keeps the sample timer from adding samples
        // while the save is awaited.
        final slowProvider = TelemetryProvider(
          sampleInterval: const Duration(minutes: 10),
        );
        addTearDown(slowProvider.dispose);
        slowProvider.startRideSession();

        final pendingSave = slowProvider.stopRideSessionAndPersist(
          segment1.path,
          segmentPaths: [segment1.path],
        );
        slowProvider.startRideSession();
        final newRideSamples = slowProvider.activeRideSamples.length;

        final path = await pendingSave;
        expect(path, isNotNull);
        expect(slowProvider.isRideActive, isTrue);
        expect(slowProvider.activeRideSamples.length, newRideSamples);
        expect(newRideSamples, greaterThan(0));
      },
    );

    test(
      'a later successful save does not discard an earlier failed one',
      () async {
        final segment1 = await createSegment('segment_1.mp4', 'video-one');
        provider.startRideSession();
        final firstPath = await provider.checkpointRideSession(
          segmentPaths: [segment1.path],
        );
        expect(firstPath, isNotNull);
        await File(firstPath!).delete();
        final blocker = Directory(firstPath);
        await blocker.create();

        expect(
          await provider.stopRideSessionAndPersist(
            segment1.path,
            segmentPaths: [segment1.path],
          ),
          isNull,
        );
        expect(provider.hasPendingPersist, isTrue);

        // A second ride saves fine while the first is still pending.
        final segment2 = await createSegment('segment_2.mp4', 'video-two');
        provider.startRideSession();
        final secondPath = await provider.stopRideSessionAndPersist(
          segment2.path,
          segmentPaths: [segment2.path],
        );
        expect(secondPath, isNotNull);
        expect(provider.hasPendingPersist, isTrue);
        expect(provider.lastPersistError, isNotNull);

        await blocker.delete(recursive: true);
        expect(await provider.retryPendingPersist(), firstPath);
        expect(provider.hasPendingPersist, isFalse);
        expect(provider.lastPersistError, isNull);
        expect((await readJson(firstPath))['sessionComplete'], isTrue);
      },
    );
  });
}
