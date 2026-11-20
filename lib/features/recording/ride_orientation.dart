// lib/features/recording/ride_orientation.dart
//
// Landscape recording engine: the build switch, the orientation classifier
// (gravity to portraitUp, landscapeLeft or landscapeRight) and the pinner
// that holds the UI in the classified orientation while the recording
// screen is idle and freezes it for a ride.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../../core/diagnostics/diagnostic_log.dart';

/// Build switch for landscape recording, off by default. Turn it on with
/// `--dart-define=MOTOCAM_LANDSCAPE=true` (bench builds only, until the UI
/// redesign ships its landscape layouts).
///
/// Off: the UI and the capture stay portraitUp, exactly as before the
/// engine existed. On: while the recording screen is idle the UI is pinned
/// to the orientation the phone is held in, and START takes that
/// orientation for the whole ride (see [RideOrientationPinner]).
const bool kLandscapeRecording = bool.fromEnvironment('MOTOCAM_LANDSCAPE');

/// The orientations a ride can be recorded in. portraitDown is not
/// supported.
const List<DeviceOrientation> rideOrientations = [
  DeviceOrientation.portraitUp,
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
];

/// Whether [orientation] is one of the two landscape orientations.
bool isLandscapeOrientation(DeviceOrientation orientation) =>
    orientation == DeviceOrientation.landscapeLeft ||
    orientation == DeviceOrientation.landscapeRight;

/// Classifies raw accelerometer samples (gravity included, Android device
/// frame, m/s²) into portraitUp, landscapeLeft or landscapeRight, with
/// hysteresis.
///
/// Sign convention. Android's sensor axes are fixed to the phone in its
/// natural (portrait) orientation: +x to the right edge, +y to the top edge,
/// +z out of the screen, and a phone at rest reads about +9.81 on the axis
/// that points up. Flutter's [DeviceOrientation.landscapeLeft] is "90
/// degrees counterclockwise from portraitUp", which the Flutter embedding
/// requests as `SCREEN_ORIENTATION_LANDSCAPE` (display rotation
/// `ROTATION_90`, also what the camera plugin maps landscapeLeft to). Turned
/// 90 degrees counterclockwise, the phone's right edge points up, so:
///
/// * portraitUp: gravity reads about (0, +9.81, 0);
/// * landscapeLeft: about (+9.81, 0, 0);
/// * landscapeRight: about (-9.81, 0, 0).
///
/// The classifier works on the in-plane angle `atan2(x, y)`: 0 degrees is
/// portraitUp, +90 landscapeLeft, -90 landscapeRight and ±180 portraitDown.
/// Each orientation owns the 90 degree sector around its angle (the
/// boundaries are at ±45 and ±135 degrees).
///
/// Hysteresis. The samples are first smoothed with a low-pass
/// ([smoothing]). A new orientation is taken only when the smoothed angle
/// is inside its sector and at least [boundaryMarginDegrees] past the edge
/// of the current orientation's sector (so at least 75 degrees from the
/// current orientation's axis), without a break for [hold]. A phone lying
/// nearly flat (in-plane gravity under [minInPlaneMs2]) or upside down
/// (the portraitDown sector) keeps the current orientation.
class OrientationClassifier {
  /// Creates a classifier that starts in [initial].
  OrientationClassifier({
    DeviceOrientation initial = DeviceOrientation.portraitUp,
  }) : _current = _supportedOrPortrait(initial);

  /// Half the width of each orientation's sector, in degrees.
  static const double sectorHalfWidthDegrees = 45.0;

  /// How far past the current orientation's sector boundary the tilt must
  /// be before a change can start, in degrees.
  static const double boundaryMarginDegrees = 30.0;

  /// How long the tilt must stay past the boundary before the change is
  /// taken.
  static const Duration hold = Duration(seconds: 1);

  /// Time constant of the gravity low-pass, which keeps handlebar vibration
  /// from breaking the hold.
  static const Duration smoothing = Duration(milliseconds: 300);

  /// Below this in-plane gravity (m/s², about 0.3 g: the phone tilted more
  /// than about 72 degrees from upright towards flat) the angle is not
  /// trusted and the current orientation is kept.
  static const double minInPlaneMs2 = 3.0;

  DeviceOrientation _current;
  DeviceOrientation? _candidate;
  DateTime? _candidateSince;
  double? _smoothX;
  double? _smoothY;
  DateTime? _lastAt;

  /// The classified orientation.
  DeviceOrientation get current => _current;

  /// Sets the classified orientation without a hold (for example when the
  /// UI is pinned to portrait for another screen) and forgets any pending
  /// change and the smoothed gravity.
  void reset(DeviceOrientation orientation) {
    _current = _supportedOrPortrait(orientation);
    restart();
  }

  /// Forgets any pending change and the smoothed gravity, keeping
  /// [current]. Call it when samples resume after a pause, so a hold never
  /// spans the gap.
  void restart() {
    _candidate = null;
    _candidateSince = null;
    _smoothX = null;
    _smoothY = null;
    _lastAt = null;
  }

  /// Adds one raw accelerometer sample taken at [at]. Returns the new
  /// orientation when this sample completes a change, otherwise `null`.
  DeviceOrientation? addSample(double x, double y, double z, DateTime at) {
    if (!x.isFinite || !y.isFinite || !z.isFinite) {
      return null;
    }
    final lastAt = _lastAt;
    if (lastAt != null && at.isBefore(lastAt)) {
      // Out of order: ignore rather than smooth backwards.
      return null;
    }
    final previousX = _smoothX;
    final previousY = _smoothY;
    if (previousX == null || previousY == null || lastAt == null) {
      _smoothX = x;
      _smoothY = y;
    } else {
      final dtMs = at.difference(lastAt).inMicroseconds / 1000.0;
      final alpha = dtMs <= 0
          ? 0.0
          : 1 - math.exp(-dtMs / smoothing.inMilliseconds);
      _smoothX = previousX + alpha * (x - previousX);
      _smoothY = previousY + alpha * (y - previousY);
    }
    _lastAt = at;

    final candidate = _candidateFor(_smoothX!, _smoothY!);
    if (candidate == null) {
      _candidate = null;
      _candidateSince = null;
      return null;
    }
    if (candidate != _candidate) {
      _candidate = candidate;
      _candidateSince = at;
    }
    if (at.difference(_candidateSince!) < hold) {
      return null;
    }
    _current = candidate;
    _candidate = null;
    _candidateSince = null;
    return candidate;
  }

  /// The orientation the smoothed gravity ([x], [y]) qualifies for as a
  /// change from [current], or `null` when it stays.
  DeviceOrientation? _candidateFor(double x, double y) {
    if (math.sqrt(x * x + y * y) < minInPlaneMs2) {
      return null;
    }
    final angle = math.atan2(x, y) * 180 / math.pi;
    for (final orientation in rideOrientations) {
      if (orientation == _current) {
        continue;
      }
      final inSector =
          _angleBetween(angle, _axisDegrees(orientation)) <=
          sectorHalfWidthDegrees;
      final pastCurrent =
          _angleBetween(angle, _axisDegrees(_current)) >=
          sectorHalfWidthDegrees + boundaryMarginDegrees;
      if (inSector && pastCurrent) {
        return orientation;
      }
    }
    return null;
  }

  static double _axisDegrees(DeviceOrientation orientation) {
    switch (orientation) {
      case DeviceOrientation.portraitUp:
        return 0;
      case DeviceOrientation.landscapeLeft:
        return 90;
      case DeviceOrientation.landscapeRight:
        return -90;
      case DeviceOrientation.portraitDown:
        return 180;
    }
  }

  /// The unsigned angle between two directions, 0 to 180 degrees.
  static double _angleBetween(double a, double b) {
    final difference = (a - b).abs() % 360;
    return difference > 180 ? 360 - difference : difference;
  }

  static DeviceOrientation _supportedOrPortrait(DeviceOrientation o) =>
      rideOrientations.contains(o) ? o : DeviceOrientation.portraitUp;
}

/// One raw accelerometer reading (gravity included, m/s², Android device
/// frame) and its sensor time.
typedef GravitySample = ({double x, double y, double z, DateTime at});

/// Pins the UI to the orientation an [OrientationClassifier] reads from
/// gravity while no ride runs, and freezes it for a ride.
///
/// The owner calls [setWatching] with `true` only while the app is idle
/// and in the foreground (no ride starting, running or stopping, not in
/// PiP; the parked screens over the recording screen follow the pin too)
/// and with `false` otherwise; while not watching, [pinned] never changes, so the
/// orientation pinned when START was tapped is the ride's until STOP.
/// When [enabled] is false (the build switch is off) it never subscribes
/// and never pins.
class RideOrientationPinner {
  /// Creates a pinner. [gravity] opens the raw accelerometer stream (called
  /// once per watch period); [onPin] applies a new orientation (UI pin and
  /// idle capture lock).
  RideOrientationPinner({
    required this.enabled,
    required Stream<GravitySample> Function() gravity,
    required Future<void> Function(DeviceOrientation orientation) onPin,
    OrientationClassifier? classifier,
  }) : _gravity = gravity,
       _onPin = onPin,
       _classifier = classifier ?? OrientationClassifier();

  /// Whether landscape recording is on in this build.
  final bool enabled;

  final Stream<GravitySample> Function() _gravity;
  final Future<void> Function(DeviceOrientation orientation) _onPin;
  final OrientationClassifier _classifier;
  StreamSubscription<GravitySample>? _subscription;
  bool _disposed = false;

  /// The orientation the UI is pinned to (portraitUp until a change).
  DeviceOrientation get pinned => _classifier.current;

  /// Whether gravity is being classified now.
  bool get isWatching => _subscription != null;

  /// Starts or stops classifying gravity. Starting forgets any pending
  /// change from an earlier watch period.
  void setWatching(bool watch) {
    if (!enabled || _disposed) {
      return;
    }
    if (watch && _subscription == null) {
      _classifier.restart();
      _subscription = _gravity().listen(
        _onSample,
        onError: (Object error) {
          debugPrintError(
            'recording',
            'Orientation pin: gravity stream error: $error',
            level: DiagnosticLogLevel.warning,
          );
        },
      );
    } else if (!watch && _subscription != null) {
      unawaited(_subscription!.cancel());
      _subscription = null;
    }
  }

  /// Pins [orientation] at once, without the classifier's hold (for
  /// example portraitUp for a screen that cannot take landscape). Ignored
  /// when [enabled] is false.
  Future<void> pinNow(DeviceOrientation orientation) async {
    if (!enabled || _disposed) {
      return;
    }
    final previous = _classifier.current;
    _classifier.reset(orientation);
    if (_classifier.current != previous) {
      await _onPin(_classifier.current);
    }
  }

  void _onSample(GravitySample sample) {
    if (_disposed) {
      return;
    }
    final changed = _classifier.addSample(
      sample.x,
      sample.y,
      sample.z,
      sample.at,
    );
    if (changed != null) {
      unawaited(_onPin(changed));
    }
  }

  /// Stops classifying for good.
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
  }
}
