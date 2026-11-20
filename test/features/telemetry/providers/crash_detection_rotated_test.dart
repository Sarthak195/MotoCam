// Crash detection with the phone mounted sideways (landscape recording):
// every event is replayed in the portrait, landscapeLeft and landscapeRight
// device frames (all vectors turned about the screen normal) and must give
// the same jolt and tip-over decisions as in portrait.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/features/telemetry/providers/telemetry_provider.dart';

import '../../../support/ride_sim.dart';

const Map<String, double> _mounts = {
  'portrait': 0,
  'landscapeLeft': 90,
  'landscapeRight': -90,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final mount in _mounts.entries) {
    group('Crash detection on a ${mount.key} mount', () {
      late TelemetryProvider provider;
      late DateTime rideStart;
      late RideSim sim;

      setUp(() {
        rideStart = DateTime.now();
        provider = TelemetryProvider(
          sampleInterval: const Duration(seconds: 1),
          clock: () => sim.t,
          // No plugin in tests: gravitySamples only carries RideSim's.
          idleGravitySource: (_) => const Stream.empty(),
        );
        sim = RideSim(provider, start: rideStart)..mountDegrees = mount.value;
        provider.startRideSession(startedAt: rideStart);
        provider.setIncidentDetectionConfig(
          triggerGForce: 3.5,
          debounce: const Duration(seconds: 6),
        );
      });

      tearDown(() {
        provider.dispose();
      });

      test('the sim turns gravity into this mount\'s device frame', () {
        // A spot check of the frame: the provider sees what RideSim feeds.
        final seen = <List<double>>[];
        final subscription = provider.gravitySamples.listen(
          (s) => seen.add([s.x, s.y, s.z]),
        );
        sim.quiet(const Duration(milliseconds: 100));
        return Future<void>.delayed(Duration.zero).then((_) {
          final g = seen.first;
          final expected = switch (mount.value) {
            90.0 => [9.81, 0.0],
            -90.0 => [-9.81, 0.0],
            _ => [0.0, 9.81],
          };
          expect(g[0], closeTo(expected[0], 1e-9));
          expect(g[1], closeTo(expected[1], 1e-9));
          return subscription.cancel();
        });
      });

      test('handlebar vibration at speed starts no candidate', () {
        sim.speedKmh = 50;
        sim.quiet(const Duration(seconds: 3));
        sim.vibrate(const Duration(seconds: 3));
        sim.speedKmh = 0;
        sim.quiet(const Duration(seconds: 5));

        expect(provider.incidentCount, 0);
        expect(provider.activeRideIncidentsForTesting, isEmpty);
      });

      test('a jolt then an abrupt near-stop is one incident at the jolt', () {
        sim.speedKmh = 50;
        sim.quiet(const Duration(seconds: 3));
        final joltStartMs = sim.elapsedMsSince(rideStart);
        sim.jolt();
        sim.speedKmh = 0;
        sim.quiet(const Duration(seconds: 5));

        expect(provider.incidentCount, 1);
        final incident = provider.activeRideIncidentsForTesting.single;
        expect(incident['elapsedMs'] as int, closeTo(joltStartMs + 40, 60));
        expect(incident['gForce'] as double, closeTo(6.0, 0.01));
      });

      test('a pothole followed by a gradual stop is no incident', () {
        sim.speedKmh = 40;
        sim.quiet(const Duration(seconds: 3));
        sim.jolt();
        sim.quiet(const Duration(seconds: 1));
        for (final speed in [31.0, 22.0, 13.0, 4.0, 0.0]) {
          sim.speedKmh = speed;
          sim.quiet(const Duration(seconds: 1));
        }
        sim.quiet(const Duration(seconds: 6));

        expect(provider.incidentCount, 0);
      });

      test('a jolt and a tip-over without GPS is one incident', () {
        sim.speedKmh = null;
        sim.quiet(const Duration(seconds: 2));
        final joltStartMs = sim.elapsedMsSince(rideStart);
        sim.jolt();
        // The bike falls: the phone turns 90 degrees with it.
        sim.gravity = const [9.81, 0.0, 0.0];
        sim.quiet(const Duration(seconds: 1));
        expect(provider.incidentCount, 0, reason: 'must hold for 2 s');
        sim.quiet(const Duration(seconds: 3));

        expect(provider.incidentCount, 1);
        expect(
          provider.activeRideIncidentsForTesting.single['elapsedMs'] as int,
          closeTo(joltStartMs + 40, 60),
        );
      });

      test('a bike falling onto the screen side (gravity into z) is a '
          'tip-over too', () {
        sim.speedKmh = null;
        sim.quiet(const Duration(seconds: 2));
        sim.jolt();
        sim.gravity = const [0.0, 0.0, 9.81];
        sim.quiet(const Duration(seconds: 4));

        expect(provider.incidentCount, 1);
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
        const magnitude = 9.81 / 0.7071;
        final off = 20 * math.pi / 180;
        sim.gravity = [
          magnitude * math.sin(off),
          magnitude * math.cos(off),
          0.0,
        ];
        sim.quiet(const Duration(seconds: 1));
        sim.jolt();
        sim.quiet(const Duration(seconds: 12));

        expect(provider.incidentCount, 0);
      });

      test('a phone turned in its mount within 10 s of a jolt counts as a '
          'tip-over (documented limit)', () {
        sim.speedKmh = null;
        sim.quiet(const Duration(seconds: 2));
        sim.jolt();
        sim.quiet(const Duration(seconds: 1));
        // The rider turns the phone a quarter turn in the mount and leaves
        // it: the detector cannot tell this from a fall.
        sim.mountDegrees = mount.value + 90;
        sim.quiet(const Duration(seconds: 4));

        expect(provider.incidentCount, 1);
      });

      test('the gravity-filtered fallback feeds both the jolt and the '
          'tip-over', () {
        final radians = mount.value * math.pi / 180;
        List<double> toDevice(double x, double y, double z) => [
          x * math.cos(radians) + y * math.sin(radians),
          -x * math.sin(radians) + y * math.cos(radians),
          z,
        ];
        var t = rideStart;
        void raw(List<double> portraitFrame, Duration duration) {
          final v = toDevice(
            portraitFrame[0],
            portraitFrame[1],
            portraitFrame[2],
          );
          final end = t.add(duration);
          while (t.isBefore(end)) {
            provider.updateRawAccelerometerForTesting(
              v[0],
              v[1],
              v[2],
              timestamp: t,
            );
            t = t.add(const Duration(milliseconds: 20));
          }
        }

        // Upright on the mount, a 5 g impact for 160 ms, then the phone on
        // its side.
        raw([0.0, 9.81, 0.0], const Duration(seconds: 1));
        raw([5 * 9.81, 9.81, 0.0], const Duration(milliseconds: 160));
        expect(provider.incidentCount, 0);
        raw([9.81, 0.0, 0.0], const Duration(seconds: 4));

        expect(provider.incidentCount, 1);
      });
    });
  }
}
