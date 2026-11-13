import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:motocam/features/telemetry/crash_detector.dart';
import 'package:motocam/features/telemetry/providers/telemetry_provider.dart';

import '../../../support/ride_sim.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Crash detection (jolt + confirm)', () {
    late TelemetryProvider provider;
    late DateTime rideStart;
    late RideSim sim;

    setUp(() {
      rideStart = DateTime.now();
      // The provider's wall clock follows the synthetic sensor clock.
      provider = TelemetryProvider(
        sampleInterval: const Duration(seconds: 1),
        clock: () => sim.t,
      );
      sim = RideSim(provider, start: rideStart);
      provider.startRideSession(startedAt: rideStart);
      // Medium sensitivity.
      provider.setIncidentDetectionConfig(
        triggerGForce: 3.5,
        debounce: const Duration(seconds: 6),
      );
    });

    tearDown(() {
      provider.dispose();
    });

    test('handlebar vibration at speed starts no candidate', () {
      sim.speedKmh = 50;
      sim.quiet(const Duration(seconds: 3));
      // 8 g samples: the old 40 ms rule fired on these.
      sim.vibrate(const Duration(seconds: 3));
      // Even an abrupt stop right after does not confirm anything, because
      // no jolt was seen.
      sim.speedKmh = 0;
      sim.quiet(const Duration(seconds: 5));

      expect(provider.incidentCount, 0);
      expect(provider.activeRideIncidentsForTesting, isEmpty);
    });

    test('a sustained jolt while the speed stays high is no incident', () {
      sim.speedKmh = 50;
      sim.quiet(const Duration(seconds: 3));
      sim.jolt(length: const Duration(milliseconds: 300));
      sim.quiet(const Duration(seconds: 12));

      expect(provider.incidentCount, 0);
    });

    test('a jolt then an abrupt near-stop is one incident at the jolt', () {
      sim.speedKmh = 50;
      sim.quiet(const Duration(seconds: 3));
      final joltStartMs = sim.elapsedMsSince(rideStart);
      sim.jolt();
      sim.speedKmh = 0;
      expect(provider.incidentCount, 0, reason: 'not confirmed yet');
      sim.quiet(const Duration(seconds: 5));

      expect(provider.incidentCount, 1);
      expect(provider.lastIncidentGForce, closeTo(6.0, 0.01));
      final incident = provider.activeRideIncidentsForTesting.single;
      // The jolt starts 40 ms into the pulse, when the 100 ms average
      // reaches 3.5 g; the confirmation came seconds later.
      expect(incident['elapsedMs'] as int, closeTo(joltStartMs + 40, 60));
      expect(provider.lastIncidentJoltElapsedMs, incident['elapsedMs']);
      expect(incident['reason'], 'auto-crash');
      expect(incident['triggerGForce'], 3.5);
      expect(incident['gForce'] as double, closeTo(6.0, 0.01));
      final timestamp = DateTime.parse(incident['timestamp'] as String);
      expect(
        timestamp.difference(rideStart).inMilliseconds,
        closeTo(joltStartMs + 40, 60),
      );
    });

    test('a fix arriving while the jolt builds keeps the pre-jolt speed', () {
      sim.speedKmh = 50;
      // The jolt's run starts at 2.98 s and is reported at 3.04 s; the fix
      // at 3.00 s lands in between.
      sim.quiet(const Duration(milliseconds: 2940));
      final joltStartMs = sim.elapsedMsSince(rideStart);
      sim.jolt();
      sim.speedKmh = 0;
      sim.quiet(const Duration(seconds: 5));

      expect(provider.incidentCount, 1);
      expect(
        provider.activeRideIncidentsForTesting.single['elapsedMs'] as int,
        closeTo(joltStartMs + 40, 60),
      );
    });

    test('a pothole followed by a gradual stop is no incident', () {
      sim.speedKmh = 40;
      sim.quiet(const Duration(seconds: 3));
      sim.jolt();
      // One second to react, then a normal 0.25 g stop (about 9 km/h per
      // second) to a standstill well inside the 10 s window.
      sim.quiet(const Duration(seconds: 1));
      for (final speed in [31.0, 22.0, 13.0, 4.0, 0.0]) {
        sim.speedKmh = speed;
        sim.quiet(const Duration(seconds: 1));
      }
      sim.quiet(const Duration(seconds: 6));

      expect(provider.incidentCount, 0);
    });

    // Speed on a stop at [decelerationG] starting at the jolt: [fromKmh]
    // until the jolt, then 0.6 g (the slowest stop rule (a) is meant to
    // catch) takes about 21.2 km/h off per second.
    double speedAfter(
      double fromKmh,
      Duration sinceJolt, {
      required double decelerationG,
    }) {
      final seconds = math.max(0, sinceJolt.inMilliseconds / 1000.0);
      return math.max(0.0, fromKmh - decelerationG * 9.81 * 3.6 * seconds);
    }

    // A jolt at 3.5 s from [fromKmh], then one fix per second from 4 s on.
    // The fix arriving at 4 + i s reports the speed measured lagsS[i]
    // seconds earlier on a stop at [decelerationG] starting at the jolt.
    // Returns the jolt pulse's start in ms since the ride start.
    int joltThenLateFixes(
      double fromKmh,
      List<double> lagsS, {
      double decelerationG = 0.6,
    }) {
      sim.speedKmh = fromKmh;
      sim.quiet(const Duration(milliseconds: 3500));
      final joltAt = sim.t;
      sim.jolt();
      for (var i = 0; i < lagsS.length; i++) {
        final arrival = rideStart.add(Duration(seconds: 4 + i));
        final measured = arrival.subtract(
          Duration(milliseconds: (lagsS[i] * 1000).round()),
        );
        sim.speedKmh = speedAfter(
          fromKmh,
          measured.difference(joltAt),
          decelerationG: decelerationG,
        );
        // Run to half a second past the arrival, so this fix is sent.
        sim.quiet(
          arrival.add(const Duration(milliseconds: 500)).difference(sim.t),
        );
      }
      return joltAt.difference(rideStart).inMilliseconds;
    }

    test('a 0.6 g stop from 50 km/h seen 1 to 2 s late is an incident', () {
      // Measured at 2.0, 3.5, 5.0 and 5.5 s: 50, 50, 18 and 7.6 km/h. The
      // last arrives 3.5 s after the jolt, inside the 4.0 s deadline. The
      // filtered speed would still read 17 km/h then and 7 km/h only at
      // 8 s, past the deadline.
      final joltMs = joltThenLateFixes(50, [2.0, 1.5, 1.0, 1.5]);

      expect(provider.incidentCount, 1);
      expect(
        provider.activeRideIncidentsForTesting.single['elapsedMs'] as int,
        closeTo(joltMs + 40, 60),
      );
    });

    test('a 0.6 g stop from 80 km/h seen 1 to 2 s late is an incident', () {
      // Measured at 3.0, 3.5, 4.0, 5.5 and 7.0 s: 80, 80, 69, 38 and
      // 5.8 km/h. The last arrives 4.5 s after the jolt, inside the 5.4 s
      // deadline; the filtered speed would read 24 km/h.
      joltThenLateFixes(80, [1.0, 1.5, 2.0, 1.5, 1.0]);

      expect(provider.incidentCount, 1);
    });

    test('a 0.25 g stop starting at the pothole is no incident', () {
      // Braking from 50 km/h at the jolt itself, seen without any lag: the
      // speed reads 10 km/h at 4.5 s after the jolt and 1.4 km/h at 5.5 s,
      // both past the 4.0 s deadline.
      joltThenLateFixes(50, [0, 0, 0, 0, 0, 0], decelerationG: 0.25);
      sim.speedKmh = 0;
      sim.quiet(const Duration(seconds: 6));

      expect(provider.incidentCount, 0);
    });

    test('a fix without speed is not read as a stop', () {
      sim.speedKmh = 50;
      sim.quiet(const Duration(seconds: 3));
      sim.jolt();
      // Android maps a fix without speed to speed 0 and speed accuracy 0.
      provider.updateLocationForTesting(
        Position(
          latitude: 37.7749,
          longitude: -122.4194,
          timestamp: sim.t,
          accuracy: 3.0,
          altitude: 0.0,
          altitudeAccuracy: 0.0,
          heading: 90.0,
          headingAccuracy: 0.0,
          speed: 0.0,
          speedAccuracy: 0.0,
        ),
      );
      sim.quiet(const Duration(seconds: 12));

      expect(provider.incidentCount, 0);
    });

    test('a pre-jolt fix older than 3 s turns the stop rule off', () {
      sim.speedKmh = 50;
      // Fixes at 0, 1 and 2 s, then none: the jolt comes 3.5 s after the
      // last one.
      sim.quiet(const Duration(milliseconds: 2500));
      sim.speedKmh = null;
      sim.quiet(const Duration(seconds: 3));
      sim.jolt();
      // An instant stop right after would confirm with a fresh fix.
      sim.speedKmh = 0;
      sim.quiet(const Duration(seconds: 5));

      expect(provider.incidentCount, 0);
    });

    test(
      'a jolt pending at stop confirms neither after it nor later',
      () async {
        final tempRoot = await Directory.systemTemp.createTemp(
          'motocam_crash_',
        );
        addTearDown(() => tempRoot.delete(recursive: true));
        final sep = Platform.pathSeparator;
        final recordings = Directory(
          '${tempRoot.path}${sep}storage${sep}MotoCam${sep}Recordings',
        );
        await recordings.create(recursive: true);
        final segment = File('${recordings.path}${sep}segment_1.mp4');
        await segment.writeAsString('video', flush: true);

        sim.speedKmh = 50;
        sim.quiet(const Duration(seconds: 3));
        sim.jolt();
        expect(provider.incidentCount, 0, reason: 'still pending');
        await provider.stopRideSessionAndPersist(
          segment.path,
          segmentPaths: [segment.path],
        );

        // The bike stops at once: this would confirm the pending jolt.
        sim.speedKmh = 0;
        sim.quiet(const Duration(seconds: 5));
        expect(provider.incidentCount, 0);
        expect(provider.lastIncidentDetectedAt, isNull);

        // Nothing carries into the next ride either.
        provider.startRideSession(startedAt: sim.t);
        sim.quiet(const Duration(seconds: 12));
        expect(provider.incidentCount, 0);
        expect(provider.lastIncidentDetectedAt, isNull);
        expect(provider.activeRideIncidentsForTesting, isEmpty);
      },
    );

    test('a jolt and a tip-over without GPS is one incident', () {
      sim.speedKmh = null;
      sim.quiet(const Duration(seconds: 2));
      final joltStartMs = sim.elapsedMsSince(rideStart);
      sim.jolt();
      // The phone ends up on its side: gravity moves from y to x.
      sim.gravity = const [9.81, 0.0, 0.0];
      sim.quiet(const Duration(seconds: 1));
      expect(provider.incidentCount, 0, reason: 'must hold for 2 s');
      sim.quiet(const Duration(seconds: 3));

      expect(provider.incidentCount, 1);
      final incident = provider.activeRideIncidentsForTesting.single;
      expect(incident['elapsedMs'] as int, closeTo(joltStartMs + 40, 60));
    });

    test('a tip-over that does not hold for 2 s is no incident', () {
      sim.speedKmh = null;
      sim.quiet(const Duration(seconds: 2));
      sim.jolt();
      sim.gravity = const [9.81, 0.0, 0.0];
      sim.quiet(const Duration(milliseconds: 1500));
      sim.gravity = const [0.0, 9.81, 0.0];
      sim.quiet(const Duration(seconds: 10));

      expect(provider.incidentCount, 0);
    });

    test('a jolt at a standstill without a tip-over is no incident', () {
      sim.speedKmh = 0;
      sim.quiet(const Duration(seconds: 3));
      sim.jolt(g: 8.0);
      sim.quiet(const Duration(seconds: 12));

      expect(provider.incidentCount, 0);
    });

    test('leaning into a turn is no tip-over', () {
      sim.speedKmh = 50;
      sim.quiet(const Duration(seconds: 2));
      // A 45 degree lean: in a coordinated turn the measured gravity stays
      // along the phone's own axis and only grows (1 / cos 45). Allow 20
      // degrees of imperfect coordination on top.
      const magnitude = 9.81 / 0.7071;
      final off = 20 * math.pi / 180;
      sim.gravity = [magnitude * math.sin(off), magnitude * math.cos(off), 0.0];
      sim.quiet(const Duration(seconds: 1));
      // A bump mid-turn.
      sim.jolt();
      sim.quiet(const Duration(seconds: 12));

      expect(provider.incidentCount, 0);
    });

    test('two jolts inside one window make one incident', () {
      sim.speedKmh = 50;
      sim.quiet(const Duration(seconds: 3));
      final firstJoltMs = sim.elapsedMsSince(rideStart);
      sim.jolt();
      // Still sliding at the next fix.
      sim.speedKmh = 30;
      sim.quiet(const Duration(seconds: 1));
      // The bike hits the ground: a harder second jolt raises the peak.
      sim.jolt(g: 9.0);
      sim.speedKmh = 0;
      sim.quiet(const Duration(seconds: 5));

      expect(provider.incidentCount, 1);
      final incident = provider.activeRideIncidentsForTesting.single;
      expect(incident['elapsedMs'] as int, closeTo(firstJoltMs + 40, 60));
      expect(incident['gForce'] as double, closeTo(9.0, 0.01));
    });

    test('the gravity-filtered fallback feeds both the jolt and tip-over', () {
      // A phone without a linear-acceleration sensor: only the raw stream.
      var t = rideStart;
      void raw(double x, double y, double z, Duration duration) {
        final end = t.add(duration);
        while (t.isBefore(end)) {
          provider.updateRawAccelerometerForTesting(x, y, z, timestamp: t);
          t = t.add(const Duration(milliseconds: 20));
        }
      }

      raw(0.0, 0.0, 9.81, const Duration(seconds: 1));
      // A 5 g impact along x for 160 ms, then the phone on its side.
      raw(5 * 9.81, 0.0, 9.81, const Duration(milliseconds: 160));
      expect(provider.incidentCount, 0);
      raw(9.81, 0.0, 0.0, const Duration(seconds: 4));

      expect(provider.incidentCount, 1);
    });

    test('a jolt inside the debounce after an incident is ignored', () {
      sim.speedKmh = null;
      sim.quiet(const Duration(seconds: 2));
      sim.jolt();
      sim.gravity = const [9.81, 0.0, 0.0];
      sim.quiet(const Duration(seconds: 3));
      expect(provider.incidentCount, 1);

      // Picked up and dropped again about 1.5 s after the confirmation,
      // inside the 6 s debounce.
      sim.gravity = const [0.0, 9.81, 0.0];
      sim.quiet(const Duration(seconds: 1));
      sim.jolt();
      sim.gravity = const [0.0, 0.0, 9.81];
      sim.quiet(const Duration(seconds: 4));
      expect(provider.incidentCount, 1);
    });
  });

  group('CrashDetector.abruptStopDeadline', () {
    test('allows a 0.6 g stop plus 2 s of GPS lag', () {
      // From 50 km/h: 42 km/h to lose at 5.886 m/s^2 is about 1.98 s.
      expect(
        CrashDetector.abruptStopDeadline(50).inMilliseconds,
        closeTo(3982, 5),
      );
      expect(CrashDetector.abruptStopDeadline(5), CrashDetector.stopGpsLag);
    });
  });
}
