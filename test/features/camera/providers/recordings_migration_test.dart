// The move of rides from the legacy recordings roots into the private root:
// rides moved as units from each root, collisions, the free-space stop,
// pause and resume, a kill at each fault point, and the sweepers running in
// the middle of a move.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/core/ride_file/ride_telemetry_codec.dart';
import 'package:motocam/core/utils/integrity_utils.dart';
import 'package:motocam/core/utils/path_utils.dart' as path_utils;
import 'package:motocam/features/camera/providers/recording_retention.dart';
import 'package:motocam/features/camera/providers/recordings_migration.dart';
import 'package:motocam/features/history/models/ride_history_loader.dart';
import 'package:motocam/features/history/models/ride_record.dart';

import '../../../support/test_signing_key.dart';

/// Thrown by a fault hook to simulate the process being killed.
class _Killed implements Exception {
  const _Killed(this.point);
  final RecordingsMigrationFault point;
  @override
  String toString() => 'killed at $point';
}

void main() {
  final sep = Platform.pathSeparator;
  final phone = TestSigningKey.generate(7);
  late Directory base;
  late String root;
  late String work;
  late String external;
  late String documents;
  late String cache;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('motocam_migration_');
    root = '${base.path}${sep}support${sep}MotoCam Recordings';
    work = '${base.path}${sep}support${sep}ride_migration';
    external = '${base.path}${sep}external${sep}MotoCam Recordings';
    documents = '${base.path}${sep}documents${sep}MotoCam Recordings';
    cache = '${base.path}${sep}cache${sep}MotoCam Recordings';
    for (final directory in <String>[root, external, documents, cache]) {
      await Directory(directory).create(recursive: true);
    }
  });

  tearDown(() async {
    if (await base.exists()) {
      await base.delete(recursive: true);
    }
  });

  RideSignerContext signerContext(Set<String> ids, Set<String> segments) =>
      RideSignerContext(
        thisDevicePublicKey: phone.publicKeyBase64,
        signedRideIds: ids,
        signedTelemetryFileNames: <String>{
          for (final id in ids) rideTelemetryFileNameFor(id),
        },
        signedSegmentFileNames: segments,
      );

  /// The external root is on another file system: renames out of it fail,
  /// so its files take the copy path.
  Future<void> crossMountRename(String from, String to) async {
    if (path_utils.isPathInsideDirectory(from, external)) {
      throw FileSystemException('Invalid cross-device link', from);
    }
    await File(from).rename(to);
  }

  RecordingsMigrator migrator({
    List<String>? legacyRoots,
    RecordingsMigrationFaultHook? fault,
    bool Function()? shouldPause,
    Future<int?> Function(String path)? freeBytes,
    int reserveBytes = 0,
    int copyChunkBytes = 1024 * 1024,
  }) => RecordingsMigrator(
    recordingsRoot: root,
    legacyRoots: legacyRoots ?? <String>[external, documents, cache],
    workDirectory: work,
    freeBytes: freeBytes ?? (_) async => null,
    reserveBytes: reserveBytes,
    shouldPause: shouldPause,
    renameFile: crossMountRename,
    debugFault: fault,
    copyChunkBytes: copyChunkBytes,
  );

  /// Writes ride `ride_<id>` into [directory]: [segments] videos (each
  /// `video-<id>-<n>` repeated), one more declared segment that is missing,
  /// absolute paths as the app writes them, the first segment locked
  /// unless [locked] is false, signed by the phone key when [signed].
  Future<File> writeRide(
    String directory,
    String id, {
    int segments = 2,
    bool locked = true,
    bool signed = true,
    int videoBytes = 64,
  }) async {
    final paths = <String>[];
    final hashes = <String, String>{};
    for (var n = 1; n <= segments; n++) {
      final file = File('$directory${sep}seg_${id}_$n.mp4');
      final unit = 'video-$id-$n|';
      await file.writeAsString(
        (unit * (videoBytes ~/ unit.length + 1)).substring(0, videoBytes),
        flush: true,
      );
      paths.add(file.path);
      hashes[file.path] = (await hashFileSha256(file.path))!;
    }
    final missing = '$directory${sep}seg_${id}_gone.mp4';
    final declared = <String>[...paths, missing];
    final payload = <String, dynamic>{
      'schemaVersion': 3,
      'rideSessionId': id,
      'sessionComplete': true,
      'storageDirectory': directory,
      'videoPath': paths.isEmpty ? missing : paths.last,
      'segmentPaths': declared,
      'lockedSegmentPaths': locked
          ? <String>[paths.isEmpty ? missing : paths.first]
          : <String>[],
      'segmentTimeline': <Map<String, dynamic>>[
        for (var i = 0; i < declared.length; i++)
          <String, dynamic>{
            'path': declared[i],
            'startMs': i * 1000,
            'endMs': i * 1000 + 900,
          },
      ],
      'startedAt': '2026-05-03T10:00:00.000Z',
      'distanceKm': 1.5,
      'maxSpeedKmh': 40.0,
      'averageSpeedKmh': 20.0,
      'samples': <Map<String, dynamic>>[
        <String, dynamic>{
          'elapsedMs': 0,
          'speed': 10.0,
          'timestamp': '2026-05-03T10:00:00Z',
        },
      ],
    };
    final sealed = await sealAndSignRidePayload(
      payload,
      segmentHashes: hashes,
      segmentCount: declared.length,
      generatedAt: DateTime.utc(2026, 5, 3),
      signer: signed ? phone.signer : null,
    );
    final file = File('$directory${sep}ride_$id.telemetry.json');
    await file.writeAsString(jsonEncode(sealed.json), flush: true);
    return file;
  }

  String digest(String path) =>
      sha256.convert(File(path).readAsBytesSync()).toString();

  /// Content digest of every file in [directory] by file name.
  Map<String, String> contents(String directory) {
    final dir = Directory(directory);
    if (!dir.existsSync()) {
      return const <String, String>{};
    }
    return <String, String>{
      for (final entity in dir.listSync())
        if (entity is File)
          path_utils.fileNameFromPath(entity.path): digest(entity.path),
    };
  }

  List<String> namesIn(String directory) =>
      contents(directory).keys.toList()..sort();

  String name(String path) => path_utils.fileNameFromPath(path);

  /// What the rider sees of a ride, independent of its directory.
  Future<Map<String, Object?>> describe(
    File telemetryFile,
    RideSignerContext context,
  ) async {
    final lazy = (await RideRecord.fromTelemetryFile(
      telemetryFile,
    ))!.withSignerContext(context);
    final deep = (await RideRecord.fromTelemetryFile(
      telemetryFile,
      verifySegments: true,
    ))!.withSignerContext(context);
    final directory = telemetryFile.parent.path;
    List<String> issues(RideRecord ride) => <String>[
      for (final issue in ride.integrity.issues)
        issue.replaceAll('$directory$sep', '<dir>/'),
    ];
    return <String, Object?>{
      'segments': lazy.segmentPaths.map(name).toList(),
      'missing': lazy.missingSegmentPaths.map(name).toList(),
      'quarantined': lazy.quarantinedSegmentPaths,
      'locked': lazy.lockedSegmentPaths.map(name).toList(),
      'isLocked': lazy.isLocked,
      'timeline': <List<Object>>[
        for (final entry in lazy.segmentTimeline)
          <Object>[name(entry.path), entry.startMs, entry.endMs],
      ],
      'status': lazy.integrity.status.name,
      'issues': issues(lazy),
      'signedBy': lazy.integrity.signedBy.name,
      'deepStatus': deep.integrity.status.name,
      'deepIssues': issues(deep),
      'deepSignedBy': deep.integrity.signedBy.name,
      'allInDirectory': lazy.segmentPaths.every(
        (path) => path_utils.isPathInsideDirectory(path, directory),
      ),
    };
  }

  group('moving rides', () {
    for (final which in <String>['external', 'documents', 'cache']) {
      test('a signed, locked ride moved from the $which root reads '
          'identically', () async {
        final legacy = switch (which) {
          'external' => external,
          'documents' => documents,
          _ => cache,
        };
        await File('$legacy$sep.nomedia').create();
        final original = await writeRide(legacy, 'ride-$which');
        final context = signerContext(
          <String>{'ride-$which'},
          <String>{'seg_ride-${which}_1.mp4', 'seg_ride-${which}_2.mp4'},
        );
        final before = await describe(original, context);
        expect(before['signedBy'], RideSignedBy.thisDevice.name);
        expect(before['status'], RideIntegrityStatus.verified.name);
        expect(before['deepStatus'], RideIntegrityStatus.verified.name);
        expect(before['missing'], <String>['seg_ride-${which}_gone.mp4']);
        final originalContents = contents(legacy)..remove('.nomedia');

        final summary = await migrator().run();

        expect(summary.outcome, RecordingsMigrationOutcome.completed);
        expect(summary.moved, 1);
        expect(summary.skipped, isEmpty);
        expect(summary.shouldNotify, isTrue);
        expect(summary.message, 'Moved 1 ride to private storage.');
        // Byte for byte, and the emptied legacy root is gone.
        expect(contents(root), originalContents);
        expect(Directory(legacy).existsSync(), isFalse);
        final moved = File('$root$sep${name(original.path)}');
        expect(await describe(moved, context), <String, Object?>{...before});
        // Staging is empty and the journal names no ride in flight.
        expect(
          Directory('$work${sep}staging').existsSync()
              ? Directory('$work${sep}staging').listSync()
              : const <FileSystemEntity>[],
          isEmpty,
        );
        final journal =
            jsonDecode(
                  File(
                    '$work$sep$recordingsMigrationJournalFileName',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(journal['ride'], isNull);
      });
    }

    test('a moved ride with its source copy still in place reads from the '
        'moved files', () async {
      final original = await writeRide(external, 'twin');
      final context = signerContext(<String>{'twin'}, const <String>{});
      final before = await describe(original, context);
      // Copy, as an interrupted move or an import leaves it.
      for (final entry in contents(external).keys) {
        await File('$external$sep$entry').copy('$root$sep$entry');
      }
      final moved = File('$root$sep${name(original.path)}');
      final after = await describe(moved, context);
      expect(after, before);
      expect(after['allInDirectory'], isTrue);
    });

    test('lone videos move; ignored files and other files stay', () async {
      await File('$documents$sep.nomedia').create();
      await File('$documents${sep}lone.mp4').writeAsString('lone video');
      await File('$documents$sep$recordingsWriteProbeFileName').create();
      await File(
        '$documents${sep}ride_x.telemetry.json.123.tmp',
      ).writeAsString('{');
      await File('$documents${sep}notes.txt').writeAsString('mine');

      final summary = await migrator().run();

      expect(summary.moved, 1);
      expect(namesIn(root), <String>['lone.mp4']);
      expect(namesIn(documents), <String>[
        '.__motocam_write_probe.tmp',
        '.nomedia',
        'notes.txt',
        'ride_x.telemetry.json.123.tmp',
      ]);
    });

    test('an unlocked ride without videos stays where it is', () async {
      final ride = await writeRide(cache, 'empty', segments: 0, locked: false);
      final summary = await migrator().run();
      expect(summary.moved, 0);
      expect(
        summary.skipped.single.reason,
        RecordingsMigrationSkipReason.noVideoFiles,
      );
      expect(summary.skipped.single.name, name(ride.path));
      expect(await ride.exists(), isTrue);
      expect(namesIn(root), isEmpty);
      expect(summary.shouldNotify, isTrue);
      expect(
        summary.message,
        '1 ride left in the old folder (no video files are left).',
      );

      // Reported once only.
      final again = await migrator().run();
      expect(again.skipped, hasLength(1));
      expect(again.shouldNotify, isFalse);
    });

    test('a locked ride without videos moves', () async {
      final ride = await writeRide(cache, 'lockedEmpty', segments: 0);
      final expected = contents(cache);
      final summary = await migrator().run();
      expect(summary.moved, 1);
      expect(contents(root), expected);
      expect(await ride.exists(), isFalse);
    });

    test(
      'a ride whose videos already moved is finished, not skipped',
      () async {
        final ride = await writeRide(documents, 'half', locked: false);
        for (final video in <String>['seg_half_1.mp4', 'seg_half_2.mp4']) {
          await File('$documents$sep$video').rename('$root$sep$video');
        }
        final summary = await migrator().run();
        expect(summary.moved, 1);
        expect(summary.skipped, isEmpty);
        expect(await ride.exists(), isFalse);
        expect(namesIn(root), hasLength(3));
      },
    );
  });

  group('collisions', () {
    test('a same-named file of the same size counts as moved', () async {
      final ride = await writeRide(external, 'same');
      for (final entry in contents(external).keys) {
        await File('$external$sep$entry').copy('$root$sep$entry');
      }
      final expected = contents(external);

      final summary = await migrator().run();

      expect(summary.moved, 1);
      expect(contents(root), expected);
      expect(await ride.exists(), isFalse);
    });

    test('a same-named video of another size skips the whole ride', () async {
      final ride = await writeRide(external, 'clash');
      final expected = contents(external);
      await File('$root${sep}seg_clash_2.mp4').writeAsString('other');

      final summary = await migrator().run();

      expect(summary.moved, 0);
      expect(
        summary.skipped.single.reason,
        RecordingsMigrationSkipReason.nameCollision,
      );
      expect(summary.skipped.single.name, name(ride.path));
      expect(contents(external), expected);
      expect(namesIn(root), <String>['seg_clash_2.mp4']);
      expect(Directory(external).existsSync(), isTrue);
      expect(summary.message, contains('same name'));
    });

    test('a same-named JSON of the same size but other bytes is a '
        'collision', () async {
      final ride = await writeRide(documents, 'bytes');
      final text = await ride.readAsString();
      final altered = text.replaceFirst('"distanceKm":1.5', '"distanceKm":2.5');
      expect(altered.length, text.length);
      await File('$root$sep${name(ride.path)}').writeAsString(altered);

      final summary = await migrator().run();

      expect(
        summary.skipped.single.reason,
        RecordingsMigrationSkipReason.nameCollision,
      );
      expect(await ride.readAsString(), text);
      expect(namesIn(documents), contains('seg_bytes_1.mp4'));
    });
  });

  group('free space', () {
    test('stops before a copy that does not fit and leaves the rest', () async {
      await writeRide(external, 'big', videoBytes: 4096);
      final expected = contents(external);
      final queried = <String>[];

      final summary = await migrator(
        freeBytes: (path) async {
          queried.add(path);
          return 5000;
        },
        reserveBytes: 2000,
      ).run();

      expect(summary.outcome, RecordingsMigrationOutcome.lowStorage);
      expect(summary.moved, 0);
      expect(summary.remaining, 1);
      expect(summary.shouldNotify, isTrue);
      expect(
        summary.message,
        'Not enough free space for the remaining 1 ride, which stays in the '
        'old folder.',
      );
      expect(queried, everyElement(root));
      expect(contents(external), expected);
      expect(namesIn(root), isEmpty);
      expect(
        Directory('$work${sep}staging').existsSync()
            ? Directory('$work${sep}staging').listSync()
            : const <FileSystemEntity>[],
        isEmpty,
      );
    });

    test('renames need no free space', () async {
      await writeRide(documents, 'rename', videoBytes: 4096);
      final summary = await migrator(
        freeBytes: (_) async => 0,
        reserveBytes: 1 << 30,
      ).run();
      expect(summary.moved, 1);
    });
  });

  group('pause and resume', () {
    test('a copy in flight is abandoned and resumes later', () async {
      final ride = await writeRide(external, 'pause', videoBytes: 256);
      final expected = contents(external);
      var pause = false;
      var chunks = 0;
      final progress = <RecordingsMigrationProgress>[];

      final first = await migrator(
        copyChunkBytes: 16,
        shouldPause: () {
          // Pauses in the middle of the first video's copy.
          if (Directory('$work${sep}staging').existsSync() && ++chunks > 4) {
            pause = true;
          }
          return pause;
        },
      ).run(onProgress: progress.add);

      expect(first.outcome, RecordingsMigrationOutcome.paused);
      expect(contents(external), expected);
      expect(namesIn(root), isEmpty);
      expect(Directory('$work${sep}staging').listSync(), isEmpty);
      expect(
        progress.last.inFlightPaths,
        contains(path_utils.normalizePath(ride.path)),
      );
      final journal =
          jsonDecode(
                File(
                  '$work$sep$recordingsMigrationJournalFileName',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect((journal['ride'] as Map)['telemetry'], ride.path);

      final second = await migrator().run();
      expect(second.outcome, RecordingsMigrationOutcome.completed);
      expect(second.moved, 1);
      expect(contents(root), expected);
    });

    test('a pause before the first ride moves nothing', () async {
      await writeRide(documents, 'early');
      final expected = contents(documents);
      final summary = await migrator(shouldPause: () => true).run();
      expect(summary.outcome, RecordingsMigrationOutcome.paused);
      expect(summary.remaining, 1);
      expect(contents(documents), expected);
    });
  });

  group('a kill at each fault point', () {
    for (final point in RecordingsMigrationFault.values) {
      for (final which in <String>['external', 'documents']) {
        test('$point on the $which root rolls forward', () async {
          final legacy = which == 'external' ? external : documents;
          await writeRide(legacy, 'kill');
          await File('$legacy${sep}lone.mp4').writeAsString('lone video');
          final expected = contents(legacy);
          var hits = 0;

          // Kill at the second time the point is reached, so some files
          // have already moved.
          Future<void> killed() => migrator(
            fault: (hit, path) {
              if (hit == point && ++hits == 2) {
                throw _Killed(point);
              }
            },
          ).run();

          final reached =
              point == RecordingsMigrationFault.beforeCopy ||
              point == RecordingsMigrationFault.duringJournalWrite ||
              which == 'external';
          if (reached) {
            await expectLater(killed(), throwsA(isA<_Killed>()));
          } else {
            // A rename never reaches the copy points.
            await killed();
          }

          // No file is only in staging: each one is whole in a root.
          final union = <String, String>{
            ...contents(legacy),
            ...contents(root),
          };
          expect(union, expected);
          for (final entry in contents(root).entries) {
            expect(expected[entry.key], entry.value);
          }

          final resumed = await migrator().run();
          expect(resumed.outcome, RecordingsMigrationOutcome.completed);
          expect(contents(root), expected);
          expect(Directory(legacy).existsSync(), isFalse);
          final staging = Directory('$work${sep}staging');
          expect(staging.existsSync() ? staging.listSync() : const [], isEmpty);
          expect(
            File(
              '$work$sep$recordingsMigrationJournalFileName.new',
            ).existsSync(),
            isFalse,
          );
        });
      }
    }

    test('a truncated staging copy never deletes the source', () async {
      final ride = await writeRide(external, 'short');
      final expected = contents(external);
      final summary = await migrator(
        fault: (point, path) {
          if (point == RecordingsMigrationFault.afterCopyBeforeRename) {
            final file = File(path);
            final bytes = file.readAsBytesSync();
            file.writeAsBytesSync(bytes.sublist(0, bytes.length - 1));
          }
        },
      ).run();
      expect(summary.moved, 0);
      expect(
        summary.skipped.single.reason,
        RecordingsMigrationSkipReason.copyFailed,
      );
      expect(summary.skipped.single.name, name(ride.path));
      expect(contents(external), expected);
      expect(namesIn(root), isEmpty);
    });
  });

  group('sweepers during a move', () {
    test('staging names are not telemetry temp files, rides or videos', () {
      for (final staged in <String>[
        'ride_a.telemetry.json$recordingsMigrationStagingSuffix',
        'seg.mp4$recordingsMigrationStagingSuffix',
      ]) {
        expect(isTelemetryTempFilePath(staged), isFalse);
        expect(staged.endsWith(rideTelemetryFileSuffix), isFalse);
        expect(RideRecord.isVideoFilePath(staged), isFalse);
      }
    });

    test('the work directory may not lie inside a scanned root', () {
      expect(
        () => RecordingsMigrator(
          recordingsRoot: root,
          legacyRoots: <String>[external],
          workDirectory: '$root${sep}ride_migration',
          freeBytes: (_) async => null,
          reserveBytes: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => RecordingsMigrator(
          recordingsRoot: root,
          legacyRoots: <String>[external],
          workDirectory: '$external${sep}ride_migration',
          freeBytes: (_) async => null,
          reserveBytes: 0,
        ),
        throwsArgumentError,
      );
    });

    test('the orphan prune, the temp prune, loop retention and the history '
        'scan delete or show nothing they should not', () async {
      final unlocked = await writeRide(external, 'sweep', locked: false);
      await writeRide(documents, 'sweepDocs', locked: false);
      final expected = <String, String>{
        ...contents(external),
        ...contents(documents),
      };
      // A session being recorded in the new root.
      final session = <String>[
        for (var n = 1; n <= 3; n++) '$root${sep}REC$n.mp4',
      ];
      for (final path in session) {
        await File(path).writeAsString('session');
      }
      final checks = <RecordingsMigrationFault>[];

      Future<void> sweep(RecordingsMigrationFault point) async {
        checks.add(point);
        // The deferred orphan prune only scans the new root.
        expect(findOrphanTelemetryFiles(root), isEmpty);
        // The startup temp prune: nothing in the root or in staging.
        expect(
          await pruneStaleTelemetryTempFiles(
            Directory(root),
            olderThan: Duration.zero,
          ),
          0,
        );
        expect(
          await pruneStaleTelemetryTempFiles(
            Directory('$work${sep}staging'),
            olderThan: Duration.zero,
          ),
          0,
        );
        // Loop retention evicts only the session's own segments.
        final listing = <String>[
          for (final directory in <String>[root, external, documents])
            if (Directory(directory).existsSync())
              for (final entity in Directory(directory).listSync()) entity.path,
        ];
        expect(
          selectSegmentsToEvict(
            sessionPaths: session,
            lockedPaths: const <String>{},
            maxUnlockedSegments: 1,
          ),
          session.sublist(0, 2),
        );
        // The history scan never sees a staging file.
        expect(
          listing.where(
            (path) => path.endsWith(recordingsMigrationStagingSuffix),
          ),
          isEmpty,
        );
        final rides = await loadRideHistory(listing);
        expect(
          rides.expand((ride) => ride.segmentPaths),
          everyElement(isNot(endsWith(recordingsMigrationStagingSuffix))),
        );
      }

      // The migration waits for the checks at each point.
      final summary = await migrator(fault: (point, _) => sweep(point)).run();

      expect(checks, isNotEmpty);
      expect(summary.moved, 2);
      for (final entry in expected.entries) {
        expect(contents(root)[entry.key], entry.value);
      }
      expect(await File('$root$sep${name(unlocked.path)}').exists(), isTrue);
      expect(findOrphanTelemetryFiles(root), isEmpty);
    });
  });

  group('controller', () {
    test('reports progress, idleness and a summary once', () async {
      await writeRide(documents, 'ui');
      final controller = RecordingsMigrationController();
      final banners = <String?>[];
      controller.addListener(() => banners.add(controller.bannerText));
      expect(controller.isIdle, isTrue);

      controller.start(migrator());
      expect(controller.isIdle, isFalse);
      await controller.whenIdle();

      expect(controller.isIdle, isTrue);
      expect(controller.isFinished, isTrue);
      expect(banners, contains('Moving 1 ride to private storage (1 of 1)'));
      expect(controller.bannerText, isNull);
      expect(controller.notice, 'Moved 1 ride to private storage.');
      expect(controller.inFlightPaths, isEmpty);
      controller.dismissNotice();
      expect(controller.notice, isNull);

      // A finished migration does not run again in this process.
      controller.start(migrator());
      expect(controller.isIdle, isTrue);
    });

    test('a paused run can start again', () async {
      await writeRide(documents, 'again');
      final controller = RecordingsMigrationController();
      controller.start(migrator(shouldPause: () => true));
      await controller.whenIdle();
      expect(controller.isFinished, isFalse);
      expect(controller.notice, isNull);
      controller.start(migrator());
      await controller.whenIdle();
      expect(controller.isFinished, isTrue);
      expect(controller.lastSummary!.moved, 1);
    });
  });
}
