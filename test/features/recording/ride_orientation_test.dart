import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/features/recording/ride_orientation.dart';

const double _g = 9.81;

/// Gravity as the phone reads it when turned [degrees] counterclockwise
/// (seen from the screen) from upright portrait: atan2(x, y) == degrees.
List<double> _tilted(double degrees, {double magnitude = _g}) {
  final radians = degrees * math.pi / 180;
  return [magnitude * math.sin(radians), magnitude * math.cos(radians), 0.0];
}

class _Feed {
  _Feed(this.classifier, {DateTime? start})
    : t = start ?? DateTime(2026, 11, 19, 8);

  final OrientationClassifier classifier;
  DateTime t;
  final List<DeviceOrientation> changes = [];

  static const Duration step = Duration(milliseconds: 66);

  /// Feeds [vector] every 66 ms (the 15 Hz raw accelerometer) for
  /// [duration].
  void hold(List<double> vector, Duration duration) {
    final end = t.add(duration);
    while (t.isBefore(end)) {
      final changed = classifier.addSample(vector[0], vector[1], vector[2], t);
      if (changed != null) {
        changes.add(changed);
      }
      t = t.add(step);
    }
  }
}

void main() {
  group('OrientationClassifier sign convention', () {
    // Android sensor frame: +x right edge, +y top edge, the axis pointing
    // up reads +g. Flutter landscapeLeft is 90 degrees counterclockwise from
    // portraitUp (SCREEN_ORIENTATION_LANDSCAPE, ROTATION_90): the right edge
    // points up, so gravity reads +x. landscapeRight reads -x. The phone
    // bench confirms the last link (the vivo's own axes).
    test('upright portrait (0, +g, 0) stays portraitUp', () {
      final feed = _Feed(OrientationClassifier())
        ..hold([0, _g, 0], const Duration(seconds: 3));
      expect(feed.changes, isEmpty);
      expect(feed.classifier.current, DeviceOrientation.portraitUp);
    });

    test('right edge up (+g, 0, 0) is landscapeLeft', () {
      final feed = _Feed(OrientationClassifier())
        ..hold([_g, 0, 0], const Duration(seconds: 2));
      expect(feed.changes, [DeviceOrientation.landscapeLeft]);
      expect(feed.classifier.current, DeviceOrientation.landscapeLeft);
    });

    test('left edge up (-g, 0, 0) is landscapeRight', () {
      final feed = _Feed(OrientationClassifier())
        ..hold([-_g, 0, 0], const Duration(seconds: 2));
      expect(feed.changes, [DeviceOrientation.landscapeRight]);
    });

    test('the in-plane angle matches the helper used by the tests', () {
      final v = _tilted(90);
      expect(v[0], closeTo(_g, 1e-9));
      expect(v[1], closeTo(0, 1e-9));
    });
  });

  group('OrientationClassifier hysteresis', () {
    test('a change needs the tilt held for 1 s', () {
      final feed = _Feed(OrientationClassifier())
        ..hold(_tilted(90), const Duration(milliseconds: 900));
      expect(feed.changes, isEmpty);
      feed.hold(_tilted(90), const Duration(milliseconds: 900));
      expect(feed.changes, [DeviceOrientation.landscapeLeft]);
    });

    test('a tilt less than 30 degrees past the 45 degree boundary never '
        'changes', () {
      final feed = _Feed(OrientationClassifier())
        ..hold(_tilted(70), const Duration(seconds: 10))
        ..hold(_tilted(-70), const Duration(seconds: 10));
      expect(feed.changes, isEmpty);
    });

    test('a tilt 30 degrees past the boundary (76 degrees) changes', () {
      final feed = _Feed(OrientationClassifier())
        ..hold(_tilted(76), const Duration(seconds: 2));
      expect(feed.changes, [DeviceOrientation.landscapeLeft]);
    });

    test('back to portrait needs 15 degrees or less from upright', () {
      final classifier = OrientationClassifier(
        initial: DeviceOrientation.landscapeLeft,
      );
      final feed = _Feed(classifier)
        ..hold(_tilted(20), const Duration(seconds: 5));
      expect(feed.changes, isEmpty, reason: '20 degrees is inside the margin');
      feed.hold(_tilted(10), const Duration(seconds: 2));
      expect(feed.changes, [DeviceOrientation.portraitUp]);
    });

    test('one landscape side to the other changes directly', () {
      final feed = _Feed(
        OrientationClassifier(initial: DeviceOrientation.landscapeLeft),
      )..hold([-_g, 0, 0], const Duration(seconds: 2));
      expect(feed.changes, [DeviceOrientation.landscapeRight]);
    });

    test('a break in the tilt restarts the hold', () {
      final feed = _Feed(OrientationClassifier())
        ..hold(_tilted(90), const Duration(milliseconds: 800))
        ..hold(_tilted(0), const Duration(milliseconds: 600))
        ..hold(_tilted(90), const Duration(milliseconds: 800));
      expect(feed.changes, isEmpty);
      feed.hold(_tilted(90), const Duration(seconds: 1));
      expect(feed.changes, [DeviceOrientation.landscapeLeft]);
    });

    test('a phone lying flat keeps the current orientation', () {
      final feed = _Feed(
        OrientationClassifier(initial: DeviceOrientation.landscapeRight),
      )..hold([0.5, 0.5, _g], const Duration(seconds: 5));
      expect(feed.changes, isEmpty);
      expect(feed.classifier.current, DeviceOrientation.landscapeRight);
    });

    test('a phone tilted back 60 degrees on the mount still classifies', () {
      // In-plane gravity is g * cos(60) = 4.9 m/s².
      final feed = _Feed(OrientationClassifier())
        ..hold([_g * 0.5, 0, _g * 0.866], const Duration(seconds: 2));
      expect(feed.changes, [DeviceOrientation.landscapeLeft]);
    });

    test('upside down (portraitDown) keeps the current orientation', () {
      final feed = _Feed(OrientationClassifier())
        ..hold(_tilted(180), const Duration(seconds: 5))
        ..hold(_tilted(160), const Duration(seconds: 5));
      expect(feed.changes, isEmpty);
      expect(feed.classifier.current, DeviceOrientation.portraitUp);
    });

    test('handlebar vibration on a landscape mount does not break the '
        'hold', () {
      // 3 g of shake along x and y, flipping sign every sample.
      final classifier = OrientationClassifier();
      var t = DateTime(2026, 11, 19, 8);
      var sign = 1.0;
      final changes = <DeviceOrientation>[];
      for (var i = 0; i < 45; i++) {
        final changed = classifier.addSample(
          _g + sign * 3 * _g * 0.6,
          sign * 3 * _g * 0.8,
          0,
          t,
        );
        if (changed != null) {
          changes.add(changed);
        }
        sign = -sign;
        t = t.add(const Duration(milliseconds: 66));
      }
      expect(changes, [DeviceOrientation.landscapeLeft]);
    });

    test('non-finite and out-of-order samples are ignored', () {
      final classifier = OrientationClassifier();
      final start = DateTime(2026, 11, 19, 8);
      expect(classifier.addSample(double.nan, 0, 0, start), isNull);
      final feed = _Feed(classifier, start: start)
        ..hold([_g, 0, 0], const Duration(milliseconds: 500));
      expect(classifier.addSample(-_g, 0, 0, start), isNull);
      feed.hold([_g, 0, 0], const Duration(milliseconds: 700));
      expect(feed.changes, [DeviceOrientation.landscapeLeft]);
    });

    test('restart forgets a pending change', () {
      final classifier = OrientationClassifier();
      final feed = _Feed(classifier)
        ..hold([_g, 0, 0], const Duration(milliseconds: 900));
      classifier.restart();
      feed.hold([_g, 0, 0], const Duration(milliseconds: 900));
      expect(feed.changes, isEmpty);
    });

    test('reset sets the orientation without a hold; portraitDown maps to '
        'portraitUp', () {
      final classifier = OrientationClassifier()
        ..reset(DeviceOrientation.landscapeRight);
      expect(classifier.current, DeviceOrientation.landscapeRight);
      classifier.reset(DeviceOrientation.portraitDown);
      expect(classifier.current, DeviceOrientation.portraitUp);
      expect(
        OrientationClassifier(initial: DeviceOrientation.portraitDown).current,
        DeviceOrientation.portraitUp,
      );
    });
  });

  group('RideOrientationPinner', () {
    late StreamController<GravitySample> gravity;
    late List<DeviceOrientation> pins;
    late int listens;

    RideOrientationPinner pinner({bool enabled = true}) {
      return RideOrientationPinner(
        enabled: enabled,
        gravity: () {
          listens++;
          return gravity.stream;
        },
        onPin: (orientation) async => pins.add(orientation),
      );
    }

    Future<void> send(List<double> v, DateTime from, Duration length) async {
      var t = from;
      final end = from.add(length);
      while (t.isBefore(end)) {
        gravity.add((x: v[0], y: v[1], z: v[2], at: t));
        t = t.add(const Duration(milliseconds: 66));
      }
      await Future<void>.delayed(Duration.zero);
    }

    setUp(() {
      gravity = StreamController<GravitySample>.broadcast();
      pins = [];
      listens = 0;
    });

    tearDown(() => gravity.close());

    test('switched off it never subscribes or pins', () async {
      final p = pinner(enabled: false)..setWatching(true);
      await p.pinNow(DeviceOrientation.landscapeLeft);
      expect(listens, 0);
      expect(p.isWatching, isFalse);
      expect(pins, isEmpty);
      expect(p.pinned, DeviceOrientation.portraitUp);
    });

    test('pins the classified orientation while watching', () async {
      final p = pinner()..setWatching(true);
      await send([_g, 0, 0], DateTime(2026), const Duration(seconds: 2));
      expect(pins, [DeviceOrientation.landscapeLeft]);
      expect(p.pinned, DeviceOrientation.landscapeLeft);
      p.dispose();
    });

    test('frozen (not watching) for a ride: turning the phone changes '
        'nothing until watching resumes', () async {
      final p = pinner()..setWatching(true);
      final start = DateTime(2026);
      await send([_g, 0, 0], start, const Duration(seconds: 2));
      // START: the ride is landscapeLeft.
      p.setWatching(false);
      expect(p.isWatching, isFalse);
      await send(
        [0, _g, 0],
        start.add(const Duration(seconds: 2)),
        const Duration(seconds: 5),
      );
      expect(p.pinned, DeviceOrientation.landscapeLeft);
      expect(pins, [DeviceOrientation.landscapeLeft]);
      // STOP: classification resumes.
      p.setWatching(true);
      await send(
        [0, _g, 0],
        start.add(const Duration(seconds: 8)),
        const Duration(seconds: 2),
      );
      expect(pins, [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.portraitUp,
      ]);
      expect(listens, 2);
      p.dispose();
    });

    test('pinNow pins at once and only reports a real change', () async {
      final p = pinner();
      await p.pinNow(DeviceOrientation.portraitUp);
      expect(pins, isEmpty);
      await p.pinNow(DeviceOrientation.landscapeRight);
      expect(pins, [DeviceOrientation.landscapeRight]);
      expect(p.pinned, DeviceOrientation.landscapeRight);
    });

    test('isLandscapeOrientation', () {
      expect(isLandscapeOrientation(DeviceOrientation.landscapeLeft), isTrue);
      expect(isLandscapeOrientation(DeviceOrientation.landscapeRight), isTrue);
      expect(isLandscapeOrientation(DeviceOrientation.portraitUp), isFalse);
      expect(isLandscapeOrientation(DeviceOrientation.portraitDown), isFalse);
    });
  });
}
