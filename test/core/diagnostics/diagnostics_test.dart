import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/diagnostics/diagnostics.dart';
import 'package:motocam/core/services/ride_export_channel.dart';
import 'package:motocam/features/recording/ride_orientation.dart';

class _FakeNative implements DiagnosticsNative {
  _FakeNative({this.info = const {}, this.exits = const []});

  final Map<String, Object?> info;
  final List<Map<String, Object?>> exits;

  @override
  Future<Map<String, Object?>> sessionInfo() async => info;

  @override
  Future<List<Map<String, Object?>>> takeExitReasons() async => exits;
}

class _FakeShare extends Fake implements RideExportNative {
  _FakeShare({this.opens = true});

  final bool opens;
  List<String>? paths;
  List<String>? mimeTypes;
  String? subject;

  @override
  Future<bool> shareFiles({
    required List<String> paths,
    required List<String> mimeTypes,
    required String subject,
  }) async {
    this.paths = paths;
    this.mimeTypes = mimeTypes;
    this.subject = subject;
    return opens;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late Directory files;
  late Directory cache;
  late DiagnosticLog log;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('motocam_diag_');
    files = await Directory('${temp.path}/files').create();
    cache = await Directory('${temp.path}/cache').create();
    log = DiagnosticLog(
      resolveDirectory: () async => files,
      clock: () => DateTime.utc(2026, 11, 20),
      flushDelay: const Duration(milliseconds: 10),
    );
  });

  tearDown(() async {
    await log.flush();
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<List<String>> logLines() async {
    final found = await log.files();
    return [for (final f in found) ...await f.readAsLines()];
  }

  group('session header', () {
    test('names version, build, device and switches', () {
      final header = diagnosticSessionHeader(
        const {
          'versionName': '0.1.19',
          'versionCode': 19,
          'manufacturer': 'OnePlus',
          'model': 'LE2113',
          'release': '14',
          'sdkInt': 34,
        },
        buildMode: 'debug',
        switches: const {'MOTOCAM_X': true},
      );
      expect(
        header,
        'Session start: MotoCam 0.1.19 (19) debug build, OnePlus LE2113, '
        'Android 14 (SDK 34), switches: MOTOCAM_X=true',
      );
    });

    test('marks missing fields and no switches', () {
      expect(
        diagnosticSessionHeader(
          const {},
          buildMode: 'release',
          switches: const {},
        ),
        'Session start: MotoCam ? (?) release build, ? ?, '
        'Android ? (SDK ?), switches: none',
      );
    });

    test('lists MOTOCAM_LANDSCAPE with the value of this build by default', () {
      expect(diagnosticBuildSwitches, {
        'MOTOCAM_LANDSCAPE': kLandscapeRecording,
      });
      expect(
        diagnosticSessionHeader(const {}, buildMode: 'release'),
        'Session start: MotoCam ? (?) release build, ? ?, '
        'Android ? (SDK ?), switches: MOTOCAM_LANDSCAPE=$kLandscapeRecording',
      );
    });
  });

  group('exit reasons', () {
    test('levels', () {
      expect(diagnosticExitLevel('CRASH'), DiagnosticLogLevel.error);
      expect(diagnosticExitLevel('CRASH_NATIVE'), DiagnosticLogLevel.error);
      expect(diagnosticExitLevel('ANR'), DiagnosticLogLevel.error);
      expect(diagnosticExitLevel('LOW_MEMORY'), DiagnosticLogLevel.warning);
      expect(diagnosticExitLevel('USER_REQUESTED'), DiagnosticLogLevel.info);
    });

    test('an ANR line carries its time, description and trace head', () {
      final text = describeDiagnosticExit(const {
        'timestamp': 1763634272000,
        'reason': 'ANR',
        'status': 0,
        'importance': 100,
        'description': 'Input dispatching timed out',
        'trace': '"main" prio=5 tid=1 Blocked',
      });
      expect(text, startsWith('Previous process exit at 2025-11-20T'));
      expect(text, contains('reason=ANR'));
      expect(text, contains('description: Input dispatching timed out'));
      expect(text, contains('trace head: "main" prio=5 tid=1 Blocked'));
    });

    test('a native crash is noted', () {
      final text = describeDiagnosticExit(const {'reason': 'CRASH_NATIVE'});
      expect(text, contains('at ?'));
      expect(text, contains('native crash'));
    });
  });

  test('startDiagnosticSession writes the header and every exit', () async {
    await startDiagnosticSession(
      log,
      _FakeNative(
        info: const {'versionName': '0.1.19', 'versionCode': 19},
        exits: const [
          {'timestamp': 1, 'reason': 'CRASH', 'description': 'boom'},
          {'timestamp': 2, 'reason': 'USER_REQUESTED'},
        ],
      ),
      buildMode: 'debug',
      switches: const {},
    );
    final lines = await logLines();
    expect(lines, hasLength(3));
    expect(lines[0], contains('INFO [session] Session start: MotoCam 0.1.19'));
    expect(lines[1], contains('ERROR [exit] Previous process exit'));
    expect(lines[1], contains('description: boom'));
    expect(lines[2], contains('INFO [exit]'));
  });

  group('installErrorHooks', () {
    late FlutterExceptionHandler? previousFlutter;
    late ErrorCallback? previousPlatform;

    setUp(() {
      previousFlutter = FlutterError.onError;
      previousPlatform = PlatformDispatcher.instance.onError;
    });

    tearDown(() {
      FlutterError.onError = previousFlutter;
      PlatformDispatcher.instance.onError = previousPlatform;
    });

    test('framework errors are logged; silent ones are not', () async {
      installErrorHooks(log, releaseMode: true);
      FlutterError.onError!(
        FlutterErrorDetails(
          exception: AssertionError("'_dependents.isEmpty': is not true."),
          stack: StackTrace.fromString('#0 Element.unmount'),
          library: 'widgets library',
          context: ErrorDescription('while finalizing the widget tree'),
        ),
      );
      FlutterError.onError!(
        FlutterErrorDetails(
          exception: Exception('https://tile.example.org/15/1/2.png'),
          silent: true,
        ),
      );
      final lines = await logLines();
      expect(lines, hasLength(1));
      expect(lines.single, contains('ERROR [flutter]'));
      expect(lines.single, contains('_dependents.isEmpty'));
      expect(
        lines.single,
        contains('widgets library, while finalizing the widget tree'),
      );
      expect(lines.single, contains('Stack: #0 Element.unmount'));
    });

    test('uncaught errors are logged and handled', () async {
      installErrorHooks(log, releaseMode: true);
      final handled = PlatformDispatcher.instance.onError!(
        StateError('late'),
        StackTrace.fromString('#0 future'),
      );
      expect(handled, isTrue);
      final lines = await logLines();
      expect(lines.single, contains('ERROR [uncaught] Uncaught error'));
      expect(lines.single, contains('Bad state: late'));
    });
  });

  group('share and clear', () {
    String stagingPath() =>
        '${cache.path}${Platform.pathSeparator}ride_export'
        '${Platform.pathSeparator}diagnostics';

    test('no log: nothing is shared', () async {
      final share = _FakeShare();
      final result = await shareDiagnosticLog(
        log: log,
        cacheDirectory: () async => cache,
        native: share,
      );
      expect(result, DiagnosticShareResult.empty);
      expect(share.paths, isNull);
    });

    test('stages copies under ride_export/diagnostics and shares '
        'them', () async {
      log.error('a', 'something failed');
      final share = _FakeShare();
      final result = await shareDiagnosticLog(
        log: log,
        cacheDirectory: () async => cache,
        native: share,
      );
      expect(result, DiagnosticShareResult.shared);
      expect(share.paths, hasLength(1));
      expect(share.paths!.single, startsWith(stagingPath()));
      expect(share.paths!.single, endsWith('motocam-diagnostics.txt'));
      expect(share.mimeTypes, ['text/plain']);
      expect(share.subject, 'MotoCam diagnostic log');
      expect(
        await File(share.paths!.single).readAsString(),
        contains('something failed'),
      );
      expect(diagnosticShareFolder, isNot('trim'));
    });

    test('a share sheet that does not open is a failure', () async {
      log.error('a', 'b');
      final result = await shareDiagnosticLog(
        log: log,
        cacheDirectory: () async => cache,
        native: _FakeShare(opens: false),
      );
      expect(result, DiagnosticShareResult.failed);
    });

    test('clear removes the log and the staged copies', () async {
      log.error('a', 'b');
      await shareDiagnosticLog(
        log: log,
        cacheDirectory: () async => cache,
        native: _FakeShare(),
      );
      expect(await Directory(stagingPath()).exists(), isTrue);
      final cleared = await clearDiagnosticLog(
        log: log,
        cacheDirectory: () async => cache,
      );
      expect(cleared, isTrue);
      expect(await log.files(), isEmpty);
      expect(await Directory(stagingPath()).exists(), isFalse);
    });

    test('clear logs the session header again', () async {
      await startDiagnosticSession(
        log,
        _FakeNative(
          info: const {'versionName': '0.1.19', 'versionCode': 19},
          exits: const [
            {'timestamp': 1, 'reason': 'CRASH', 'description': 'boom'},
          ],
        ),
        buildMode: 'debug',
        switches: const {},
      );
      log.error('camera', 'old error');
      final cleared = await clearDiagnosticLog(
        log: log,
        cacheDirectory: () async => cache,
      );
      expect(cleared, isTrue);
      log.error('camera', 'new error');
      final lines = await logLines();
      expect(lines, hasLength(2));
      expect(
        lines[0],
        contains('INFO [session] Log cleared. Session start: MotoCam 0.1.19'),
      );
      expect(lines[0], contains('debug'));
      expect(lines[1], contains('new error'));
      expect(lines.join(' '), isNot(contains('old error')));
      expect(lines.join(' '), isNot(contains('boom')));
    });

    test('the confirm text says there is no location', () {
      expect(diagnosticShareConfirmText, contains('no location'));
    });
  });

  group('DiagnosticsChannel', () {
    const channel = DiagnosticsChannel.channel;
    TestDefaultBinaryMessenger messenger() =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger().setMockMethodCallHandler(channel, null));

    test('name matches the native side', () {
      expect(channel.name, 'com.example.motocam/diagnostics');
    });

    test('decodes the replies', () async {
      messenger().setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'getSessionInfo':
            return <Object?, Object?>{'versionName': '0.1.19', 'sdkInt': 34};
          case 'takeExitReasons':
            return <Object?>[
              <Object?, Object?>{'reason': 'ANR', 'timestamp': 5},
              'not a map',
            ];
        }
        return null;
      });
      const native = DiagnosticsChannel();
      expect(await native.sessionInfo(), {
        'versionName': '0.1.19',
        'sdkInt': 34,
      });
      expect(await native.takeExitReasons(), [
        {'reason': 'ANR', 'timestamp': 5},
      ]);
    });

    test('never throws', () async {
      messenger().setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'X');
      });
      const native = DiagnosticsChannel();
      expect(await native.sessionInfo(), isEmpty);
      expect(await native.takeExitReasons(), isEmpty);
    });
  });
}
