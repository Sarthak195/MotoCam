// lib/features/telemetry/crash_debug_log.dart
//
// Debug-build diagnostics for the crash detector: one JSON Lines file per
// ride with what the jolt filter and the two confirmation rules saw, so an
// unplugged test ride can be read afterwards (the phone keeps no live logcat
// during rides). It never records positions. Lines are buffered in memory and
// appended by a periodic flush, so the sensor path never waits on a file; any
// I/O error disables the log for the ride.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'crash_detector.dart';

/// The speed side of one GPS fix, as the crash detector was fed it. Never
/// holds a position.
class GpsSpeedFix {
  /// Creates the record.
  const GpsSpeedFix({
    required this.rawSpeedKmh,
    required this.speedAccuracyMps,
    required this.hasSpeed,
    required this.hasSpeedAccuracy,
    required this.fedKmh,
    required this.fedRaw,
  });

  /// `Position.speed` in km/h (may be non-finite).
  final double rawSpeedKmh;

  /// `Position.speedAccuracy` in m/s (0 when the fix reports none).
  final double speedAccuracyMps;

  /// Android's `Location.hasSpeed()`.
  final bool hasSpeed;

  /// Android's `Location.hasSpeedAccuracy()`.
  final bool hasSpeedAccuracy;

  /// The speed (km/h) the crash detector received for this fix.
  final double fedKmh;

  /// Whether [fedKmh] is the fix's own speed (`true`) or the app's smoothed
  /// fallback (`false`, when the fix reports speed 0 without accuracy).
  final bool fedRaw;
}

/// Writes `crash_debug/<rideSessionId>.jsonl` under the directory returned by
/// the resolver, listening to a [CrashDetector] as its observer.
///
/// Times: `t` is the ride-elapsed time (ms) and `s` the sensor clock (ms
/// since the epoch of the accelerometer's event time). Line types (`e`):
/// `start`, `sec` (one per second of sensor samples), `cand`, `peak`,
/// `confirmed`, `expired`, `dropped`, `capped` and `summary`.
class CrashDebugLog implements CrashDetectorObserver {
  /// Creates the log; call [begin] to start it and [finish] at ride end.
  ///
  /// [clock] is the wall clock the ride-elapsed time is measured on (it must
  /// match the one [rideStartedAt] was taken from). [resolveDirectory]
  /// returns the app's private files directory. The file stops growing after
  /// [maxBytes] (the closing summary is always written).
  CrashDebugLog({
    required this.rideSessionId,
    required this.rideStartedAt,
    required Future<Directory> Function() resolveDirectory,
    required double triggerG,
    DateTime Function()? clock,
    this.flushInterval = const Duration(seconds: 3),
    this.maxBytes = defaultMaxBytes,
  }) : _resolveDirectory = resolveDirectory,
       _triggerG = triggerG,
       _clock = clock ?? DateTime.now;

  /// Subdirectory of the files directory that holds the logs.
  static const String directoryName = 'crash_debug';

  /// Default size limit of one ride's file.
  static const int defaultMaxBytes = 5 * 1024 * 1024;

  /// The ride this log belongs to; also the file name.
  final String rideSessionId;

  /// Wall-clock start of the ride (the zero of `t`).
  final DateTime rideStartedAt;

  /// How often buffered lines are appended to the file.
  final Duration flushInterval;

  /// Size limit of the file in bytes.
  final int maxBytes;

  final Future<Directory> Function() _resolveDirectory;
  final DateTime Function() _clock;
  final double _triggerG;

  final StringBuffer _pending = StringBuffer();
  Future<void> _chain = Future<void>.value();
  IOSink? _sink;
  Timer? _timer;
  int _bytes = 0;
  bool _disabled = false;
  bool _finished = false;
  bool _capped = false;
  DateTime? _latestAt;

  // The latest two GPS speed fixes (sensor time), newest last.
  DateTime? _fixAt;
  GpsSpeedFix? _fix;
  DateTime? _prevFixAt;
  GpsSpeedFix? _prevFix;

  // The current one-second bucket of samples.
  DateTime? _originAt;
  int _bucketIndex = 0;
  int _bucketSamples = 0;
  double _bucketMaxAvgG = 0.0;
  double _bucketMaxRawG = 0.0;
  double _bucketTriggerG = 0.0;
  DateTime? _bucketLastAt;

  // Totals for the summary line.
  int _seconds = 0;
  int _candidates = 0;
  int _abruptStops = 0;
  int _tipOvers = 0;
  int _notConfirmed = 0;
  int _dropped = 0;
  double _maxAvgG = 0.0;

  /// Whether writing was turned off by an I/O error.
  @visibleForTesting
  bool get isDisabled => _disabled;

  /// Writes the header line and starts the periodic flush.
  void begin() {
    _add(<String, Object?>{
      'e': 'start',
      'ride': rideSessionId,
      'startUtc': rideStartedAt.toUtc().toIso8601String(),
      'trigG': _round(_triggerG),
      'joltWindowMs': CrashDetector.joltWindow.inMilliseconds,
      'minJoltMs': CrashDetector.minJoltDuration.inMilliseconds,
      'confirmS': CrashDetector.confirmWindow.inSeconds,
      'minMoveKmh': CrashDetector.minMovingSpeedKmh,
      'nearStopKmh': CrashDetector.nearStopSpeedKmh,
      'tipDeg': CrashDetector.tipOverMinAngleDegrees,
      'tipHoldMs': CrashDetector.tipOverHold.inMilliseconds,
    });
    _timer = Timer.periodic(flushInterval, (_) => _flush());
  }

  /// Writes the last second and the summary, flushes and closes the file.
  /// Never throws; the returned future completes when the file is closed.
  Future<void> finish() {
    if (_finished) {
      return _chain;
    }
    _timer?.cancel();
    _timer = null;
    _emitBucket();
    _add(<String, Object?>{
      'e': 'summary',
      't': _elapsedNow(),
      'seconds': _seconds,
      'candidates': _candidates,
      'abruptStop': _abruptStops,
      'tipOver': _tipOvers,
      'notConfirmed': _notConfirmed,
      'dropped': _dropped,
      'maxAvgG': _round(_maxAvgG),
    }, force: true);
    _finished = true;
    _flush();
    _chain = _chain.then((_) async {
      final sink = _sink;
      _sink = null;
      try {
        await sink?.close();
      } catch (error) {
        _disable(error);
      }
    });
    return _chain;
  }

  /// Records the speed side of a GPS fix received at sensor time [at]; the
  /// per-second and candidate lines carry the latest one.
  void noteFix(DateTime at, GpsSpeedFix fix) {
    if (_finished) {
      return;
    }
    _prevFixAt = _fixAt;
    _prevFix = _fix;
    _fixAt = at;
    _fix = fix;
  }

  // The newest fix received at or before [at], as a compact JSON object with
  // its age at [at] (seconds), or null when there is none.
  Map<String, Object?>? _fixJson(DateTime at) {
    var fixAt = _fixAt;
    var fix = _fix;
    if (fixAt != null && fixAt.isAfter(at)) {
      fixAt = _prevFixAt;
      fix = _prevFix;
    }
    if (fixAt == null || fix == null || fixAt.isAfter(at)) {
      return null;
    }
    return <String, Object?>{
      'kmh': fix.rawSpeedKmh.isFinite ? _round(fix.rawSpeedKmh) : null,
      'acc': fix.speedAccuracyMps.isFinite
          ? _round(fix.speedAccuracyMps)
          : null,
      'hasSpd': fix.hasSpeed,
      'hasAcc': fix.hasSpeedAccuracy,
      'fed': _round(fix.fedKmh),
      'src': fix.fedRaw ? 'raw' : 'smooth',
      'age': double.parse(
        (at.difference(fixAt).inMilliseconds / 1000).toStringAsFixed(1),
      ),
    };
  }

  @override
  void onSample(DateTime at, double averagedG, double rawG, double triggerG) {
    if (_finished) {
      return;
    }
    _maxAvgG = math.max(_maxAvgG, averagedG);
    _noteTime(at);
    final origin = _originAt ??= at;
    final index = at.difference(origin).inMilliseconds ~/ 1000;
    if (index != _bucketIndex && _bucketSamples > 0) {
      _emitBucket();
    }
    _bucketIndex = index;
    _bucketSamples++;
    _bucketMaxAvgG = math.max(_bucketMaxAvgG, averagedG);
    _bucketMaxRawG = math.max(_bucketMaxRawG, rawG);
    _bucketTriggerG = triggerG;
    _bucketLastAt = at;
  }

  @override
  void onCandidateStarted(CandidateStartInfo info) {
    _candidates++;
    _noteTime(info.joltAt);
    _add(<String, Object?>{
      'e': 'cand',
      ..._times(info.joltAt),
      'peakG': _round(info.peakG),
      'preKmh': info.preJoltSpeedKmh == null
          ? null
          : _round(info.preJoltSpeedKmh!),
      'preAgeMs': info.preJoltSpeedAge?.inMilliseconds,
      'ruleA': info.stopRuleArmed,
      'deadlineMs': info.stopDeadline?.inMilliseconds,
      'ruleB': info.orientationAvailable,
      'gps': ?_fixJson(info.joltAt),
    });
  }

  @override
  void onCandidatePeakRaised(DateTime at, double peakG) {
    _noteTime(at);
    _add(<String, Object?>{'e': 'peak', ..._times(at), 'peakG': _round(peakG)});
  }

  @override
  void onCandidateConfirmed(ConfirmedCrash crash) {
    if (crash.confirmation == CrashConfirmation.abruptStop) {
      _abruptStops++;
    } else {
      _tipOvers++;
    }
    _noteTime(crash.confirmedAt);
    _add(<String, Object?>{
      'e': 'confirmed',
      ..._times(crash.confirmedAt),
      'by': crash.confirmation.name,
      'delayMs': crash.confirmedAt.difference(crash.joltAt).inMilliseconds,
      'peakG': _round(crash.peakG),
    });
  }

  @override
  void onCandidateExpired(DateTime at, CandidateEndInfo info) {
    _notConfirmed++;
    _noteTime(at);
    _add(<String, Object?>{
      'e': 'expired',
      ..._times(at),
      'delayMs': at.difference(info.joltAt).inMilliseconds,
      ..._endDetails(info),
    });
  }

  @override
  void onCandidateDropped(CandidateEndInfo info) {
    _dropped++;
    final at = _latestAt;
    _add(<String, Object?>{
      'e': 'dropped',
      if (at != null) ..._times(at) else 't': _elapsedNow(),
      ..._endDetails(info),
    });
  }

  // Why neither rule confirmed, as far as the detector knows.
  Map<String, Object?> _endDetails(CandidateEndInfo info) {
    String ruleA;
    if (!info.stopRuleArmed) {
      ruleA = 'off';
    } else if (info.speedFixesAfterJolt == 0) {
      ruleA = 'noFixAfterJolt';
    } else if (info.nearStopTooLate) {
      ruleA = 'nearStopTooLate';
    } else {
      ruleA = 'neverBelowNearStop';
    }
    String ruleB;
    final tilt = info.maxTiltDegrees;
    if (!info.orientationAvailable) {
      ruleB = 'off';
    } else if (tilt == null) {
      ruleB = 'noOrientationAfterJolt';
    } else if (tilt < CrashDetector.tipOverMinAngleDegrees) {
      ruleB = 'tiltBelowLimit';
    } else {
      ruleB = 'tiltNotHeld';
    }
    return <String, Object?>{
      'peakG': _round(info.peakG),
      'ruleA': ruleA,
      'minKmh': info.minSpeedAfterJoltKmh == null
          ? null
          : _round(info.minSpeedAfterJoltKmh!),
      'fixes': info.speedFixesAfterJolt,
      'ruleB': ruleB,
      'maxTiltDeg': tilt == null ? null : _round(tilt),
      'holdMs': info.longestTipHold.inMilliseconds,
    };
  }

  void _emitBucket() {
    final last = _bucketLastAt;
    if (_bucketSamples == 0 || last == null) {
      return;
    }
    _seconds++;
    _add(<String, Object?>{
      'e': 'sec',
      ..._times(last),
      'avgG': _round(_bucketMaxAvgG),
      'rawG': _round(_bucketMaxRawG),
      'n': _bucketSamples,
      'trig': _round(_bucketTriggerG),
      'gps': ?_fixJson(last),
    });
    _bucketSamples = 0;
    _bucketMaxAvgG = 0.0;
    _bucketMaxRawG = 0.0;
    _bucketLastAt = null;
  }

  void _noteTime(DateTime at) {
    final latest = _latestAt;
    if (latest == null || at.isAfter(latest)) {
      _latestAt = at;
    }
  }

  int _elapsedNow() =>
      math.max(0, _clock().difference(rideStartedAt).inMilliseconds);

  // The sensor clock `s` and the ride-elapsed time `t` of [at]: the wall
  // clock reads "now" at the latest sensor time seen, so [at] lies that far
  // before it.
  Map<String, Object?> _times(DateTime at) {
    final latest = _latestAt ?? at;
    final behindMs = latest.difference(at).inMilliseconds;
    return <String, Object?>{
      't': math.max(0, _elapsedNow() - behindMs),
      's': at.millisecondsSinceEpoch,
    };
  }

  static double _round(double value) =>
      value.isFinite ? double.parse(value.toStringAsFixed(2)) : 0.0;

  void _add(Map<String, Object?> line, {bool force = false}) {
    if (_disabled || (_finished && !force)) {
      return;
    }
    if (_capped && !force) {
      return;
    }
    final text = '${jsonEncode(line)}\n';
    if (!force && _bytes + text.length > maxBytes) {
      _capped = true;
      _bytes += 20;
      _pending.write('{"e":"capped"}\n');
      return;
    }
    _bytes += text.length;
    _pending.write(text);
  }

  void _flush() {
    if (_disabled || _pending.isEmpty) {
      return;
    }
    final data = _pending.toString();
    _pending.clear();
    _chain = _chain.then((_) => _write(data));
  }

  Future<void> _write(String data) async {
    if (_disabled) {
      return;
    }
    try {
      var sink = _sink;
      if (sink == null) {
        final base = await _resolveDirectory();
        final sep = Platform.pathSeparator;
        final directory = Directory('${base.path}$sep$directoryName');
        await directory.create(recursive: true);
        sink = File(
          '${directory.path}$sep$rideSessionId.jsonl',
        ).openWrite(mode: FileMode.append);
        unawaited(sink.done.catchError(_disable));
        _sink = sink;
      }
      sink.write(data);
      await sink.flush();
    } catch (error) {
      _disable(error);
    }
  }

  void _disable(Object error) {
    if (_disabled) {
      return;
    }
    _disabled = true;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    debugPrint('Telemetry: crash debug log disabled for this ride: $error');
  }
}
