// lib/features/telemetry/roll_stall_diag.dart
//
// Debug-build diagnostics for the video stalls after segment rolls. Switch
// files under files/diag/ turn parts of the roll work off for one recording
// (read once at START), and a per-recording JSON Lines event log records the
// background prehash, the checkpoint writes and every late tick of a 100 ms
// heartbeat on the main isolate. Release builds never create any of it.
// Like the crash debug log, lines are buffered in memory and appended by a
// periodic flush; any I/O error disables the log for the recording.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Asks the native side to block the Android main thread for [ms]
/// milliseconds; returns its `startMs` and `endMs` (epoch ms), or `null`.
typedef DiagControlStall = Future<Map<Object?, Object?>?> Function(int ms);

/// The diagnostic switches of one recording, read once when it starts.
@immutable
class DiagSwitches {
  /// Creates a set of switch states.
  const DiagSwitches({
    this.skipPrehash = false,
    this.skipCheckpoint = false,
    this.controlStall = false,
  });

  /// Every switch off (release builds, tests, or no switch file).
  static const DiagSwitches off = DiagSwitches();

  /// Subdirectory of the files directory with the switches and the logs.
  static const String directoryName = 'diag';

  /// File name of the [skipPrehash] switch.
  static const String skipPrehashFile = 'skip_prehash';

  /// File name of the [skipCheckpoint] switch.
  static const String skipCheckpointFile = 'skip_checkpoint';

  /// File name of the [controlStall] switch.
  static const String controlStallFile = 'control_stall';

  /// Rolls do not start the background segment hashing.
  final bool skipPrehash;

  /// Rolls do not call `TelemetryProvider.checkpointRideSession` at all.
  final bool skipCheckpoint;

  /// Once, 60 s after START, the Android main thread is blocked for 1.5 s.
  final bool controlStall;

  /// Reads the switch files under `<files>/diag/`. Never throws: anything
  /// that cannot be read counts as off.
  static Future<DiagSwitches> read(
    Future<Directory> Function() resolveDirectory,
  ) async {
    try {
      final base = await resolveDirectory();
      final sep = Platform.pathSeparator;
      final dir = '${base.path}$sep$directoryName$sep';
      Future<bool> on(String name) async {
        try {
          return await File('$dir$name').exists();
        } catch (_) {
          return false;
        }
      }

      return DiagSwitches(
        skipPrehash: await on(skipPrehashFile),
        skipCheckpoint: await on(skipCheckpointFile),
        controlStall: await on(controlStallFile),
      );
    } catch (error) {
      debugPrint('Diag: switches unreadable, all off: $error');
      return off;
    }
  }

  /// The states as JSON fields.
  Map<String, Object?> toJson() => <String, Object?>{
    'skipPrehash': skipPrehash,
    'skipCheckpoint': skipCheckpoint,
    'controlStall': controlStall,
  };

  @override
  bool operator ==(Object other) =>
      other is DiagSwitches &&
      other.skipPrehash == skipPrehash &&
      other.skipCheckpoint == skipCheckpoint &&
      other.controlStall == controlStall;

  @override
  int get hashCode => Object.hash(skipPrehash, skipCheckpoint, controlStall);

  @override
  String toString() =>
      'skip_prehash=$skipPrehash skip_checkpoint=$skipCheckpoint '
      'control_stall=$controlStall';
}

/// Lateness of a periodic tick measured on a monotonic clock: the gap since
/// the previous tick minus the period. Pure, so tests need no timers.
class HeartbeatLateness {
  /// Creates the meter; ticks later than [threshold] are reported.
  HeartbeatLateness({
    this.period = const Duration(milliseconds: 100),
    this.threshold = const Duration(milliseconds: 50),
  });

  /// The intended time between ticks.
  final Duration period;

  /// Lateness above which a tick is reported.
  final Duration threshold;

  int? _lastMs;

  /// Notes a tick at monotonic time [nowMs]; returns its lateness in ms when
  /// it exceeds [threshold], otherwise `null`. The first tick only starts
  /// the measurement.
  int? tick(int nowMs) {
    final last = _lastMs;
    _lastMs = nowMs;
    if (last == null) {
      return null;
    }
    final late = nowMs - last - period.inMilliseconds;
    return late > threshold.inMilliseconds ? late : null;
  }
}

/// Appends `diag/<name>.jsonl` under the directory returned by the resolver.
/// Every line carries `e` (the event) and `ms` (epoch ms).
class DiagEventLog {
  /// Creates the log; call [begin] to start the periodic flush and [finish]
  /// at the end. The file stops growing after [maxBytes] (the closing line
  /// is always written).
  DiagEventLog({
    required this.name,
    required Future<Directory> Function() resolveDirectory,
    DateTime Function()? clock,
    this.flushInterval = const Duration(seconds: 3),
    this.maxBytes = defaultMaxBytes,
  }) : _resolveDirectory = resolveDirectory,
       _clock = clock ?? DateTime.now;

  /// Default size limit of one file.
  static const int defaultMaxBytes = 5 * 1024 * 1024;

  /// The file name without `.jsonl`.
  final String name;

  /// How often buffered lines are appended.
  final Duration flushInterval;

  /// Size limit of the file in bytes.
  final int maxBytes;

  final Future<Directory> Function() _resolveDirectory;
  final DateTime Function() _clock;

  final StringBuffer _pending = StringBuffer();
  Future<void> _chain = Future<void>.value();
  IOSink? _sink;
  Timer? _timer;
  int _bytes = 0;
  bool _disabled = false;
  bool _finished = false;
  bool _capped = false;

  /// Whether writing was turned off by an I/O error.
  bool get isDisabled => _disabled;

  /// Whether [finish] was called.
  bool get isFinished => _finished;

  /// Starts the periodic flush.
  void begin() {
    _timer ??= Timer.periodic(flushInterval, (_) => flush());
  }

  /// Buffers one line `{"e": event, "ms": now, ...fields}`. Never throws.
  void add(String event, [Map<String, Object?> fields = const {}]) {
    _add(event, fields);
  }

  /// Appends the buffered lines now. Never throws.
  void flush() {
    if (_disabled || _pending.isEmpty) {
      return;
    }
    final data = _pending.toString();
    _pending.clear();
    _chain = _chain.then((_) => _write(data));
  }

  /// Writes the closing [event] line, flushes and closes the file. Never
  /// throws; the returned future completes when the file is closed.
  Future<void> finish(String event, [Map<String, Object?> fields = const {}]) {
    if (_finished) {
      return _chain;
    }
    _timer?.cancel();
    _timer = null;
    _add(event, fields, force: true);
    _finished = true;
    flush();
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

  void _add(String event, Map<String, Object?> fields, {bool force = false}) {
    if (_disabled || (_finished && !force) || (_capped && !force)) {
      return;
    }
    final now = _clock().millisecondsSinceEpoch;
    String text;
    try {
      text =
          '${jsonEncode(<String, Object?>{'e': event, 'ms': now, ...fields})}\n';
    } catch (error) {
      debugPrint('Diag: event $event not encodable: $error');
      return;
    }
    if (!force && _bytes + text.length > maxBytes) {
      _capped = true;
      final capped = '{"e":"capped","ms":$now}\n';
      _bytes += capped.length;
      _pending.write(capped);
      return;
    }
    _bytes += text.length;
    _pending.write(text);
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
        final directory = Directory(
          '${base.path}$sep${DiagSwitches.directoryName}',
        );
        await directory.create(recursive: true);
        sink = File(
          '${directory.path}$sep$name.jsonl',
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
    debugPrint('Diag: event log $name disabled: $error');
  }
}

/// The diagnostics of one recording: its switches, its event log
/// (`diag/<rideSessionId>.jsonl`), the main-isolate heartbeat and the
/// optional control stall.
class RecordingDiagSession {
  /// Creates the session; [begin] starts it and [finish] ends it.
  RecordingDiagSession({
    required this.rideSessionId,
    required this.switches,
    required Future<Directory> Function() resolveDirectory,
    DiagControlStall? controlStall,
    DateTime Function()? clock,
    this.heartbeatPeriod = const Duration(milliseconds: 100),
    this.lateThreshold = const Duration(milliseconds: 50),
    this.controlStallDelay = const Duration(seconds: 60),
    this.controlStallDuration = const Duration(milliseconds: 1500),
    Duration flushInterval = const Duration(seconds: 3),
    int maxBytes = DiagEventLog.defaultMaxBytes,
  }) : _controlStall = controlStall ?? nativeControlStall,
       log = DiagEventLog(
         name: rideSessionId,
         resolveDirectory: resolveDirectory,
         clock: clock,
         flushInterval: flushInterval,
         maxBytes: maxBytes,
       );

  /// The debug-only channel of `DiagHeartbeats.kt`.
  static const MethodChannel channel = MethodChannel(
    'com.example.motocam/diag',
  );

  /// Blocks the Android main thread through [channel].
  static Future<Map<Object?, Object?>?> nativeControlStall(int ms) =>
      channel.invokeMethod<Map<Object?, Object?>>(
        'controlStall',
        <String, Object?>{'ms': ms},
      );

  /// The recording's ride id (also the log's file name).
  final String rideSessionId;

  /// The switch states read at START.
  final DiagSwitches switches;

  /// The heartbeat period.
  final Duration heartbeatPeriod;

  /// Lateness above which a heartbeat tick is logged.
  final Duration lateThreshold;

  /// Time after [begin] at which the control stall runs.
  final Duration controlStallDelay;

  /// How long the control stall blocks the main thread.
  final Duration controlStallDuration;

  /// The event log.
  final DiagEventLog log;

  final DiagControlStall _controlStall;
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _heartbeat;
  Timer? _stallTimer;
  HeartbeatLateness? _lateness;
  bool _finished = false;

  /// Writes the `start` line, logs the switches to logcat and starts the
  /// heartbeat and, when switched on, the control stall timer.
  void begin() {
    debugPrint('Diag: recording $rideSessionId switches: $switches');
    log
      ..add('start', <String, Object?>{
        'ride': rideSessionId,
        ...switches.toJson(),
        'periodMs': heartbeatPeriod.inMilliseconds,
        'lateMs': lateThreshold.inMilliseconds,
      })
      ..begin();
    _lateness = HeartbeatLateness(
      period: heartbeatPeriod,
      threshold: lateThreshold,
    );
    _stopwatch.start();
    _lateness!.tick(_stopwatch.elapsedMilliseconds);
    _heartbeat = Timer(heartbeatPeriod, _onHeartbeat);
    if (switches.controlStall) {
      _stallTimer = Timer(controlStallDelay, () => unawaited(_runStall()));
    }
  }

  // A chain of one-shot timers: a late tick never triggers catch-up ticks.
  void _onHeartbeat() {
    if (_finished) {
      return;
    }
    final late = _lateness?.tick(_stopwatch.elapsedMilliseconds);
    if (late != null) {
      log.add('late', <String, Object?>{'lateMs': late});
      if (late >= 500) {
        debugPrint('Diag: main isolate heartbeat $late ms late');
      }
    }
    _heartbeat = Timer(heartbeatPeriod, _onHeartbeat);
  }

  Future<void> _runStall() async {
    if (_finished) {
      return;
    }
    final ms = controlStallDuration.inMilliseconds;
    final calledAt = DateTime.now().millisecondsSinceEpoch;
    debugPrint('Diag: control stall of $ms ms requested');
    try {
      final result = await _controlStall(ms);
      log.add('controlStall', <String, Object?>{
        'requestMs': ms,
        'calledMs': calledAt,
        'startMs': result?['startMs'],
        'endMs': result?['endMs'],
      });
    } catch (error) {
      log.add('controlStall', <String, Object?>{
        'requestMs': ms,
        'calledMs': calledAt,
        'error': '$error',
      });
    }
  }

  /// Background prehash of [files] not-yet-hashed segments ([bytes] total)
  /// started.
  void prehashStarted({required int files, required int bytes}) {
    log.add('prehashStart', <String, Object?>{'files': files, 'bytes': bytes});
  }

  /// The background prehash took [ms] and hashed [hashed] files.
  void prehashEnded({required int ms, required int hashed}) {
    log.add('prehashEnd', <String, Object?>{'durMs': ms, 'hashed': hashed});
  }

  /// Checkpoint [seq] over [segments] segments started.
  void checkpointStarted({required int seq, required int segments}) {
    log.add('checkpointStart', <String, Object?>{
      'seq': seq,
      'segments': segments,
    });
  }

  /// Checkpoint [seq] ended after [ms] (of which [waitMs] waiting for the
  /// prehash); [wrote] tells whether a file was queued.
  void checkpointEnded({
    required int seq,
    required int ms,
    required int waitMs,
    required bool wrote,
  }) {
    log.add('checkpointEnd', <String, Object?>{
      'seq': seq,
      'durMs': ms,
      'waitMs': waitMs,
      'wrote': wrote,
    });
  }

  /// A roll's checkpoint was skipped by `skip_checkpoint`.
  void checkpointSkipped({required int segments}) {
    log.add('checkpointSkipped', <String, Object?>{'segments': segments});
  }

  /// Stops the heartbeat and the stall timer, writes the `stop` line and
  /// closes the file. Never throws.
  Future<void> finish() {
    if (_finished) {
      return log.finish('stop');
    }
    _finished = true;
    _heartbeat?.cancel();
    _heartbeat = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    _stopwatch.stop();
    debugPrint('Diag: recording $rideSessionId diagnostics stopped');
    return log.finish('stop', <String, Object?>{
      'elapsedMs': _stopwatch.elapsedMilliseconds,
    });
  }
}
