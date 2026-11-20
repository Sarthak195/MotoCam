import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/diagnostics/diagnostic_log.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('motocam_diag_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  DiagnosticLog newLog({int maxBytes = DiagnosticLog.defaultMaxBytes}) =>
      DiagnosticLog(
        resolveDirectory: () async => temp,
        clock: () => DateTime.utc(2026, 11, 20, 10, 24, 32),
        maxBytes: maxBytes,
        flushDelay: const Duration(milliseconds: 10),
      );

  File logFile([String name = DiagnosticLog.fileName]) => File(
    '${temp.path}${Platform.pathSeparator}${DiagnosticLog.directoryName}'
    '${Platform.pathSeparator}$name',
  );

  group('formatLine', () {
    test('writes UTC time, level, source and message on one line', () {
      final line = DiagnosticLog.formatLine(
        DateTime.utc(2026, 11, 20, 10, 24, 32, 5),
        DiagnosticLogLevel.error,
        'camera',
        'first\nsecond\r\nthird',
      );
      expect(
        line,
        r'2026-11-20T10:24:32.005Z ERROR [camera] first\nsecond\nthird',
      );
      expect(line.contains('\n'), isFalse);
    });

    test('caps a long message', () {
      final line = DiagnosticLog.formatLine(
        DateTime.utc(2026),
        DiagnosticLogLevel.info,
        's',
        'x' * (DiagnosticLog.maxMessageChars + 50),
      );
      expect(line, endsWith(' [truncated]'));
      expect(line.length, lessThan(DiagnosticLog.maxMessageChars + 80));
    });

    test('cuts web addresses to their host', () {
      final line = DiagnosticLog.formatLine(
        DateTime.utc(2026),
        DiagnosticLogLevel.error,
        'map',
        'HttpException: https://tile.openstreetmap.org/15/23456/12345.png '
            'failed; see https://docs.flutter.dev/testing/errors and '
            'http://example.com',
      );
      expect(line, isNot(contains('23456')));
      expect(line, contains('https://tile.openstreetmap.org/...'));
      expect(line, contains('https://docs.flutter.dev/...'));
      expect(line, contains('http://example.com'));
    });
  });

  test('the source excerpt of a FormatException is removed', () {
    Object? caught;
    try {
      jsonDecode('{"lat": 48.85661, "lon": 2.35222, "speedKmh": 31.5');
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<FormatException>());
    expect('$caught', contains('48.85661'));
    final line = DiagnosticLog.formatLine(
      DateTime.utc(2026),
      DiagnosticLogLevel.error,
      'telemetry',
      'Ride load failed: $caught | $caught | Stack: #0 main',
    );
    expect(line, isNot(contains('48.85661')));
    expect(line, isNot(contains('31.5')));
    expect(line, contains('FormatException: Unexpected end of input'));
    expect(line, contains('[source text removed]'));
    expect(line, contains('Stack: #0 main'));
  });

  test('errors reach the file with their stack, info lines after the '
      'delay', () async {
    final log = newLog();
    log.info('session', 'Session start');
    log.error(
      'flutter',
      'Failed assertion',
      error: StateError('bad'),
      stack: StackTrace.fromString('#0 main (file.dart:1)\n#1 run'),
    );
    await log.flush();
    final lines = await logFile().readAsLines();
    expect(lines, hasLength(2));
    expect(lines[0], contains('INFO [session] Session start'));
    expect(lines[1], contains('ERROR [flutter] Failed assertion | '));
    expect(lines[1], contains('Bad state: bad'));
    expect(lines[1], contains(r'Stack: #0 main (file.dart:1)\n#1 run'));

    log.info('session', 'later');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await log.flush();
    expect(await logFile().readAsLines(), hasLength(3));
  });

  test('a repeated line is counted, not written again', () async {
    final log = newLog();
    for (var i = 0; i < 5; i++) {
      log.error('flutter', 'same error');
    }
    log.error('flutter', 'other error');
    await log.flush();
    final lines = await logFile().readAsLines();
    expect(lines, hasLength(3));
    expect(lines[0], contains('same error'));
    expect(lines[1], contains('The previous line repeated 4 more times'));
    expect(lines[2], contains('other error'));
  });

  test('rotates to app.log.1 and keeps two files', () async {
    final log = newLog(maxBytes: 300);
    for (var i = 0; i < 12; i++) {
      log.error('test', 'line $i ${'y' * 60}');
      await log.flush();
    }
    expect(await logFile().exists(), isTrue);
    expect(await logFile(DiagnosticLog.rotatedFileName).exists(), isTrue);
    expect(await logFile().length(), lessThanOrEqualTo(300));
    final all = [
      ...await logFile(DiagnosticLog.rotatedFileName).readAsLines(),
      ...await logFile().readAsLines(),
    ];
    expect(all.last, contains('line 11'));
    expect(all.first, isNot(contains('line 0 ')));
    final files = await log.files();
    expect(files.map((f) => f.path.split(Platform.pathSeparator).last), [
      DiagnosticLog.rotatedFileName,
      DiagnosticLog.fileName,
    ]);
  });

  test('keeps lines while the directory is unknown and notes no '
      'drop', () async {
    var available = false;
    final log = DiagnosticLog(
      resolveDirectory: () async {
        if (!available) {
          throw StateError('not yet');
        }
        return temp;
      },
      flushDelay: const Duration(milliseconds: 10),
    );
    log.error('a', 'early');
    await log.flush();
    await log.flush();
    expect(log.bufferedLines, hasLength(1));
    available = true;
    await log.flush();
    final lines = await logFile().readAsLines();
    expect(lines, hasLength(1));
    expect(lines.single, contains('early'));
  });

  test('a full buffer drops the oldest lines and says so', () async {
    var available = false;
    final log = DiagnosticLog(
      resolveDirectory: () async {
        if (!available) {
          throw StateError('not yet');
        }
        return temp;
      },
      maxBufferedLines: 3,
    );
    for (var i = 0; i < 5; i++) {
      log.error('a', 'line $i');
    }
    await log.flush();
    available = true;
    await log.flush();
    final lines = await logFile().readAsLines();
    expect(lines, hasLength(4));
    expect(lines.first, contains('line 2'));
    expect(lines.last, contains('2 earlier lines were dropped'));
  });

  test('add and flush never throw when writing fails', () async {
    final blocker = File('${temp.path}${Platform.pathSeparator}file');
    await blocker.writeAsString('x');
    final log = DiagnosticLog(
      resolveDirectory: () async => Directory(blocker.path),
    );
    log.error('a', 'b');
    await log.flush();
    expect(await log.files(), isEmpty);
  });

  test('clear deletes both files', () async {
    final log = newLog(maxBytes: 100);
    for (var i = 0; i < 4; i++) {
      log.error('a', 'z' * 60);
      await log.flush();
    }
    expect(await log.files(), hasLength(2));
    expect(await log.clear(), isTrue);
    expect(await log.files(), isEmpty);
  });

  test('a disabled log records nothing', () async {
    final log = DiagnosticLog.disabled();
    log.error('a', 'b');
    expect(log.enabled, isFalse);
    expect(log.bufferedLines, isEmpty);
    expect(await log.files(), isEmpty);
    expect(await log.clear(), isTrue);
  });

  test('debugPrintError prints and records the message', () async {
    final previous = DiagnosticLog.instance;
    final log = newLog();
    DiagnosticLog.instance = log;
    addTearDown(() => DiagnosticLog.instance = previous);
    debugPrintError('export', 'Ride export failed: boom');
    debugPrintError(
      'telemetry',
      'stream unavailable',
      level: DiagnosticLogLevel.warning,
    );
    await log.flush();
    final lines = await logFile().readAsLines();
    expect(lines[0], contains('ERROR [export] Ride export failed: boom'));
    expect(lines[1], contains('WARN [telemetry] stream unavailable'));
  });
}
