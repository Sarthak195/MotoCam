import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:motocam/features/telemetry/crash_debug_log.dart';
import 'package:motocam/features/telemetry/providers/telemetry_provider.dart';

import '../../../support/ride_sim.dart';

File _logFile(Directory dir, String id) => File(
  '${dir.path}${Platform.pathSeparator}crash_debug'
  '${Platform.pathSeparator}$id.jsonl',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Crash debug log (provider)', () {
    late Directory dir;
    late TelemetryProvider provider;
    late DateTime rideStart;
    late RideSim sim;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('motocam_crash_debug_');
      rideStart = DateTime.now();
    });

    tearDown(() {
      provider.dispose();
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    void startRide({
      bool enabled = true,
      Future<Directory> Function()? directory,
    }) {
      provider = TelemetryProvider(
        clock: () => sim.t,
        crashDebugLogEnabled: enabled,
        crashDebugDirectory: directory ?? () async => dir,
      );
      sim = RideSim(provider, start: rideStart);
      provider.startRideSession(startedAt: rideStart);
      provider.setIncidentDetectionConfig(
        triggerGForce: 3.5,
        debounce: const Duration(seconds: 6),
      );
    }

    Future<List<Map<String, dynamic>>> endRideAndRead() async {
      final id = provider.rideSessionId!;
      provider.cancelRideSession();
      await provider.crashDebugLogClosedForTesting;
      final file = _logFile(dir, id);
      expect(file.existsSync(), isTrue);
      return [
        for (final line in file.readAsLinesSync())
          jsonDecode(line) as Map<String, dynamic>,
      ];
    }

    void crashAtSpeed() {
      sim.speedKmh = 50;
      sim.quiet(const Duration(seconds: 3));
      sim.jolt();
      sim.speedKmh = 0;
      sim.quiet(const Duration(seconds: 5));
    }

    test('a candidate confirmed by an abrupt stop is logged', () async {
      startRide();
      crashAtSpeed();
      expect(provider.incidentCount, 1);

      final lines = await endRideAndRead();
      expect(lines.first['e'], 'start');
      expect(lines.last['e'], 'summary');
      expect(lines.first['trigG'], 3.5);
      expect(lines.first['ride'], isA<String>());

      final cand = lines.singleWhere((l) => l['e'] == 'cand');
      expect(cand['peakG'] as double, greaterThanOrEqualTo(3.5));
      expect(cand['preKmh'] as double, closeTo(50, 5));
      expect(cand['preAgeMs'], isA<int>());
      expect(cand['ruleA'], isTrue);
      expect(cand['deadlineMs'], isA<int>());
      expect(cand['ruleB'], isTrue);
      expect(cand['t'] as int, closeTo(3040, 200));
      expect(cand['s'], isA<int>());

      final confirmed = lines.singleWhere((l) => l['e'] == 'confirmed');
      expect(confirmed['by'], 'abruptStop');
      expect(confirmed['delayMs'] as int, inInclusiveRange(1, 10000));
      expect(confirmed['peakG'] as double, closeTo(6.0, 0.01));

      final summary = lines.last;
      expect(summary['candidates'], 1);
      expect(summary['abruptStop'], 1);
      expect(summary['tipOver'], 0);
      expect(summary['notConfirmed'], 0);
      expect(summary['dropped'], 0);
      expect(summary['maxAvgG'] as double, greaterThanOrEqualTo(3.5));
    });

    test('a candidate confirmed by a tip-over is logged', () async {
      startRide();
      sim.quiet(const Duration(seconds: 2));
      sim.jolt();
      sim.gravity = const [9.81, 0.0, 0.0];
      sim.quiet(const Duration(seconds: 4));
      expect(provider.incidentCount, 1);

      final lines = await endRideAndRead();
      final cand = lines.singleWhere((l) => l['e'] == 'cand');
      expect(cand['ruleA'], isFalse);
      expect(cand['preKmh'], isNull);
      expect(cand['ruleB'], isTrue);
      expect(lines.singleWhere((l) => l['e'] == 'confirmed')['by'], 'tipOver');
      expect(lines.last['tipOver'], 1);
    });

    test('a candidate that expires says which rules failed', () async {
      startRide();
      sim.speedKmh = 50;
      sim.quiet(const Duration(seconds: 3));
      sim.jolt();
      sim.quiet(const Duration(seconds: 12));
      expect(provider.incidentCount, 0);

      final lines = await endRideAndRead();
      final expired = lines.singleWhere((l) => l['e'] == 'expired');
      expect(expired['delayMs'] as int, greaterThan(10000));
      expect(expired['ruleA'], 'neverBelowNearStop');
      expect(expired['minKmh'] as double, closeTo(50, 5));
      expect(expired['fixes'] as int, greaterThan(5));
      expect(expired['ruleB'], 'tiltBelowLimit');
      expect(expired['maxTiltDeg'] as double, lessThan(10));
      expect(lines.last['notConfirmed'], 1);
      expect(lines.last['abruptStop'], 0);
    });

    test('a candidate pending at ride stop is logged as dropped', () async {
      startRide();
      sim.speedKmh = 50;
      sim.quiet(const Duration(seconds: 3));
      sim.jolt();
      sim.quiet(const Duration(seconds: 1));

      final lines = await endRideAndRead();
      expect(lines.where((l) => l['e'] == 'dropped'), hasLength(1));
      expect(lines.where((l) => l['e'] == 'expired'), isEmpty);
      expect(lines.last['dropped'], 1);
    });

    test('one compact line per second with averaged and raw maxima', () async {
      startRide();
      sim.speedKmh = 50;
      sim.quiet(const Duration(seconds: 3));
      sim.vibrate(const Duration(seconds: 3));
      sim.quiet(const Duration(seconds: 1));

      final lines = await endRideAndRead();
      final secs = lines.where((l) => l['e'] == 'sec').toList();
      expect(secs.length, inInclusiveRange(6, 8));
      for (final sec in secs.take(5)) {
        expect(sec['n'] as int, inInclusiveRange(49, 51));
        expect(sec['trig'], 3.5);
        expect(sec.keys.toSet(), {
          'e',
          't',
          's',
          'avgG',
          'rawG',
          'n',
          'trig',
          'gps',
        });
      }
      // Vibration: raw samples near 8 g, the 100 ms average far below.
      final vibrating = secs.where((s) => (s['rawG'] as double) > 7.0);
      expect(vibrating, isNotEmpty);
      for (final sec in vibrating) {
        expect(sec['avgG'] as double, lessThan(3.5));
      }
      expect(lines.last['candidates'], 0);
      expect(lines.last['maxAvgG'] as double, lessThan(3.5));
      expect(lines.last['seconds'], secs.length);
    });

    test(
      'lines carry the GPS speed details and what the detector got',
      () async {
        startRide();
        sim.speedKmh = 50;
        sim.quiet(const Duration(seconds: 3));
        // A fix that reports speed 0 with no speed accuracy: the detector is
        // fed the smoothed speed instead.
        sim.speedKmh = null;
        provider.updateLocationForTesting(
          Position(
            latitude: 37.7749,
            longitude: -122.4194,
            timestamp: sim.t.add(const Duration(milliseconds: 100)),
            accuracy: 3.0,
            altitude: 0.0,
            altitudeAccuracy: 0.0,
            heading: 90.0,
            headingAccuracy: 0.0,
            speed: 0.0,
            speedAccuracy: 0.0,
            hasSpeed: true,
          ),
        );
        sim.jolt();
        sim.quiet(const Duration(seconds: 2));

        final lines = await endRideAndRead();
        final raw = <Map<String, dynamic>>[
          for (final l in lines)
            if (l['e'] == 'sec' && l['gps'] is Map<String, dynamic>)
              l['gps'] as Map<String, dynamic>,
        ].firstWhere((gps) => gps['src'] == 'raw');
        expect(raw['kmh'], closeTo(50, 0.1));
        expect(raw['acc'], 0.5);
        expect(raw['hasSpd'], isFalse);
        expect(raw['hasAcc'], isFalse);
        expect(raw['fed'], closeTo(50, 0.1));
        expect(raw['age'] as double, lessThan(1.1));

        final cand = lines.singleWhere((l) => l['e'] == 'cand');
        final gps = cand['gps'] as Map<String, dynamic>;
        expect(gps['src'], 'smooth');
        expect(gps['kmh'], 0.0);
        expect(gps['acc'], 0.0);
        expect(gps['hasSpd'], isTrue);
        expect(gps['hasAcc'], isFalse);
        expect(gps['fed'] as double, greaterThan(0.0));
        expect(gps['age'] as double, lessThan(1.0));
      },
    );

    test('nothing is written when disabled', () async {
      startRide(enabled: false);
      crashAtSpeed();
      provider.cancelRideSession();
      await provider.crashDebugLogClosedForTesting;

      expect(provider.incidentCount, 1);
      expect(dir.listSync(), isEmpty);
    });

    test('never writes coordinates', () async {
      startRide();
      crashAtSpeed();
      final id = provider.rideSessionId!;
      await endRideAndRead();

      final text = _logFile(dir, id).readAsStringSync().toLowerCase();
      // The synthetic fixes sit at 37.7749, -122.4194.
      expect(text, isNot(contains('37.77')));
      expect(text, isNot(contains('122.41')));
      expect(text, isNot(contains('lat')));
      expect(text, isNot(contains('lon')));
    });

    test('a failing directory leaves the ride and detection alone', () async {
      startRide(
        directory: () async => throw const FileSystemException('no storage'),
      );
      crashAtSpeed();
      expect(provider.incidentCount, 1);
      provider.cancelRideSession();
      await provider.crashDebugLogClosedForTesting;
      expect(dir.listSync(), isEmpty);
    });
  });

  group('CrashDebugLog file', () {
    late Directory dir;
    final t0 = DateTime(2026, 11, 13, 12);

    setUp(() {
      dir = Directory.systemTemp.createTempSync('motocam_crash_debug_');
    });

    tearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    test(
      'stops growing at the size limit but still writes the summary',
      () async {
        final log = CrashDebugLog(
          rideSessionId: 'cap',
          rideStartedAt: t0,
          resolveDirectory: () async => dir,
          triggerG: 3.5,
          clock: () => t0.add(const Duration(minutes: 10)),
          maxBytes: 1000,
        )..begin();
        for (var i = 0; i < 200; i++) {
          log.onSample(t0.add(Duration(seconds: i)), 1.0, 2.0, 3.5);
        }
        await log.finish();

        final file = _logFile(dir, 'cap');
        final lines = file.readAsLinesSync();
        expect(file.lengthSync(), lessThan(1000 + 300));
        expect(lines.where((l) => l == '{"e":"capped"}'), hasLength(1));
        expect(
          (jsonDecode(lines.last) as Map<String, dynamic>)['e'],
          'summary',
        );
      },
    );

    test('an I/O error disables it and finish still completes', () async {
      final blocker = File('${dir.path}${Platform.pathSeparator}blocker')
        ..writeAsStringSync('x');
      final log = CrashDebugLog(
        rideSessionId: 'bad',
        rideStartedAt: t0,
        // A file where the directory should be makes create() fail.
        resolveDirectory: () async => Directory(blocker.path),
        triggerG: 3.5,
        clock: () => t0,
      )..begin();
      log.onSample(t0, 1.0, 1.0, 3.5);
      await log.finish();

      expect(log.isDisabled, isTrue);
      expect(dir.listSync(), hasLength(1));
    });
  });
}
