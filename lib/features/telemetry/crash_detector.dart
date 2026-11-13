// lib/features/telemetry/crash_detector.dart
//
// Automatic crash detection as "jolt + confirm": a filtered jolt only starts
// a candidate, and the candidate becomes an incident only when, within
// [CrashDetector.confirmWindow], the bike stops abruptly or the phone stays
// tipped over. Pure Dart with every time passed in, so it can be tested with
// synthetic sensor and speed streams.

import 'dart:collection';
import 'dart:math' as math;

/// How a jolt candidate was confirmed.
enum CrashConfirmation {
  /// The bike was clearly moving before the jolt and nearly stopped soon
  /// after it, faster than any normal stop.
  abruptStop,

  /// The direction of gravity stayed far from the pre-jolt orientation.
  tipOver,
}

/// A confirmed incident: the jolt's time and peak, and how it was confirmed.
class ConfirmedCrash {
  /// Creates a confirmed incident.
  const ConfirmedCrash({
    required this.joltAt,
    required this.peakG,
    required this.confirmedAt,
    required this.confirmation,
  });

  /// Time of the jolt (sensor time base): the first sample whose filtered
  /// acceleration reached the trigger.
  final DateTime joltAt;

  /// Peak raw linear-acceleration magnitude (g) of the jolt, raised by any
  /// later jolt while the candidate was pending.
  final double peakG;

  /// Time (sensor time base) of the input that confirmed the candidate.
  final DateTime confirmedAt;

  /// Which rule confirmed it.
  final CrashConfirmation confirmation;
}

/// What the detector knew when it started a candidate.
class CandidateStartInfo {
  /// Creates the record.
  const CandidateStartInfo({
    required this.joltAt,
    required this.peakG,
    required this.preJoltSpeedKmh,
    required this.preJoltSpeedAge,
    required this.stopRuleArmed,
    required this.orientationAvailable,
    required this.stopDeadline,
  });

  /// Time of the jolt (sensor time base).
  final DateTime joltAt;

  /// Peak raw linear-acceleration magnitude (g) so far.
  final double peakG;

  /// The last speed (km/h) before the jolt, or `null` when there was none,
  /// whether or not it qualified for rule (a).
  final double? preJoltSpeedKmh;

  /// Age of [preJoltSpeedKmh] at the jolt.
  final Duration? preJoltSpeedAge;

  /// Whether rule (a) (abrupt stop) can confirm this candidate: the
  /// pre-jolt speed was recent and at least
  /// [CrashDetector.minMovingSpeedKmh].
  final bool stopRuleArmed;

  /// Whether rule (b) (tip-over) has a pre-jolt orientation to compare with.
  final bool orientationAvailable;

  /// Latest time after the jolt for a near-stop to count, or `null` when
  /// rule (a) is not armed.
  final Duration? stopDeadline;
}

/// What the detector saw of a candidate that ended without confirmation.
class CandidateEndInfo {
  /// Creates the record.
  const CandidateEndInfo({
    required this.joltAt,
    required this.peakG,
    required this.stopRuleArmed,
    required this.speedFixesAfterJolt,
    required this.minSpeedAfterJoltKmh,
    required this.nearStopTooLate,
    required this.orientationAvailable,
    required this.maxTiltDegrees,
    required this.longestTipHold,
  });

  /// Time of the jolt (sensor time base).
  final DateTime joltAt;

  /// Peak raw linear-acceleration magnitude (g) of the candidate.
  final double peakG;

  /// Whether rule (a) was armed at the jolt.
  final bool stopRuleArmed;

  /// Speed fixes received after the jolt while the candidate was pending.
  final int speedFixesAfterJolt;

  /// The lowest of those speeds (km/h), or `null` without any fix.
  final double? minSpeedAfterJoltKmh;

  /// Whether a speed below [CrashDetector.nearStopSpeedKmh] arrived, but
  /// after the abrupt-stop deadline.
  final bool nearStopTooLate;

  /// Whether rule (b) had a pre-jolt orientation.
  final bool orientationAvailable;

  /// Largest angle (degrees) between the pre-jolt and the current gravity
  /// direction while the candidate was pending, or `null` without one.
  final double? maxTiltDegrees;

  /// Longest time the tip-over angle was held without a break.
  final Duration longestTipHold;
}

/// Receives what the [CrashDetector] sees, for diagnostics. Calls are made
/// synchronously on the sensor path: implementations must be cheap and must
/// not throw.
abstract class CrashDetectorObserver {
  /// One linear-acceleration sample: the 100 ms averaged magnitude and the
  /// raw magnitude (both g) and the current trigger (g).
  void onSample(DateTime at, double averagedG, double rawG, double triggerG);

  /// A jolt started a candidate.
  void onCandidateStarted(CandidateStartInfo info);

  /// The pending candidate's peak rose by at least
  /// [CrashDetector.peakReportStepG] since the last report.
  void onCandidatePeakRaised(DateTime at, double peakG);

  /// The candidate was confirmed.
  void onCandidateConfirmed(ConfirmedCrash crash);

  /// The confirmation window passed (at sensor time [at]).
  void onCandidateExpired(DateTime at, CandidateEndInfo info);

  /// The candidate was discarded by [CrashDetector.reset] (for example at
  /// the end of a ride).
  void onCandidateDropped(CandidateEndInfo info);
}

/// Detects crash candidates from linear acceleration and confirms them with
/// speed and orientation.
///
/// Inputs: [addLinearAcceleration] (gravity removed, m/s², about 50 Hz),
/// [addGravitySample] (raw accelerometer with gravity, m/s², any rate) and
/// [addSpeed] (km/h, once per GPS fix). Each returns the incident it
/// confirmed, if any. All times share one time base (the accelerometer's
/// event time); the caller stamps speed updates in that base.
class CrashDetector {
  /// Jolt filter: moving average of the linear-acceleration vector over this
  /// window. Handlebar and engine vibration sit at about 10 Hz and above and
  /// are zero-mean along each axis, so a 100 ms boxcar (first null at 10 Hz)
  /// keeps only about 1/(pi * f * 0.1 s) of their amplitude, around 20
  /// percent at 15 Hz and 13 percent at 25 Hz (the Nyquist limit at 50 Hz).
  /// If the 4 to 8 g raw peaks of the 2026-11-13 handlebar ride are such
  /// vibration, they average to under 1.7 g. An impact that pushes the phone
  /// one way keeps its value: the average times the window is the change of
  /// velocity.
  static const Duration joltWindow = Duration(milliseconds: 100);

  /// The averaged magnitude must stay at or above the trigger for at least
  /// this long (event time). With [joltWindow] this needs a velocity change
  /// of roughly 3.5 to 5 m/s within about 100 ms at the medium 3.5 g
  /// trigger: a 15 g knock must last about 25 ms, an 8 g one about 50 ms and
  /// a 5 g one about 100 ms (the old rule took any 40 ms of raw samples).
  /// For scale, a handlebar dropping 1 m to the road hits it at about
  /// 4.4 m/s.
  static const Duration minJoltDuration = Duration(milliseconds: 60);

  /// Samples above the trigger needed instead of [minJoltDuration] when the
  /// platform reports no usable event times (60 ms at 20 ms per sample).
  static const int minJoltSamplesWithoutTimes = 4;

  /// A candidate must be confirmed within this time after the jolt.
  static const Duration confirmWindow = Duration(seconds: 10);

  /// Rule (a): the last speed before the jolt must be at least this (km/h).
  /// 20 rather than 15: below about 20 km/h, GPS lag makes a gentle stop
  /// look abrupt. Replaying the 2026-11-13 ride with a jolt placed at every
  /// moving second, on each fix's own speed (estimated by undoing the
  /// provider's filter on the saved speeds, which is noisy), a 15 km/h
  /// floor confirmed 17 to 29 of 686 such jolts depending on where in the
  /// second the jolt falls, a 20 km/h floor 11 to 19 of 629 (mostly at 20
  /// to 35 km/h, up to 2.5 s before a hard but normal stop). None of the
  /// ride's 52 real jolts confirmed. Slow crashes usually tip the bike over,
  /// which rule (b) catches.
  static const double minMovingSpeedKmh = 20.0;

  /// Rule (a): the speed after the jolt must fall below this (km/h).
  static const double nearStopSpeedKmh = 8.0;

  /// Rule (a): the speed before the jolt only counts from a fix at most this
  /// old at the jolt (about two missed 1 Hz fixes); an older one is stale.
  static const Duration maxPreJoltSpeedAge = Duration(seconds: 3);

  /// Rule (a): the near-stop must come no later than a stop at this mean
  /// deceleration would take, plus [stopGpsLag]. Normal stops mostly brake
  /// at about 0.1 to 0.3 g (the 2026-11-13 ride's seven stops from 15 km/h
  /// or more peaked at 0.25 g on the saved, filtered speed, but undoing the
  /// filter suggests one-second drops near 0.5 g in a few hard stops); a
  /// collision stops the bike almost at once.
  static const double abruptStopMinDecelerationG = 0.6;

  /// Rule (a): allowance for the receiver's speed lagging the bike: its own
  /// smoothing, the delivery delay and the wait for the next 1 Hz fix. The
  /// provider passes each fix's own speed, not its filtered speed, so the
  /// app's smoothing takes none of it.
  static const Duration stopGpsLag = Duration(seconds: 2);

  /// Rule (b): gravity must differ from the pre-jolt direction by more than
  /// this. A bike on its side stand leans only about 10 to 15 degrees, and
  /// even 1 g of braking tilts the measured gravity by only 45 degrees. In a
  /// coordinated lean through a turn, gravity plus the centripetal
  /// acceleration stays along the bike's own vertical axis, so the measured
  /// direction does not change at all (only its size grows).
  static const double tipOverMinAngleDegrees = 60.0;

  /// Rule (b): the tip-over angle must hold this long, as with the bike
  /// lying on its side or the phone thrown off the mount.
  static const Duration tipOverHold = Duration(seconds: 2);

  /// Time constant of the orientation low-pass on the raw accelerometer: it
  /// removes vibration but follows a fall within about a second.
  static const Duration orientationTimeConstant = Duration(milliseconds: 500);

  /// The pre-jolt orientation is taken at least this long before the jolt,
  /// so the impact itself has not moved the estimate yet.
  static const Duration referenceLead = Duration(milliseconds: 500);

  /// A pending candidate's higher peak is reported to the observer only when
  /// it exceeds the last reported one by this much (g).
  static const double peakReportStepG = 0.5;

  static const Duration _orientationHistory = Duration(seconds: 3);
  static const int _maxWindowSamples = 64;
  static const double _gravity = 9.81;
  // Below this measured magnitude (m/s²), for example in free fall, the
  // direction is not used.
  static const double _minOrientationMagnitude = 0.5 * _gravity;

  /// Creates a detector; [log] receives one line per candidate started and
  /// per candidate that expired unconfirmed.
  CrashDetector({void Function(String message)? log}) : _log = log;

  final void Function(String message)? _log;

  /// Diagnostics listener; `null` (the default) means none. It never
  /// changes what the detector decides.
  CrashDetectorObserver? observer;

  double _triggerG = 3.5;
  Duration _debounce = const Duration(seconds: 6);

  final ListQueue<_LinearSample> _window = ListQueue<_LinearSample>();
  double _sumX = 0.0;
  double _sumY = 0.0;
  double _sumZ = 0.0;

  DateTime? _runStartedAt;
  int _runSampleCount = 0;
  double _runPeakG = 0.0;
  bool _runReported = false;
  // The last speed when the run started: a fix arriving during the 60 ms
  // before the jolt is reported must not replace the pre-jolt speed.
  double? _runSpeedKmh;
  DateTime? _runSpeedAt;

  _Candidate? _candidate;
  DateTime? _lastConfirmedAt;

  List<double>? _orientation;
  DateTime? _lastOrientationAt;
  final ListQueue<_OrientationSnapshot> _orientationSnapshots =
      ListQueue<_OrientationSnapshot>();

  double? _lastSpeedKmh;
  DateTime? _lastSpeedAt;

  /// The trigger (g) the filtered acceleration must reach.
  double get triggerG => _triggerG;

  /// Whether a jolt is waiting for confirmation.
  bool get hasPendingCandidate => _candidate != null;

  /// Sets the trigger and the minimum time between two incidents (measured
  /// from the confirmation of the previous one).
  void configure({required double triggerG, required Duration debounce}) {
    _triggerG = triggerG;
    _debounce = debounce;
  }

  /// Drops the pending candidate and the debounce, for example at the start
  /// of a ride. With [clearSignals], also forgets the acceleration window,
  /// the orientation and the last speed (when the sensors stop).
  void reset({bool clearSignals = false}) {
    final dropped = _candidate;
    _candidate = null;
    if (dropped != null) {
      observer?.onCandidateDropped(_endInfo(dropped));
    }
    _lastConfirmedAt = null;
    _resetRun();
    if (clearSignals) {
      _window.clear();
      _sumX = 0.0;
      _sumY = 0.0;
      _sumZ = 0.0;
      _orientation = null;
      _lastOrientationAt = null;
      _orientationSnapshots.clear();
      _lastSpeedKmh = null;
      _lastSpeedAt = null;
    }
  }

  /// Adds one linear-acceleration sample (m/s², gravity removed) at [at].
  ConfirmedCrash? addLinearAcceleration(
    double x,
    double y,
    double z,
    DateTime at,
  ) {
    if (!x.isFinite || !y.isFinite || !z.isFinite) {
      return null;
    }
    final rawG = math.sqrt(x * x + y * y + z * z) / _gravity;
    _window.addLast(_LinearSample(at, x, y, z, rawG));
    _sumX += x;
    _sumY += y;
    _sumZ += z;
    while (_window.length > _maxWindowSamples ||
        (_window.length > 1 && at.difference(_window.first.at) >= joltWindow)) {
      final old = _window.removeFirst();
      _sumX -= old.x;
      _sumY -= old.y;
      _sumZ -= old.z;
    }
    // Without usable event times the window would never shrink by time.
    final spanOfWindow = at.difference(_window.first.at);
    if (spanOfWindow <= Duration.zero) {
      while (_window.length > minJoltSamplesWithoutTimes + 1) {
        final old = _window.removeFirst();
        _sumX -= old.x;
        _sumY -= old.y;
        _sumZ -= old.z;
      }
    }

    final n = _window.length;
    final filteredG =
        math.sqrt(
          (_sumX / n) * (_sumX / n) +
              (_sumY / n) * (_sumY / n) +
              (_sumZ / n) * (_sumZ / n),
        ) /
        _gravity;

    observer?.onSample(at, filteredG, rawG, _triggerG);
    _expireCandidate(at);
    if (filteredG >= _triggerG) {
      if (_runStartedAt == null) {
        _runStartedAt = at;
        _runSpeedKmh = _lastSpeedKmh;
        _runSpeedAt = _lastSpeedAt;
        _runPeakG = _window.fold<double>(
          0.0,
          (peak, sample) => math.max(peak, sample.rawG),
        );
      }
      _runSampleCount++;
      _runPeakG = math.max(_runPeakG, rawG);
      final span = at.difference(_runStartedAt!);
      final isSustained =
          span >= minJoltDuration ||
          (span <= Duration.zero &&
              _runSampleCount >= minJoltSamplesWithoutTimes);
      if (isSustained && !_runReported) {
        _runReported = true;
        _onJolt(_runStartedAt!, _runPeakG, at);
      } else if (_runReported) {
        _raisePeak(_candidate, _runPeakG, at);
      }
    } else {
      _resetRun();
    }
    return null;
  }

  /// Adds one raw accelerometer sample (m/s², gravity included) at [at] and
  /// checks the tip-over rule.
  ConfirmedCrash? addGravitySample(double x, double y, double z, DateTime at) {
    if (!x.isFinite || !y.isFinite || !z.isFinite) {
      return null;
    }
    final estimate = _orientation;
    final previousAt = _lastOrientationAt;
    _lastOrientationAt = at;
    if (estimate == null) {
      _orientation = <double>[x, y, z];
    } else {
      var dtMs = previousAt == null
          ? 0
          : at.difference(previousAt).inMilliseconds;
      dtMs = dtMs.clamp(1, 250);
      final tauMs = orientationTimeConstant.inMilliseconds;
      final alpha = tauMs / (tauMs + dtMs);
      estimate[0] = alpha * estimate[0] + (1 - alpha) * x;
      estimate[1] = alpha * estimate[1] + (1 - alpha) * y;
      estimate[2] = alpha * estimate[2] + (1 - alpha) * z;
    }
    final current = _orientation!;
    _orientationSnapshots.addLast(
      _OrientationSnapshot(at, List<double>.of(current)),
    );
    while (_orientationSnapshots.length > 1 &&
        at.difference(_orientationSnapshots.first.at) > _orientationHistory) {
      _orientationSnapshots.removeFirst();
    }

    final candidate = _candidate;
    if (candidate != null && !_isExpired(candidate, at)) {
      final reference = candidate.referenceOrientation;
      if (reference != null && observer != null) {
        _trackTilt(candidate, reference, current);
      }
      if (reference != null && _isTippedOver(reference, current)) {
        final since = candidate.tippedSince ??= at;
        final held = at.difference(since);
        if (held > candidate.longestTipHold) {
          candidate.longestTipHold = held;
        }
        if (held >= tipOverHold) {
          return _confirm(at, CrashConfirmation.tipOver);
        }
      } else {
        candidate.tippedSince = null;
      }
    }
    return _expireCandidate(at);
  }

  /// Adds the speed (km/h) reported at [at] by a GPS fix and checks the
  /// abrupt-stop rule.
  ConfirmedCrash? addSpeed(double speedKmh, DateTime at) {
    if (!speedKmh.isFinite) {
      return null;
    }
    _lastSpeedKmh = speedKmh;
    _lastSpeedAt = at;
    final candidate = _candidate;
    final before = candidate?.speedBeforeKmh;
    if (candidate != null &&
        at.isAfter(candidate.joltAt) &&
        !_isExpired(candidate, at)) {
      candidate.speedFixesAfter++;
      candidate.minSpeedAfterKmh = candidate.minSpeedAfterKmh == null
          ? speedKmh
          : math.min(candidate.minSpeedAfterKmh!, speedKmh);
    }
    if (candidate != null &&
        before != null &&
        at.isAfter(candidate.joltAt) &&
        !_isExpired(candidate, at) &&
        speedKmh < nearStopSpeedKmh) {
      final sinceJolt = at.difference(candidate.joltAt);
      if (sinceJolt <= abruptStopDeadline(before)) {
        return _confirm(at, CrashConfirmation.abruptStop);
      }
      candidate.nearStopTooLate = true;
    }
    return _expireCandidate(at);
  }

  /// Latest time after the jolt at which a near-stop from [speedBeforeKmh]
  /// still counts as abrupt (see [abruptStopMinDecelerationG]).
  static Duration abruptStopDeadline(double speedBeforeKmh) {
    final lostMps = math.max(0.0, speedBeforeKmh - nearStopSpeedKmh) / 3.6;
    final stopSeconds = lostMps / (abruptStopMinDecelerationG * _gravity);
    return stopGpsLag + Duration(milliseconds: (stopSeconds * 1000).round());
  }

  void _onJolt(DateTime joltAt, double peakG, DateTime at) {
    final existing = _candidate;
    if (existing != null) {
      _raisePeak(existing, peakG, at);
      return;
    }
    final lastConfirmedAt = _lastConfirmedAt;
    if (lastConfirmedAt != null &&
        joltAt.difference(lastConfirmedAt) < _debounce) {
      return;
    }
    double? speedBefore;
    final speedAt = _runSpeedAt;
    final speed = _runSpeedKmh;
    if (speedAt != null &&
        speed != null &&
        !speedAt.isAfter(joltAt) &&
        joltAt.difference(speedAt) <= maxPreJoltSpeedAge &&
        speed >= minMovingSpeedKmh) {
      speedBefore = speed;
    }
    final reference = _referenceOrientationBefore(joltAt);
    final candidate = _Candidate(
      joltAt: joltAt,
      peakG: peakG,
      speedBeforeKmh: speedBefore,
      referenceOrientation: reference,
    );
    _candidate = candidate;
    observer?.onCandidateStarted(
      CandidateStartInfo(
        joltAt: joltAt,
        peakG: peakG,
        preJoltSpeedKmh: speed != null && speedAt != null ? speed : null,
        preJoltSpeedAge: speed != null && speedAt != null
            ? joltAt.difference(speedAt)
            : null,
        stopRuleArmed: speedBefore != null,
        orientationAvailable: reference != null,
        stopDeadline: speedBefore == null
            ? null
            : abruptStopDeadline(speedBefore),
      ),
    );
    _log?.call(
      'jolt candidate: peak ${peakG.toStringAsFixed(1)} g, speed before '
      '${speedBefore == null ? 'none (stop rule off)' : '${speedBefore.toStringAsFixed(0)} km/h'}, '
      'orientation ${reference == null ? 'none (tip-over rule off)' : 'kept'}',
    );
  }

  List<double>? _referenceOrientationBefore(DateTime joltAt) {
    final latestAllowed = joltAt.subtract(referenceLead);
    _OrientationSnapshot? reference;
    for (final snapshot in _orientationSnapshots) {
      if (snapshot.at.isAfter(latestAllowed)) {
        break;
      }
      reference = snapshot;
    }
    final vector = reference?.vector;
    if (vector == null || _magnitude(vector) < _minOrientationMagnitude) {
      return null;
    }
    return vector;
  }

  bool _isTippedOver(List<double> reference, List<double> current) {
    final currentMagnitude = _magnitude(current);
    if (currentMagnitude < _minOrientationMagnitude) {
      return false;
    }
    final cosine =
        (reference[0] * current[0] +
            reference[1] * current[1] +
            reference[2] * current[2]) /
        (_magnitude(reference) * currentMagnitude);
    return cosine < math.cos(tipOverMinAngleDegrees * math.pi / 180.0);
  }

  static double _magnitude(List<double> v) =>
      math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);

  bool _isExpired(_Candidate candidate, DateTime at) =>
      at.difference(candidate.joltAt) > confirmWindow;

  // Drops a candidate whose window has passed. Never confirms anything; it
  // returns null so callers can `return _expireCandidate(at)`.
  ConfirmedCrash? _expireCandidate(DateTime at) {
    final candidate = _candidate;
    if (candidate != null && _isExpired(candidate, at)) {
      _candidate = null;
      observer?.onCandidateExpired(at, _endInfo(candidate));
      _log?.call(
        'jolt not confirmed within ${confirmWindow.inSeconds} s '
        '(peak ${candidate.peakG.toStringAsFixed(1)} g)',
      );
    }
    return null;
  }

  ConfirmedCrash _confirm(DateTime at, CrashConfirmation how) {
    final candidate = _candidate!;
    _candidate = null;
    _lastConfirmedAt = at;
    final crash = ConfirmedCrash(
      joltAt: candidate.joltAt,
      peakG: candidate.peakG,
      confirmedAt: at,
      confirmation: how,
    );
    observer?.onCandidateConfirmed(crash);
    return crash;
  }

  void _raisePeak(_Candidate? candidate, double peakG, DateTime at) {
    if (candidate == null) {
      return;
    }
    candidate.raisePeak(peakG);
    if (candidate.peakG >= candidate.reportedPeakG + peakReportStepG) {
      candidate.reportedPeakG = candidate.peakG;
      observer?.onCandidatePeakRaised(at, candidate.peakG);
    }
  }

  // Diagnostics only: the largest angle between the pre-jolt and the
  // current gravity direction while the candidate is pending.
  void _trackTilt(
    _Candidate candidate,
    List<double> reference,
    List<double> current,
  ) {
    final currentMagnitude = _magnitude(current);
    if (currentMagnitude < _minOrientationMagnitude) {
      return;
    }
    final cosine =
        ((reference[0] * current[0] +
                    reference[1] * current[1] +
                    reference[2] * current[2]) /
                (_magnitude(reference) * currentMagnitude))
            .clamp(-1.0, 1.0);
    final degrees = math.acos(cosine) * 180.0 / math.pi;
    candidate.maxTiltDegrees = candidate.maxTiltDegrees == null
        ? degrees
        : math.max(candidate.maxTiltDegrees!, degrees);
  }

  CandidateEndInfo _endInfo(_Candidate c) => CandidateEndInfo(
    joltAt: c.joltAt,
    peakG: c.peakG,
    stopRuleArmed: c.speedBeforeKmh != null,
    speedFixesAfterJolt: c.speedFixesAfter,
    minSpeedAfterJoltKmh: c.minSpeedAfterKmh,
    nearStopTooLate: c.nearStopTooLate,
    orientationAvailable: c.referenceOrientation != null,
    maxTiltDegrees: c.maxTiltDegrees,
    longestTipHold: c.longestTipHold,
  );

  void _resetRun() {
    _runStartedAt = null;
    _runSampleCount = 0;
    _runPeakG = 0.0;
    _runReported = false;
    _runSpeedKmh = null;
    _runSpeedAt = null;
  }
}

class _LinearSample {
  _LinearSample(this.at, this.x, this.y, this.z, this.rawG);

  final DateTime at;
  final double x;
  final double y;
  final double z;
  final double rawG;
}

class _OrientationSnapshot {
  _OrientationSnapshot(this.at, this.vector);

  final DateTime at;
  final List<double> vector;
}

class _Candidate {
  _Candidate({
    required this.joltAt,
    required this.peakG,
    required this.speedBeforeKmh,
    required this.referenceOrientation,
  }) : reportedPeakG = peakG;

  final DateTime joltAt;
  double peakG;
  final double? speedBeforeKmh;
  final List<double>? referenceOrientation;
  DateTime? tippedSince;

  // Diagnostics only (see CrashDetectorObserver); never read by a rule.
  double reportedPeakG;
  int speedFixesAfter = 0;
  double? minSpeedAfterKmh;
  bool nearStopTooLate = false;
  double? maxTiltDegrees;
  Duration longestTipHold = Duration.zero;

  void raisePeak(double g) {
    peakG = math.max(peakG, g);
  }
}
