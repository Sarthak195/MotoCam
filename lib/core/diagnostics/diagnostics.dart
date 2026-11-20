// lib/core/diagnostics/diagnostics.dart
//
// Wiring of the diagnostic log: the error hooks, the session header and the
// process exits the system recorded since the last launch (from
// `Diagnostics.kt`), the flush on app pause, and the share and clear actions
// of the recording settings sheet.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../services/ride_export_channel.dart';
import 'diagnostic_log.dart';

export 'diagnostic_log.dart';

/// Build switches written to the session header (`--dart-define` values,
/// as `bool.fromEnvironment('NAME')`). This build has none; add each new
/// switch here.
const Map<String, bool> diagnosticBuildSwitches = <String, bool>{};

/// The native side of the diagnostics (`Diagnostics.kt`).
abstract class DiagnosticsNative {
  /// The app version and device: `versionName`, `versionCode`,
  /// `manufacturer`, `model`, `release`, `sdkInt`. Empty when unavailable.
  /// Never throws.
  Future<Map<String, Object?>> sessionInfo();

  /// The process exits the system recorded since the last call (Android 11
  /// and later; empty below), oldest first: `timestamp` (ms since the
  /// epoch), `reason` (the `ApplicationExitInfo.REASON_*` name without the
  /// prefix, such as `CRASH` or `ANR`), `status`, `importance`,
  /// `description` and, for an ANR, `trace` (the head of its trace). The
  /// native side remembers the newest timestamp it returned. Never throws.
  Future<List<Map<String, Object?>>> takeExitReasons();
}

/// The method channel to `Diagnostics.kt`.
class DiagnosticsChannel implements DiagnosticsNative {
  /// Creates the channel wrapper.
  const DiagnosticsChannel();

  /// The method channel.
  static const MethodChannel channel = MethodChannel(
    'com.example.motocam/diagnostics',
  );

  @override
  Future<Map<String, Object?>> sessionInfo() async {
    try {
      final reply = await channel.invokeMethod<Map<Object?, Object?>>(
        'getSessionInfo',
      );
      return <String, Object?>{
        for (final entry in (reply ?? const {}).entries)
          '${entry.key}': entry.value,
      };
    } catch (_) {
      return const <String, Object?>{};
    }
  }

  @override
  Future<List<Map<String, Object?>>> takeExitReasons() async {
    try {
      final reply = await channel.invokeMethod<List<Object?>>(
        'takeExitReasons',
      );
      return <Map<String, Object?>>[
        for (final item in reply ?? const <Object?>[])
          if (item is Map)
            <String, Object?>{
              for (final entry in item.entries) '${entry.key}': entry.value,
            },
      ];
    } catch (_) {
      return const <Map<String, Object?>>[];
    }
  }
}

/// The session header: app version, build mode and switches, and device.
String diagnosticSessionHeader(
  Map<String, Object?> info, {
  required String buildMode,
  Map<String, bool> switches = diagnosticBuildSwitches,
}) {
  String field(String key) => '${info[key] ?? '?'}';
  final switchText = switches.entries
      .map((e) => '${e.key}=${e.value}')
      .join(' ');
  return 'Session start: MotoCam ${field('versionName')} '
      '(${field('versionCode')}) $buildMode build, '
      '${field('manufacturer')} ${field('model')}, '
      'Android ${field('release')} (SDK ${field('sdkInt')}), '
      'switches: ${switchText.isEmpty ? 'none' : switchText}';
}

/// The current build mode's name.
String get diagnosticBuildMode =>
    kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug');

/// Exit reasons logged as errors; the rest as warnings or info.
const Set<String> _errorExitReasons = {'CRASH', 'CRASH_NATIVE', 'ANR'};
const Set<String> _warningExitReasons = {
  'LOW_MEMORY',
  'SIGNALED',
  'EXCESSIVE_RESOURCE_USAGE',
  'INITIALIZATION_FAILURE',
  'DEPENDENCY_DIED',
  'FREEZER',
  'UNKNOWN',
};

/// The level an exit of [reason] is logged at.
DiagnosticLogLevel diagnosticExitLevel(String reason) {
  if (_errorExitReasons.contains(reason)) {
    return DiagnosticLogLevel.error;
  }
  if (_warningExitReasons.contains(reason)) {
    return DiagnosticLogLevel.warning;
  }
  return DiagnosticLogLevel.info;
}

/// One exit reason from [DiagnosticsNative.takeExitReasons] as a line.
String describeDiagnosticExit(Map<String, Object?> exit) {
  final timestamp = exit['timestamp'];
  final at = timestamp is int
      ? DateTime.fromMillisecondsSinceEpoch(
          timestamp,
          isUtc: true,
        ).toIso8601String()
      : '?';
  final reason = '${exit['reason'] ?? '?'}';
  final parts = <String>[
    'Previous process exit at $at: reason=$reason',
    'status=${exit['status'] ?? '?'}',
    'importance=${exit['importance'] ?? '?'}',
  ];
  final description = exit['description'];
  if (description is String && description.isNotEmpty) {
    parts.add('description: $description');
  }
  if (reason == 'CRASH_NATIVE') {
    parts.add('native crash (its tombstone is not copied here)');
  }
  final trace = exit['trace'];
  if (trace is String && trace.isNotEmpty) {
    parts.add('trace head: $trace');
  }
  return parts.join(', ');
}

/// Writes the session header and the exits since the last launch, then
/// flushes. Never throws.
Future<void> startDiagnosticSession(
  DiagnosticLog log,
  DiagnosticsNative native, {
  String? buildMode,
  Map<String, bool> switches = diagnosticBuildSwitches,
}) async {
  try {
    final info = await native.sessionInfo();
    final header = diagnosticSessionHeader(
      info,
      buildMode: buildMode ?? diagnosticBuildMode,
      switches: switches,
    );
    log.sessionHeader = header;
    log.info('session', header);
    final exits = await native.takeExitReasons();
    for (final exit in exits) {
      final reason = '${exit['reason'] ?? '?'}';
      log.add(
        diagnosticExitLevel(reason),
        'exit',
        describeDiagnosticExit(exit),
      );
    }
    await log.flush();
  } catch (_) {
    // The header is context only.
  }
}

/// The text logged for a framework error: the exception, and what the
/// framework was doing.
String _flutterErrorText(FlutterErrorDetails details) {
  final context = details.context?.toDescription();
  final library = details.library;
  final where = [
    if (library != null && library.isNotEmpty) library,
    if (context != null && context.isNotEmpty) context,
  ].join(', ');
  final exception = details.exceptionAsString();
  return where.isEmpty ? exception : '$exception ($where)';
}

/// Sets `FlutterError.onError` and `PlatformDispatcher.instance.onError` so
/// framework errors and uncaught asynchronous errors reach [log], keeping
/// the console reporting: Flutter's default in debug and profile; in
/// release (where `debugPrint` is silenced) the error and its stack through
/// `debugPrintSynchronously`. Errors reported as silent (such as failed
/// image loads, whose message can hold a map-tile URL that reveals the ride
/// area) are never logged, as before. Uncaught errors keep the app running.
///
/// No zone is used, and every isolate the app starts is an `Isolate.run`,
/// whose errors are rethrown to the caller and so reach these hooks or the
/// caller's own error path.
void installErrorHooks(DiagnosticLog log, {bool releaseMode = kReleaseMode}) {
  FlutterError.onError = (FlutterErrorDetails details) {
    if (details.silent) {
      if (!releaseMode) {
        FlutterError.presentError(details);
      }
      return;
    }
    log.error('flutter', _flutterErrorText(details), stack: details.stack);
    if (releaseMode) {
      debugPrintSynchronously('Flutter error: ${details.exceptionAsString()}');
      debugPrintSynchronously('Stack trace: ${details.stack}');
      return;
    }
    FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    log.error('uncaught', 'Uncaught error', error: error, stack: stack);
    debugPrintSynchronously('Uncaught error: $error');
    debugPrintSynchronously('Stack trace: $stack');
    return true;
  };
}

/// Flushes [log] whenever the app is paused, hidden or detached. Keep the
/// returned listener for the app's lifetime.
AppLifecycleListener flushDiagnosticsOnPause(DiagnosticLog log) {
  void flush() => unawaited(log.flush());
  return AppLifecycleListener(
    onInactive: flush,
    onHide: flush,
    onPause: flush,
    onDetach: flush,
  );
}

/// Name of the cache folder the FileProvider shares from (the ride export
/// staging root, `res/xml/export_file_paths.xml`).
const String diagnosticShareCacheRoot = 'ride_export';

/// Folder under [diagnosticShareCacheRoot] that holds the staged copies.
const String diagnosticShareFolder = 'diagnostics';

/// What the share confirmation tells the rider.
const String diagnosticShareConfirmText =
    'It holds app errors, crash and freeze reports, the app version and the '
    'phone model, and no location, speed or route.';

/// Copies the log files into `<cacheDirectory>/ride_export/diagnostics`
/// (cleared first) and returns their paths, oldest first; empty when there
/// is no log. Never throws.
Future<List<String>> stageDiagnosticLogForShare(
  DiagnosticLog log,
  Directory cacheDirectory,
) async {
  try {
    final files = await log.files();
    if (files.isEmpty) {
      return const <String>[];
    }
    final sep = Platform.pathSeparator;
    final staging = Directory(
      '${cacheDirectory.path}$sep$diagnosticShareCacheRoot$sep'
      '$diagnosticShareFolder',
    );
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
    await staging.create(recursive: true);
    final staged = <String>[];
    for (final file in files) {
      final isOlder = file.path.endsWith(DiagnosticLog.rotatedFileName);
      final name = isOlder
          ? 'motocam-diagnostics-older.txt'
          : 'motocam-diagnostics.txt';
      final copy = await file.copy('${staging.path}$sep$name');
      staged.add(copy.path);
    }
    return staged;
  } catch (_) {
    return const <String>[];
  }
}

/// Outcome of [shareDiagnosticLog].
enum DiagnosticShareResult {
  /// The share sheet opened.
  shared,

  /// There is no log to share.
  empty,

  /// Staging or the share sheet failed.
  failed,
}

/// Stages the log (see [stageDiagnosticLogForShare]) and opens the share
/// sheet through the ride export FileProvider. Never throws.
Future<DiagnosticShareResult> shareDiagnosticLog({
  required DiagnosticLog log,
  required Future<Directory> Function() cacheDirectory,
  RideExportNative native = const RideExportChannel(),
}) async {
  try {
    final paths = await stageDiagnosticLogForShare(log, await cacheDirectory());
    if (paths.isEmpty) {
      return DiagnosticShareResult.empty;
    }
    final opened = await native.shareFiles(
      paths: paths,
      mimeTypes: List<String>.filled(paths.length, 'text/plain'),
      subject: 'MotoCam diagnostic log',
    );
    return opened ? DiagnosticShareResult.shared : DiagnosticShareResult.failed;
  } catch (e) {
    log.warning('diagnostics', 'Sharing the diagnostic log failed: $e');
    return DiagnosticShareResult.failed;
  }
}

/// Deletes the log files, the buffered lines and the staged share copies
/// (`<cacheDirectory>/ride_export/diagnostics`), then logs this session's
/// header again (when one was logged), so a log shared later still names
/// the build and phone; returns whether the old log files are gone. Never
/// throws.
Future<bool> clearDiagnosticLog({
  required DiagnosticLog log,
  required Future<Directory> Function() cacheDirectory,
}) async {
  final cleared = await log.clear();
  final header = log.sessionHeader;
  if (header != null) {
    log.info('session', 'Log cleared. $header');
    await log.flush();
  }
  try {
    final sep = Platform.pathSeparator;
    final staging = Directory(
      '${(await cacheDirectory()).path}$sep$diagnosticShareCacheRoot$sep'
      '$diagnosticShareFolder',
    );
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
  } catch (_) {
    // The system clears the cache; the next share replaces the copies.
  }
  return cleared;
}
