import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/features/telemetry/providers/telemetry_provider.dart';
import 'package:motocam/features/telemetry/roll_stall_diag.dart';

final String _sep = Platform.pathSeparator;

File _diagFile(Directory dir, String name) =>
    File('${dir.path}${_sep}diag$_sep$name');

List<Map<String, dynamic>> _readLines(File file) => [
  for (final line in file.readAsLinesSync())
    jsonDecode(line) as Map<String, dynamic>,
];

void _touchSwitch(Directory dir, String name) {
  _diagFile(dir, name)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('motocam_roll_diag_');
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  group('DiagSwitches.read', () {
    test('all off without switch files', () async {
      expect(await DiagSwitches.read(() async => dir), DiagSwitches.off);
    });

    test('each switch file turns its switch on', () async {
      _touchSwitch(dir, DiagSwitches.skipPrehashFile);
      expect(
        await DiagSwitches.read(() async => dir),
        const DiagSwitches(skipPrehash: true),
      );
      _touchSwitch(dir, DiagSwitches.skipCheckpointFile);
      _touchSwitch(dir, DiagSwitches.controlStallFile);
      expect(
        await DiagSwitches.read(() async => dir),
        const DiagSwitches(
          skipPrehash: true,
          skipCheckpoint: true,
          controlStall: true,
        ),
      );
    });

    test('an unresolvable directory reads as all off', () async {
      expect(
        await DiagSwitches.read(() async => throw const FileSystemException()),
        DiagSwitches.off,
      );
    });
  });

  group('HeartbeatLateness', () {
    test('reports only ticks later than the threshold', () {
      final meter = HeartbeatLateness();
      expect(meter.tick(0), isNull);
      expect(meter.tick(100), isNull);
      expect(meter.tick(250), isNull); // 50 ms late: not above the threshold
      expect(meter.tick(1850), 1500);
      expect(meter.tick(1960), isNull);
    });
  });

  group('DiagEventLog', () {
    test('writes JSON lines with the event and epoch ms', () async {
      final at = DateTime.utc(2026, 11, 17, 10);
      final log = DiagEventLog(
        name: 'ride_1',
        resolveDirectory: () async => dir,
        clock: () => at,
      )..begin();
      log.add('prehashStart', {'files': 2, 'bytes': 1234});
      await log.finish('stop', {'elapsedMs': 5});

      final lines = _readLines(_diagFile(dir, 'ride_1.jsonl'));
      expect(lines, [
        {
          'e': 'prehashStart',
          'ms': at.millisecondsSinceEpoch,
          'files': 2,
          'bytes': 1234,
        },
        {'e': 'stop', 'ms': at.millisecondsSinceEpoch, 'elapsedMs': 5},
      ]);
    });

    test('flushes periodically before finish', () async {
      final log = DiagEventLog(
        name: 'ride_2',
        resolveDirectory: () async => dir,
        flushInterval: const Duration(milliseconds: 20),
      )..begin();
      log.add('late', {'lateMs': 120});
      final file = _diagFile(dir, 'ride_2.jsonl');
      for (var i = 0; i < 100 && !file.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      for (var i = 0; i < 100 && file.readAsStringSync().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(_readLines(file).single['e'], 'late');
      await log.finish('stop');
      expect(_readLines(file).map((l) => l['e']), ['late', 'stop']);
    });

    test('stops growing at the cap but still writes the stop line', () async {
      final log = DiagEventLog(
        name: 'ride_3',
        resolveDirectory: () async => dir,
        maxBytes: 300,
      )..begin();
      for (var i = 0; i < 50; i++) {
        log.add('late', {'lateMs': i});
      }
      await log.finish('stop');
      final file = _diagFile(dir, 'ride_3.jsonl');
      final lines = _readLines(file);
      expect(lines.where((l) => l['e'] == 'capped'), hasLength(1));
      expect(lines.last['e'], 'stop');
      expect(lines.length, lessThan(10));
      expect(file.lengthSync(), lessThan(400));
    });

    test('an I/O error disables it and finish still completes', () async {
      // A file where the diag directory should be.
      File('${dir.path}${_sep}diag').writeAsStringSync('blocker');
      final log = DiagEventLog(
        name: 'ride_4',
        resolveDirectory: () async => dir,
      )..begin();
      log.add('late', {'lateMs': 70});
      log.flush();
      await log.finish('stop');
      expect(log.isDisabled, isTrue);
      log.add('late', {'lateMs': 80});
      await log.finish('stop');
    });

    test('a failing directory resolver is tolerated', () async {
      final log = DiagEventLog(
        name: 'ride_5',
        resolveDirectory: () async => throw const FileSystemException('none'),
      )..begin();
      log.add('start');
      await log.finish('stop');
      expect(log.isDisabled, isTrue);
    });
  });

  group('RecordingDiagSession', () {
    test('logs a late main-isolate tick and the control stall', () async {
      final session = RecordingDiagSession(
        rideSessionId: 'ride_6',
        switches: const DiagSwitches(controlStall: true),
        resolveDirectory: () async => dir,
        controlStallDelay: const Duration(milliseconds: 50),
        controlStall: (ms) async => <Object?, Object?>{
          'startMs': 1000,
          'endMs': 1000 + ms,
        },
      )..begin();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      // Block this isolate for 300 ms: the next tick is about 200 ms late.
      final busy = Stopwatch()..start();
      while (busy.elapsedMilliseconds < 300) {}
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await session.finish();

      final lines = _readLines(_diagFile(dir, 'ride_6.jsonl'));
      expect(lines.first['e'], 'start');
      expect(lines.first['controlStall'], isTrue);
      expect(lines.first['skipPrehash'], isFalse);
      expect(lines.last['e'], 'stop');
      final late = lines.where((l) => l['e'] == 'late').toList();
      expect(late, isNotEmpty);
      expect(
        late.map((l) => l['lateMs'] as int).reduce((a, b) => a > b ? a : b),
        greaterThanOrEqualTo(150),
      );
      final stall = lines.singleWhere((l) => l['e'] == 'controlStall');
      expect(stall['requestMs'], 1500);
      expect(stall['startMs'], 1000);
      expect(stall['endMs'], 2500);
    });

    test('a failing control stall call is logged, never thrown', () async {
      final session = RecordingDiagSession(
        rideSessionId: 'ride_7',
        switches: const DiagSwitches(controlStall: true),
        resolveDirectory: () async => dir,
        controlStallDelay: const Duration(milliseconds: 10),
        controlStall: (ms) async => throw Exception('no channel'),
      )..begin();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await session.finish();
      final stall = _readLines(
        _diagFile(dir, 'ride_7.jsonl'),
      ).singleWhere((l) => l['e'] == 'controlStall');
      expect(stall['error'], contains('no channel'));
    });
  });

  group('TelemetryProvider roll diagnostics', () {
    late Directory storage;
    late TelemetryProvider provider;
    var calls = 0;

    setUp(() {
      storage = Directory(
        '${dir.path}${_sep}storage${_sep}MotoCam${_sep}Recordings',
      )..createSync(recursive: true);
      calls = 0;
    });

    tearDown(() {
      provider.dispose();
    });

    TelemetryProvider create({bool enabled = true}) =>
        provider = TelemetryProvider(
          sampleInterval: const Duration(seconds: 1),
          rollDiagEnabled: enabled,
          diagDirectory: () async => dir,
          diagControlStall: (ms) async {
            calls++;
            return null;
          },
        );

    Future<File> segment(String name) async {
      final file = File('${storage.path}$_sep$name');
      await file.writeAsString('video-$name', flush: true);
      return file;
    }

    Future<List<Map<String, dynamic>>> endAndRead(String id) async {
      provider.cancelRideSession();
      await provider.diagLogClosedForTesting;
      return _readLines(_diagFile(dir, '$id.jsonl'));
    }

    test('disabled: switches read as off and no log is written', () async {
      _touchSwitch(dir, DiagSwitches.skipPrehashFile);
      create(enabled: false);
      final switches = await provider.readDiagSwitches();
      expect(switches, DiagSwitches.off);
      provider.startRideSession(diagSwitches: switches);
      final id = provider.rideSessionId!;
      provider.cancelRideSession();
      await provider.diagLogClosedForTesting;
      expect(_diagFile(dir, '$id.jsonl').existsSync(), isFalse);
    });

    test(
      'switches are read once at start and hold for the whole ride',
      () async {
        _touchSwitch(dir, DiagSwitches.skipPrehashFile);
        create();
        final switches = await provider.readDiagSwitches();
        provider.startRideSession(diagSwitches: switches);
        final id = provider.rideSessionId!;
        // Removing the file mid-ride changes nothing.
        _diagFile(dir, DiagSwitches.skipPrehashFile).deleteSync();
        expect(provider.diagSwitches.skipPrehash, isTrue);

        final first = await segment('seg_1.mp4');
        final path = await provider.checkpointRideSession(
          segmentPaths: [first.path],
        );
        // Nothing hashed, so the checkpoint lists no segment and is not
        // written.
        expect(path, isNull);
        expect(provider.diagSwitches.skipPrehash, isTrue);

        final lines = await endAndRead(id);
        expect(lines.first['e'], 'start');
        expect(lines.first['ride'], id);
        expect(lines.first['skipPrehash'], isTrue);
        expect(lines.first['skipCheckpoint'], isFalse);
        expect(lines.where((l) => l['e'] == 'prehashStart'), isEmpty);
        final end = lines.singleWhere((l) => l['e'] == 'checkpointEnd');
        expect(end['wrote'], isFalse);
        expect(lines.last['e'], 'stop');
        expect(provider.diagSwitches, DiagSwitches.off);
        expect(calls, 0);
      },
    );

    test(
      'without switches a roll logs the prehash and the checkpoint',
      () async {
        create();
        provider.startRideSession(
          diagSwitches: await provider.readDiagSwitches(),
        );
        final id = provider.rideSessionId!;
        final first = await segment('seg_1.mp4');
        final path = await provider.checkpointRideSession(
          segmentPaths: [first.path],
        );
        expect(path, isNotNull);

        final lines = await endAndRead(id);
        final events = lines.map((l) => l['e']).toList();
        expect(
          events,
          containsAllInOrder([
            'start',
            'checkpointStart',
            'prehashStart',
            'prehashEnd',
            'checkpointEnd',
            'stop',
          ]),
        );
        final start = lines.singleWhere((l) => l['e'] == 'prehashStart');
        expect(start['files'], 1);
        expect(start['bytes'], first.lengthSync());
        expect(lines.singleWhere((l) => l['e'] == 'prehashEnd')['hashed'], 1);
        final end = lines.singleWhere((l) => l['e'] == 'checkpointEnd');
        expect(end['wrote'], isTrue);
        expect(end['durMs'] as int, greaterThanOrEqualTo(end['waitMs'] as int));
      },
    );

    test('a skipped checkpoint is noted in the log', () async {
      _touchSwitch(dir, DiagSwitches.skipCheckpointFile);
      create();
      provider.startRideSession(
        diagSwitches: await provider.readDiagSwitches(),
      );
      final id = provider.rideSessionId!;
      expect(provider.diagSwitches.skipCheckpoint, isTrue);
      provider.noteDiagCheckpointSkipped(2);
      final lines = await endAndRead(id);
      expect(
        lines.singleWhere((l) => l['e'] == 'checkpointSkipped')['segments'],
        2,
      );
    });
  });
}
