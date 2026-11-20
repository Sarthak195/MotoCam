// lib/core/diagnostics/diagnostic_log.dart
//
// The app's persistent diagnostic log: app errors (Dart and native) and a
// session header, so a tester can hand over what went wrong. One line per
// event in `<filesDir>/diagnostics/app.log`, rotated to `app.log.1` at about
// 1 MiB (two files kept). The native side (`Diagnostics.kt`) appends
// uncaught JVM exceptions to the same file synchronously, with the same line
// format. Never log positions, speeds, routes or anything about other
// people: callers pass error text only, and web addresses lose their path
// (a map tile address reveals the ride area).

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Severity of one diagnostic line.
enum DiagnosticLogLevel {
  /// Context, such as the session header.
  info('INFO'),

  /// Something went wrong but the app carried on.
  warning('WARN'),

  /// An error.
  error('ERROR');

  const DiagnosticLogLevel(this.label);

  /// The label written to the line.
  final String label;
}

/// Buffered, append-only writer of the diagnostic log.
///
/// [add] never throws and never touches the disk: lines are buffered and
/// appended by [flush], which runs at once for warnings and errors, after
/// [flushDelay] for info lines and repeats, and on app pause (see
/// `flushDiagnosticsOnPause`). Any I/O failure drops the batch quietly.
/// A line (same level, source and text) seen [repeatWriteLimit] times
/// among the last [recentKeyLimit] distinct lines is then counted instead
/// of written, so build errors repeated every frame, even two that
/// alternate, cannot rotate the rest of the log away. The counts are
/// written, with the head of their line, by the next [flush] that another
/// line, a pause or a share causes, or when the line leaves the window.
class DiagnosticLog {
  /// Creates the log under `<directory>/diagnostics`, where [resolveDirectory]
  /// returns the app's private files directory.
  DiagnosticLog({
    required Future<Directory> Function() resolveDirectory,
    DateTime Function()? clock,
    this.maxBytes = defaultMaxBytes,
    this.flushDelay = const Duration(seconds: 2),
    this.maxBufferedLines = 500,
  }) : _resolveDirectory = resolveDirectory,
       _clock = clock ?? DateTime.now,
       _enabled = true;

  /// A log that records nothing (the default until `main` installs one, so
  /// tests never write files).
  DiagnosticLog.disabled()
    : _resolveDirectory = null,
      _clock = DateTime.now,
      _enabled = false,
      maxBytes = defaultMaxBytes,
      flushDelay = Duration.zero,
      maxBufferedLines = 0;

  /// The log the app's error paths write to.
  static DiagnosticLog instance = DiagnosticLog.disabled();

  /// Subdirectory of the files directory that holds the log.
  static const String directoryName = 'diagnostics';

  /// The current file.
  static const String fileName = 'app.log';

  /// The previous file, after a rotation.
  static const String rotatedFileName = 'app.log.1';

  /// Size at which the current file is rotated.
  static const int defaultMaxBytes = 1024 * 1024;

  /// Longest message (stack trace included) kept on one line.
  static const int maxMessageChars = 8000;

  /// Times a line is written before further copies are only counted.
  static const int repeatWriteLimit = 2;

  /// Distinct recent lines whose copies are counted.
  static const int recentKeyLimit = 16;

  /// Characters of a counted line quoted in its count line.
  static const int repeatHeadChars = 200;

  /// Size the current file may reach: a batch that would take it past this
  /// rotates it first.
  final int maxBytes;

  /// How long an info line may wait in the buffer.
  final Duration flushDelay;

  /// Lines kept in memory while the disk cannot be written; older lines are
  /// dropped first.
  final int maxBufferedLines;

  final Future<Directory> Function()? _resolveDirectory;
  final DateTime Function() _clock;
  final bool _enabled;
  final List<String> _buffer = <String>[];
  Future<void> _chain = Future<void>.value();
  Directory? _resolvedDirectory;
  Timer? _timer;
  int _dropped = 0;
  // Recent distinct lines, oldest first.
  final LinkedHashMap<String, _Recent> _recent =
      LinkedHashMap<String, _Recent>();

  /// Whether this log records anything.
  bool get enabled => _enabled;

  /// The session header logged at this start (set by
  /// `startDiagnosticSession`), kept so a clear can log it again.
  String? sessionHeader;

  /// Lines waiting for [flush] (for tests).
  @visibleForTesting
  List<String> get bufferedLines => List.unmodifiable(_buffer);

  static final RegExp _webAddress = RegExp(
    r'''(https?|wss?)://([^/\s?#'"<>]+)[^\s'"<>)\]]*''',
    caseSensitive: false,
  );

  // The source excerpt a FormatException prints on the lines after its
  // message (and the caret under it), which can be a ride file's text.
  static final RegExp _formatSource = RegExp(
    r'(FormatException[^\n]*)\n[^\n]*(?:\n *\^)?',
  );

  /// [text] with every web address cut to its scheme and host
  /// (`https://host/...`), as a path or query can hold a map tile position,
  /// and the source excerpt of a `FormatException` removed, as it can hold
  /// a slice of a ride file (positions and speeds).
  static String redact(String text) => text
      .replaceAllMapped(
        _formatSource,
        (m) => '${m.group(1)} [source text removed]',
      )
      .replaceAllMapped(_webAddress, (m) {
        final whole = m.group(0)!;
        final origin = '${m.group(1)}://${m.group(2)}';
        return whole.length > origin.length ? '$origin/...' : origin;
      });

  /// Formats one line: `<UTC time> <LEVEL> [<source>] <message>`, with line
  /// breaks written as `\n`, web addresses cut to their host (see
  /// [redact]) and the message capped at [maxMessageChars].
  static String formatLine(
    DateTime time,
    DiagnosticLogLevel level,
    String source,
    String message,
  ) {
    var text = redact(
      message,
    ).replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll('\n', r'\n');
    if (text.length > maxMessageChars) {
      text = '${text.substring(0, maxMessageChars)} [truncated]';
    }
    return '${time.toUtc().toIso8601String()} ${level.label} [$source] $text';
  }

  /// Records [message] from [source] (a short area name such as `camera`),
  /// with [error] and [stack] appended when given. Never throws.
  void add(
    DiagnosticLogLevel level,
    String source,
    String message, {
    Object? error,
    StackTrace? stack,
  }) {
    if (!_enabled) {
      return;
    }
    try {
      final parts = <String>[message];
      if (error != null) {
        parts.add('$error');
      }
      if (stack != null) {
        parts.add('Stack: $stack');
      }
      final text = parts.join(' | ');
      final key = '${level.label} $source $text';
      final seen = _recent.remove(key) ?? _Recent(source, text);
      _recent[key] = seen;
      if (seen.written >= repeatWriteLimit) {
        // Counted only: written by the next flush something else causes.
        seen.suppressed++;
        return;
      }
      seen.written++;
      while (_recent.length > recentKeyLimit) {
        final oldest = _recent.remove(_recent.keys.first)!;
        _emitCount(oldest);
      }
      _push(formatLine(_clock(), level, source, text));
      if (level == DiagnosticLogLevel.info) {
        _scheduleFlush();
      } else {
        unawaited(flush());
      }
    } catch (_) {
      // A diagnostic line is never worth a crash.
    }
  }

  /// Records an info line. Never throws.
  void info(String source, String message) =>
      add(DiagnosticLogLevel.info, source, message);

  /// Records a warning. Never throws.
  void warning(String source, String message) =>
      add(DiagnosticLogLevel.warning, source, message);

  /// Records an error. Never throws.
  void error(
    String source,
    String message, {
    Object? error,
    StackTrace? stack,
  }) => add(
    DiagnosticLogLevel.error,
    source,
    message,
    error: error,
    stack: stack,
  );

  void _push(String line) {
    _buffer.add(line);
    while (_buffer.length > maxBufferedLines) {
      _buffer.removeAt(0);
      _dropped++;
    }
  }

  void _scheduleFlush() {
    _timer ??= Timer(flushDelay, () {
      _timer = null;
      unawaited(flush());
    });
  }

  // Writes the copies of [recent] counted since its last count line.
  void _emitCount(_Recent recent) {
    final count = recent.suppressed;
    if (count == 0) {
      return;
    }
    recent.suppressed = 0;
    var head = redact(recent.text);
    if (head.length > repeatHeadChars) {
      head = '${head.substring(0, repeatHeadChars)}...';
    }
    _push(
      formatLine(
        _clock(),
        DiagnosticLogLevel.info,
        'diagnostics',
        'A line from [${recent.source}] repeated $count more '
            '${count == 1 ? 'time' : 'times'}: $head',
      ),
    );
  }

  // Writes the counts of every recent line.
  void _emitRepeats() {
    for (final recent in _recent.values) {
      _emitCount(recent);
    }
  }

  /// Appends the buffered lines to the file, rotating it first when the
  /// batch would take it past [maxBytes]. Never throws; calls are run one
  /// after the other.
  Future<void> flush() {
    if (!_enabled) {
      return Future<void>.value();
    }
    return _chain = _chain.then((_) => _write()).catchError((Object _) {});
  }

  /// The diagnostics directory, or null when it cannot be resolved yet.
  Future<Directory?> _directory() async {
    final known = _resolvedDirectory;
    if (known != null) {
      return known;
    }
    try {
      final base = await _resolveDirectory!();
      return _resolvedDirectory = Directory(
        '${base.path}${Platform.pathSeparator}$directoryName',
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _write() async {
    _timer?.cancel();
    _timer = null;
    _emitRepeats();
    if (_buffer.isEmpty) {
      return;
    }
    final directory = await _directory();
    if (directory == null) {
      // Kept for the next flush (for example before path_provider answers).
      return;
    }
    final lines = List<String>.of(_buffer);
    _buffer.clear();
    if (_dropped > 0) {
      lines.add(
        formatLine(
          _clock(),
          DiagnosticLogLevel.warning,
          'diagnostics',
          '$_dropped earlier lines were dropped (log not writable)',
        ),
      );
      _dropped = 0;
    }
    try {
      await directory.create(recursive: true);
      final sep = Platform.pathSeparator;
      final file = File('${directory.path}$sep$fileName');
      final text = '${lines.join('\n')}\n';
      if (await file.exists()) {
        final size = await file.length();
        if (size > 0 && size + text.length > maxBytes) {
          final rotated = File('${directory.path}$sep$rotatedFileName');
          if (await rotated.exists()) {
            await rotated.delete();
          }
          await file.rename(rotated.path);
        }
      }
      await file.writeAsString(text, mode: FileMode.append, flush: true);
    } catch (_) {
      // Dropped: the disk may be full or the directory gone.
    }
  }

  /// The log files that exist, oldest first (`app.log.1`, then `app.log`),
  /// after a [flush]. Never throws.
  Future<List<File>> files() async {
    if (!_enabled) {
      return const <File>[];
    }
    await flush();
    try {
      final directory = await _directory();
      if (directory == null) {
        return const <File>[];
      }
      final sep = Platform.pathSeparator;
      final found = <File>[];
      for (final name in const [rotatedFileName, fileName]) {
        final file = File('${directory.path}$sep$name');
        if (await file.exists()) {
          found.add(file);
        }
      }
      return found;
    } catch (_) {
      return const <File>[];
    }
  }

  /// Deletes both files and the buffered lines; returns whether nothing is
  /// left. Never throws.
  Future<bool> clear() async {
    if (!_enabled) {
      return true;
    }
    _buffer.clear();
    _dropped = 0;
    _recent.clear();
    final done = Completer<bool>();
    _chain = _chain
        .then((_) async {
          final directory = await _directory();
          var cleared = directory != null;
          if (directory != null) {
            final sep = Platform.pathSeparator;
            for (final name in const [rotatedFileName, fileName]) {
              try {
                final file = File('${directory.path}$sep$name');
                if (await file.exists()) {
                  await file.delete();
                }
              } catch (_) {
                cleared = false;
              }
            }
          }
          done.complete(cleared);
        })
        .catchError((Object _) {
          if (!done.isCompleted) {
            done.complete(false);
          }
        });
    return done.future;
  }
}

/// A recent distinct line: how often it was written and counted.
class _Recent {
  _Recent(this.source, this.text);

  final String source;
  final String text;
  int written = 0;
  int suppressed = 0;
}

/// Prints [message] with `debugPrint`, as the error paths did before (so it
/// stays silent in release builds), and records it in
/// [DiagnosticLog.instance] from [source] at [level]. Pass error text only:
/// never a position, speed or route.
void debugPrintError(
  String source,
  String message, {
  DiagnosticLogLevel level = DiagnosticLogLevel.error,
}) {
  debugPrint(message);
  DiagnosticLog.instance.add(level, source, message);
}
