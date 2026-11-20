// Ride export: clip selection, folder naming, the export source, the
// folder run and the share over a fake native side that writes into a
// temp dir, manifest.json, MOTOCAM-EXPORT.txt and the rider's summary.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/ride_file/ride_telemetry_codec.dart';
import 'package:motocam/core/services/ride_export_channel.dart';
import 'package:motocam/core/utils/format_utils.dart';
import 'package:motocam/core/utils/integrity_utils.dart';
import 'package:motocam/features/history/models/ride_index.dart';
import 'package:motocam/features/history/models/ride_record.dart';
import 'package:motocam/features/history/services/ride_export.dart';

import '../../../support/test_signing_key.dart';

final String _sep = Platform.pathSeparator;

/// A native side whose "tree" is a temp directory.
class _FakeNative implements RideExportNative {
  _FakeNative(this.treeRoot);

  final Directory treeRoot;

  /// `prepare`, `export:<name>`, `hash:<name>`,
  /// `trim:<name>:<startUs>-<endUs>`, `share`, `cancel`.
  final List<String> calls = <String>[];

  /// Names copied with `replace: true`.
  final List<String> replaced = <String>[];

  /// File name (`trim:<name>` for a trim) -> error code thrown by
  /// [exportFile], [hashFile] or [trimClip].
  final Map<String, String> fail = <String, String>{};

  /// Trims made so far; each trim writes different bytes, like MediaMuxer.
  int trims = 0;

  /// Clip name -> the `lastUs` its trim reports (default: `endUs`, a
  /// sample on the end).
  final Map<String, int> lastUs = <String, int>{};

  /// Error code thrown by [prepareFolder], if any.
  String? failPrepare;

  /// File names whose copy reads back different (`COPY_MISMATCH`).
  final Set<String> mismatch = <String>{};

  /// File names (`trim:<name>` for a trim) that take a while (cancellable).
  final Set<String> slow = <String>{};

  /// Called with the file name (`trim:<name>` for a trim) at the start of
  /// each copy, hash or trim.
  void Function(String name)? during;

  /// Whether copies report `synced`.
  bool synced = true;

  /// Whether the share sheet opens.
  bool shareOpens = true;

  /// Paths handed to [shareFiles].
  List<String>? sharedPaths;

  /// MIME types handed to [shareFiles].
  List<String>? sharedMimeTypes;

  bool _cancelled = false;

  static String _hash(List<int> bytes) => sha256.convert(bytes).toString();

  Future<void> _work(String name) async {
    during?.call(name);
    if (slow.contains(name)) {
      for (var i = 0; i < 400; i++) {
        if (_cancelled) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
    if (_cancelled) {
      throw const RideExportCancelled();
    }
    final code = fail[name];
    if (code != null) {
      throw RideExportFailure(code, 'fake');
    }
  }

  @override
  Future<String?> pickExportFolder() async => treeRoot.path;

  @override
  Future<String> prepareFolder({
    required String treeUri,
    required String name,
    required List<String> expectedNames,
  }) async {
    calls.add('prepare');
    final code = failPrepare;
    if (code != null) {
      throw RideExportFailure(code);
    }
    final folder = Directory('$treeUri$_sep$name');
    await folder.create(recursive: true);
    for (final entity in folder.listSync()) {
      final fileName = entity.uri.pathSegments.last;
      if (!expectedNames.contains(fileName)) {
        throw const RideExportFailure('FOLDER_NOT_EMPTY');
      }
    }
    for (final name in <String>['manifest.json', 'MOTOCAM-EXPORT.txt']) {
      final old = File('${folder.path}$_sep$name');
      if (old.existsSync()) {
        old.deleteSync();
      }
    }
    return folder.path;
  }

  @override
  Future<RideExportedFile> exportFile({
    required String folderUri,
    required String sourcePath,
    required String name,
    required String mimeType,
    bool replace = false,
  }) async {
    _cancelled = false;
    calls.add('export:$name');
    if (replace) {
      replaced.add(name);
    }
    await _work(name);
    final source = File(sourcePath);
    if (!source.existsSync()) {
      throw const RideExportFailure('SOURCE_NOT_FOUND');
    }
    final bytes = source.readAsBytesSync();
    final sourceHash = _hash(bytes);
    final target = File('$folderUri$_sep$name');
    if (replace && target.existsSync()) {
      target.deleteSync();
    }
    if (target.existsSync()) {
      final existing = target.readAsBytesSync();
      if (existing.length == bytes.length) {
        if (_hash(existing) == sourceHash) {
          return RideExportedFile(
            bytes: bytes.length,
            sourceSha256: sourceHash,
            copySha256: sourceHash,
            skipped: true,
            synced: synced,
          );
        }
        throw RideExportFailure('EXISTS_DIFFERENT', name);
      }
      target.deleteSync();
    }
    target.writeAsBytesSync(bytes);
    if (mismatch.contains(name)) {
      target.deleteSync();
      throw const RideExportFailure('COPY_MISMATCH');
    }
    return RideExportedFile(
      bytes: bytes.length,
      sourceSha256: sourceHash,
      copySha256: _hash(target.readAsBytesSync()),
      skipped: false,
      synced: synced,
    );
  }

  @override
  Future<RideHashedFile> hashFile(String path) async {
    _cancelled = false;
    final name = path.split(_sep).last;
    calls.add('hash:$name');
    await _work(name);
    final file = File(path);
    if (!file.existsSync()) {
      throw const RideExportFailure('SOURCE_NOT_FOUND');
    }
    final bytes = file.readAsBytesSync();
    return RideHashedFile(bytes: bytes.length, sha256: _hash(bytes));
  }

  /// Writes `trim<n>:<startUs>-<endUs>:` and the source to [targetPath];
  /// the start snaps back to a 0.7 s keyframe grid.
  @override
  Future<RideTrimmedClip> trimClip({
    required String sourcePath,
    required String targetPath,
    required int startUs,
    required int endUs,
  }) async {
    _cancelled = false;
    final name = sourcePath.split(_sep).last;
    calls.add('trim:$name:$startUs-$endUs');
    if (!targetPath.contains('${_sep}ride_export$_sep')) {
      throw const RideExportFailure('INVALID_ARGS');
    }
    final target = File(targetPath);
    if (target.existsSync()) {
      throw const RideExportFailure('INVALID_ARGS', 'target exists');
    }
    target.writeAsStringSync('partial');
    try {
      await _work('trim:$name');
    } catch (_) {
      target.deleteSync();
      rethrow;
    }
    final source = File(sourcePath);
    trims++;
    target.writeAsStringSync(
      'trim$trims:$startUs-$endUs:${source.readAsStringSync()}',
    );
    return RideTrimmedClip(
      bytes: target.lengthSync(),
      firstUs: startUs ~/ 700000 * 700000,
      lastUs: lastUs[name] ?? endUs,
    );
  }

  @override
  Future<void> cancel() async {
    calls.add('cancel');
    _cancelled = true;
  }

  @override
  Future<bool> shareFiles({
    required List<String> paths,
    required List<String> mimeTypes,
    required String subject,
  }) async {
    calls.add('share');
    sharedPaths = paths;
    sharedMimeTypes = mimeTypes;
    return shareOpens;
  }

  @override
  Future<void> setKeepScreenOn(bool enabled) async {}
}

/// How a test ride is sealed.
enum _Seal { none, v1, v2, v3 }

/// The README with runs of whitespace (including the wrap) as one space.
String _flat(String text) => text.replaceAll(RegExp(r'\s+'), ' ');

String _two(int value) => value.toString().padLeft(2, '0');

void main() {
  late Directory temp;
  late Directory rides;
  late Directory tree;
  late Directory cache;
  final phone = TestSigningKey.generate(1);
  final exportedAt = DateTime.utc(2026, 11, 19, 13, 5);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('motocam_ride_export_');
    rides = Directory('${temp.path}${_sep}MotoCam Recordings')..createSync();
    tree = Directory('${temp.path}${_sep}tree')..createSync();
    cache = Directory('${temp.path}${_sep}cache')..createSync();
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  File clip(String name, String content) =>
      File('${rides.path}$_sep$name')..writeAsStringSync(content);

  /// Writes ride [id] over [segments] (in [rides]) sealed as [seal] and
  /// returns its telemetry file.
  Future<File> writeRide(
    String id,
    List<File> segments, {
    List<File> locked = const <File>[],
    _Seal seal = _Seal.v2,
    bool sessionComplete = true,
    bool mock = false,
    List<Map<String, dynamic>>? incidents,
  }) async {
    final paths = <String>[for (final s in segments) s.path];
    final payload = <String, dynamic>{
      'schemaVersion': seal == _Seal.none ? 2 : 3,
      'rideSessionId': id,
      'sessionComplete': sessionComplete,
      'videoPath': paths.last,
      'segmentPaths': paths,
      'lockedSegmentPaths': <String>[for (final s in locked) s.path],
      'segmentTimeline': <Map<String, dynamic>>[
        for (var i = 0; i < paths.length; i++)
          <String, dynamic>{
            'path': paths[i],
            'startMs': i * 60000,
            'endMs': i * 60000 + 59800,
          },
      ],
      'incidents': ?incidents,
      if (mock) 'mockLocationDetected': true,
      'startedAt': '2026-11-19T10:00:00.000Z',
      'distanceKm': 1.5,
      'maxSpeedKmh': 40.0,
      'averageSpeedKmh': 20.0,
      'samples': <Map<String, dynamic>>[
        <String, dynamic>{
          'elapsedMs': 0,
          'speed': 10.0,
          'timestamp': '2026-11-19T10:00:00Z',
        },
      ],
    };
    final hashes = <String, String>{
      for (final path in paths) path: (await hashFileSha256(path))!,
    };
    final Map<String, dynamic> json;
    switch (seal) {
      case _Seal.none:
        json = payload;
      case _Seal.v1:
        json = <String, dynamic>{
          ...payload,
          'integrity': <String, dynamic>{
            'algo': 'sha256',
            'payloadHash': hashJsonCanonical(payload),
            'segmentCount': paths.length,
            'hashedSegmentCount': hashes.length,
            'segmentHashes': hashes,
            'generatedAt': '2026-11-19T12:00:00.000Z',
          },
        };
      case _Seal.v2:
        json = <String, dynamic>{
          ...payload,
          'integrity': buildIntegrityEnvelope(
            payload: payload,
            segmentHashes: hashes,
            segmentCount: paths.length,
          ),
        };
      case _Seal.v3:
        final sealed = await sealAndSignRidePayload(
          payload,
          segmentHashes: hashes,
          segmentCount: paths.length,
          generatedAt: DateTime.utc(2026, 11, 19, 12),
          signer: phone.signer,
        );
        expect(sealed.signature, isNotNull);
        json = sealed.json;
    }
    final file = File('${rides.path}$_sep${rideTelemetryFileNameFor(id)}');
    await file.writeAsString(jsonEncode(json));
    return file;
  }

  /// The ride as the screen holds it, with this phone's signer context
  /// (the ride is registered as signed here only when it carries a
  /// signature).
  Future<RideRecord> screenRecord(File telemetry, String id) async {
    final ride = await RideRecord.fromTelemetryFile(
      telemetry,
      loadSamples: false,
    );
    final signed = ride!.integrity.signature != null;
    return ride.withSignerContext(
      RideSignerContext(
        thisDevicePublicKey: phone.publicKeyBase64,
        signedRideIds: signed ? <String>{id} : const <String>{},
        signedTelemetryFileNames: signed
            ? <String>{rideTelemetryFileNameFor(id)}
            : const <String>{},
      ),
    );
  }

  Future<RideExportPlan> plan(
    File telemetry,
    String id, {
    RideExportClips clips = RideExportClips.all,
    bool includeRideData = true,
    RideExportSection? section,
  }) async {
    final source = await loadRideExportSource(
      await screenRecord(telemetry, id),
    );
    return planRideExport(
      source,
      clips: clips,
      includeRideData: includeRideData,
      section: section,
    );
  }

  RideExporter exporter(
    _FakeNative native, {
    bool Function()? shouldPause,
    DateTime Function()? now,
  }) => RideExporter(
    native: native,
    cacheDirectory: cache.path,
    shouldPause: shouldPause,
    now: now ?? () => exportedAt,
    pollInterval: const Duration(milliseconds: 5),
  );

  Directory exportFolder(RideExportPlan plan) =>
      Directory('${tree.path}$_sep${plan.folderName}');

  List<String> namesIn(Directory folder) =>
      folder.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

  Future<
    ({RideExportResult result, Map<String, dynamic> manifest, String readme})
  >
  exportAndRead(RideExportPlan plan) async {
    final result = await exporter(
      _FakeNative(tree),
    ).exportToFolder(plan, treeUri: tree.path);
    expect(result.outcome, RideExportOutcome.done);
    final folder = exportFolder(plan).path;
    final manifestText = File('$folder${_sep}manifest.json').readAsStringSync();
    final readme = File('$folder${_sep}MOTOCAM-EXPORT.txt').readAsStringSync();
    expect(manifestText, isNot(contains(temp.path)));
    expect(readme, isNot(contains(temp.path)));
    expect(readme, isNot(contains(rides.path)));
    return (
      result: result,
      manifest: jsonDecode(manifestText) as Map<String, dynamic>,
      readme: readme,
    );
  }

  group('clip selection', () {
    RideRecord ride({
      List<String> segments = const <String>['a', 'b', 'c'],
      List<String> locked = const <String>[],
      List<RideSegmentTimelineEntry>? timeline,
      List<int>? incidents,
    }) {
      String path(String name) => '$_sep${'r'}$_sep$name.mp4';
      return RideRecord(
        videoPath: path(segments.last),
        segmentPaths: <String>[for (final s in segments) path(s)],
        lockedSegmentPaths: <String>[for (final s in locked) path(s)],
        createdAt: DateTime(2026, 11, 19),
        telemetryPath: '$_sep${'r'}${_sep}ride_x.telemetry.json',
        rideSessionId: 'x',
        isSessionComplete: true,
        distanceKm: 0,
        maxSpeedKmh: 0,
        averageSpeedKmh: 0,
        segmentTimeline:
            timeline ??
            <RideSegmentTimelineEntry>[
              RideSegmentTimelineEntry(
                path: path('c'),
                startMs: 120200,
                endMs: 180000,
              ),
              RideSegmentTimelineEntry(
                path: path('a'),
                startMs: 0,
                endMs: 60000,
              ),
              RideSegmentTimelineEntry(
                path: path('b'),
                startMs: 60200,
                endMs: 120000,
              ),
            ],
        samples: const [],
        integrity: const RideIntegrityReport.unknown(),
        quarantinedSegmentPaths: const <String>[],
        incidents: incidents == null
            ? null
            : <RideIncident>[
                for (final t in incidents) RideIncident(elapsedMs: t),
              ],
      );
    }

    List<String> names(RideEvidenceSelection selection) => <String>[
      for (final p in selection.paths) p.split(_sep).last,
    ];

    test('locked clips are selected in recording order', () {
      final selection = selectEvidenceClips(ride(locked: <String>['c', 'a']));
      expect(names(selection), <String>['a.mp4', 'c.mp4']);
      expect(selection.unmappedIncidentsMs, isEmpty);
    });

    test('an incident selects the clip it falls in', () {
      final selection = selectEvidenceClips(ride(incidents: <int>[30000]));
      expect(names(selection), <String>['a.mp4']);
    });

    test('an incident in the roll gap selects the clip before the gap', () {
      final selection = selectEvidenceClips(ride(incidents: <int>[60100]));
      expect(names(selection), <String>['a.mp4']);
    });

    test('an incident early in a clip also selects the lead-up clip', () {
      expect(
        names(selectEvidenceClips(ride(incidents: <int>[65000]))),
        <String>['a.mp4', 'b.mp4'],
      );
      expect(
        names(selectEvidenceClips(ride(incidents: <int>[70200]))),
        <String>['b.mp4'],
      );
    });

    test('an incident past the last clip end maps to no clip', () {
      expect(
        names(selectEvidenceClips(ride(incidents: <int>[181000]))),
        <String>['c.mp4'],
      );
      final selection = selectEvidenceClips(ride(incidents: <int>[181001]));
      expect(selection.paths, isEmpty);
      expect(selection.unmappedIncidentsMs, <int>[181001]);
    });

    test('an incident before the first clip maps to no clip', () {
      final selection = selectEvidenceClips(
        ride(
          segments: <String>['a'],
          timeline: <RideSegmentTimelineEntry>[
            RideSegmentTimelineEntry(
              path: '$_sep${'r'}${_sep}a.mp4',
              startMs: 500,
              endMs: 60000,
            ),
          ],
          incidents: <int>[100],
        ),
      );
      expect(selection.paths, isEmpty);
      expect(selection.unmappedIncidentsMs, <int>[100]);
    });

    test('without a timeline only the locked clips are selected', () {
      final selection = selectEvidenceClips(
        ride(
          locked: <String>['b'],
          timeline: const <RideSegmentTimelineEntry>[],
          incidents: <int>[30000],
        ),
      );
      expect(names(selection), <String>['b.mp4']);
      expect(selection.unmappedIncidentsMs, isEmpty);
    });

    test('a quarantined path is never selected', () {
      final outside = '$_sep${'elsewhere'}${_sep}q.mp4';
      final record = ride(
        segments: <String>['a'],
        timeline: <RideSegmentTimelineEntry>[
          RideSegmentTimelineEntry(path: outside, startMs: 0, endMs: 60000),
        ],
        incidents: <int>[1000],
      );
      final selection = selectEvidenceClips(record);
      expect(selection.paths, isEmpty);
      expect(selection.unmappedIncidentsMs, <int>[1000]);
    });

    test('a missing clip is listed, never copied', () async {
      final a = clip('a.mp4', 'aaaa');
      final b = clip('b.mp4', 'bbbb');
      final telemetry = await writeRide('m', <File>[a, b], locked: <File>[b]);
      final source = await loadRideExportSource(
        await screenRecord(telemetry, 'm'),
      );
      b.deleteSync();
      final evidence = await planRideExport(
        source,
        clips: RideExportClips.evidence,
        includeRideData: true,
      );
      expect(evidence.clips, isEmpty);
      expect(
        evidence.notExported.map((o) => '${o.name}:${o.reason.name}'),
        <String>['a.mp4:notSelected', 'b.mp4:missing'],
      );
      expect(evidence.notExported.last.recordedSha256, isNotNull);

      final all = await planRideExport(
        source,
        clips: RideExportClips.all,
        includeRideData: true,
        stat: (path) async => path == a.path
            ? const RideFileStamp(size: 4, modifiedUs: 0, changedUs: 0)
            : null,
      );
      expect(all.clips.map((c) => c.name), <String>['a.mp4']);
      expect(all.clips.single.bytes, 4);
      expect(all.rideData!.name, 'ride_m.telemetry.json');
      expect(all.expectedNames, <String>[
        'a.mp4',
        'ride_m.telemetry.json',
        'manifest.json',
        'MOTOCAM-EXPORT.txt',
      ]);
    });

    group('a section', () {
      Future<RideFileStamp?> sized(String path) async =>
          const RideFileStamp(size: 600, modifiedUs: 0, changedUs: 0);

      Future<RideExportPlan> section(
        RideRecord record,
        int fromMs,
        int toMs, {
        RideFileStatSource? stat,
      }) => planRideExport(
        RideExportSource(ride: record, rideDataSha256: 'h0', rideDataBytes: 5),
        clips: RideExportClips.section,
        includeRideData: true,
        section: RideExportSection(fromMs, toMs),
        stat: stat ?? sized,
      );

      /// Each clip as `name whole|trimmed from-to` (clip-local ms).
      List<String> parts(RideExportPlan p) => <String>[
        for (final c in p.clips)
          '${c.name} ${c.trimmed ? 'trimmed' : 'whole'} '
              '${c.part!.clipFromMs}-${c.part!.clipToMs}',
      ];

      // The timeline: a 0 to 60000, b 60200 to 120000, c 120200 to 180000.

      test('clips fully inside are whole; never the ride data', () async {
        final p = await section(ride(), 0, 180000);
        expect(p.clipChoice, RideExportClips.section);
        expect(p.section, const RideExportSection(0, 180000));
        expect(parts(p), <String>[
          'a.mp4 whole 0-60000',
          'b.mp4 whole 0-59800',
          'c.mp4 whole 0-59800',
        ]);
        expect(p.clipBytes, 1800);
        expect(p.includeRideData, isFalse);
        expect(p.rideData, isNull);
        expect(p.notExported, isEmpty);
        expect(p.unmappedIncidentsMs, isEmpty);
        expect(p.folderName, 'MotoCam ride x (section 00m00s to 03m00s)');
        expect(p.expectedNames, <String>[
          'a.mp4',
          'b.mp4',
          'c.mp4',
          'manifest.json',
          'MOTOCAM-EXPORT.txt',
        ]);
      });

      test(
        'clips cut at either end are trimmed with clip-local times',
        () async {
          final p = await section(ride(), 30000, 150000);
          expect(parts(p), <String>[
            'a.mp4 trimmed 30000-60000',
            'b.mp4 whole 0-59800',
            'c.mp4 trimmed 0-29800',
          ]);
          // A trimmed part's size is its share of the clip.
          expect(p.clips.map((c) => c.bytes), <int>[300, 600, 299]);
          expect(p.folderName, 'MotoCam ride x (section 00m30s to 02m30s)');
        },
      );

      test('a range inside one clip trims that clip at both ends', () async {
        final p = await section(ride(), 70000, 80000);
        expect(parts(p), <String>['b.mp4 trimmed 9800-19800']);
        expect(p.clips.single.part!.rideStartMs, 60200);
      });

      test('a range that starts or ends in a roll gap starts at the next clip '
          'or ends at the previous one', () async {
        expect(parts(await section(ride(), 60100, 120100)), <String>[
          'b.mp4 whole 0-59800',
        ]);
        expect(parts(await section(ride(), 10000, 60100)), <String>[
          'a.mp4 trimmed 10000-60000',
        ]);
        expect(parts(await section(ride(), 60100, 90000)), <String>[
          'b.mp4 trimmed 0-29800',
        ]);
      });

      test('a missing clip inside the range is listed, never copied', () async {
        final p = await section(
          ride(),
          30000,
          150000,
          stat: (path) async => path.endsWith('b.mp4') ? null : sized(path),
        );
        expect(p.clips.map((c) => c.name), <String>['a.mp4', 'c.mp4']);
        expect(p.notExported.map((o) => '${o.name}:${o.reason.name}'), <String>[
          'b.mp4:missing',
        ]);
        expect(p.notExported.single.recordedSha256, isNull);
        expect(p.expectedNames, isNot(contains('b.mp4')));
      });

      test('a ride without a timeline has no sections', () async {
        final record = ride(timeline: const <RideSegmentTimelineEntry>[]);
        expect(rideExportLengthMs(record), isNull);
        expect(rideExportLengthMs(ride()), 180000);
        await expectLater(section(record, 0, 1000), throwsArgumentError);
      });

      test('an empty or reversed range, or no range, is refused', () async {
        await expectLater(section(ride(), 5000, 5000), throwsArgumentError);
        await expectLater(section(ride(), 6000, 5000), throwsArgumentError);
        await expectLater(section(ride(), -1000, 5000), throwsArgumentError);
        await expectLater(
          planRideExport(
            RideExportSource(ride: ride()),
            clips: RideExportClips.section,
            includeRideData: false,
          ),
          throwsArgumentError,
        );
      });

      test('the clock text is local HH:mm:ss after the ride start', () {
        // The ride starts at local midnight.
        expect(rideExportClockText(ride(), 125000), '00:02:05');
        expect(
          rideExportClockText(ride(), 14 * 3600000 + 5 * 60000 + 12000),
          '14:05:12',
        );
      });
    });
  });

  group('folder naming', () {
    RideRecord named(String? id, String video) => RideRecord(
      videoPath: '$_sep${'r'}$_sep$video',
      segmentPaths: <String>['$_sep${'r'}$_sep$video'],
      lockedSegmentPaths: const <String>[],
      createdAt: DateTime(2026, 11, 19),
      telemetryPath: null,
      rideSessionId: id,
      isSessionComplete: true,
      distanceKm: 0,
      maxSpeedKmh: 0,
      averageSpeedKmh: 0,
      segmentTimeline: const <RideSegmentTimelineEntry>[],
      samples: const [],
      integrity: const RideIntegrityReport.unknown(),
      quarantinedSegmentPaths: const <String>[],
    );

    test('the four scopes give four folders', () {
      final ride = named('1794558143532_1aec41b3127e1626', 'REC_1.mp4');
      String name(RideExportClips clips, bool data) =>
          rideExportFolderName(ride, clips: clips, includeRideData: data);
      expect(
        name(RideExportClips.evidence, true),
        'MotoCam ride 1794558143532_1aec41b3127e1626 (locked clips)',
      );
      expect(
        name(RideExportClips.all, true),
        'MotoCam ride 1794558143532_1aec41b3127e1626 (all clips)',
      );
      expect(
        name(RideExportClips.evidence, false),
        'MotoCam ride 1794558143532_1aec41b3127e1626 '
        '(locked clips, video only)',
      );
      expect(
        name(RideExportClips.all, false),
        'MotoCam ride 1794558143532_1aec41b3127e1626 (all clips, video only)',
      );
    });

    test('a section names its ride time range, always video only', () {
      final ride = named('1794558143532_1aec41b3127e1626', 'REC_1.mp4');
      String name(int fromMs, int toMs, bool data) => rideExportFolderName(
        ride,
        clips: RideExportClips.section,
        includeRideData: data,
        section: RideExportSection(fromMs, toMs),
      );
      expect(
        name(312000, 400000, true),
        'MotoCam ride 1794558143532_1aec41b3127e1626 '
        '(section 05m12s to 06m40s)',
      );
      expect(name(312000, 400000, false), name(312000, 400000, true));
      expect(
        name(3912000, 3920500, false),
        'MotoCam ride 1794558143532_1aec41b3127e1626 '
        '(section 1h05m12s to 1h05m20s)',
      );
      expect(name(312000, 401000, true), isNot(name(312000, 400000, true)));
      expect(
        () => rideExportFolderName(
          ride,
          clips: RideExportClips.section,
          includeRideData: true,
        ),
        throwsArgumentError,
      );
    });

    test('the id is sanitised and a legacy ride uses its video name', () {
      expect(
        rideExportFolderName(
          named('a b/c.d', 'x.mp4'),
          clips: RideExportClips.all,
          includeRideData: true,
        ),
        'MotoCam ride a_b_c_d (all clips)',
      );
      expect(
        rideExportFolderName(
          named(null, 'REC 2026.mp4'),
          clips: RideExportClips.all,
          includeRideData: false,
        ),
        'MotoCam ride REC_2026 (all clips, video only)',
      );
    });
  });

  group('folder run', () {
    test(
      'copies the clips, the ride file, the manifest and the README',
      () async {
        final a = clip('a.mp4', 'aaaa');
        final b = clip('b.mp4', 'bbbbbb');
        final telemetry = await writeRide('r1', <File>[a, b]);
        final p = await plan(telemetry, 'r1');
        final native = _FakeNative(tree);
        final progress = <String>[];
        final result = await exporter(native).exportToFolder(
          p,
          treeUri: tree.path,
          onProgress: (done, total) => progress.add('$done/$total'),
        );

        expect(result.outcome, RideExportOutcome.done);
        expect(native.calls, <String>[
          'prepare',
          'export:a.mp4',
          'export:b.mp4',
          'export:ride_r1.telemetry.json',
          'export:manifest.json',
          'export:MOTOCAM-EXPORT.txt',
        ]);
        expect(progress, <String>['1/5', '2/5', '3/5', '4/5', '5/5']);
        expect(namesIn(exportFolder(p)), <String>[
          'MOTOCAM-EXPORT.txt',
          'a.mp4',
          'b.mp4',
          'manifest.json',
          'ride_r1.telemetry.json',
        ]);
        expect(
          File(
            '${exportFolder(p).path}${_sep}ride_r1.telemetry.json',
          ).readAsBytesSync(),
          telemetry.readAsBytesSync(),
        );
        expect(result.fileCount, 5);
        expect(result.skipped, 0);
        expect(result.sourceDiffers, 0);
        expect(rideExportSummary(result), startsWith('Exported 5 files ('));
        expect(
          rideExportSummary(result),
          endsWith('to "MotoCam ride r1 (all clips)". All copies checked.'),
        );
        // The staging folder is removed after a folder run.
        expect(
          Directory('${cache.path}${_sep}ride_export').listSync(),
          isEmpty,
        );
      },
    );

    test('a re-run skips the files already there', () async {
      final a = clip('a.mp4', 'aaaa');
      final telemetry = await writeRide('r2', <File>[a]);
      final p = await plan(telemetry, 'r2');
      await exporter(_FakeNative(tree)).exportToFolder(p, treeUri: tree.path);
      final again = await exporter(
        _FakeNative(tree),
      ).exportToFolder(p, treeUri: tree.path);
      expect(again.outcome, RideExportOutcome.done);
      expect(again.skipped, 2);
      expect(again.fileCount, 4);
    });

    test('unsynced copies are reported', () async {
      final telemetry = await writeRide('r3', <File>[clip('a.mp4', 'aaaa')]);
      final p = await plan(telemetry, 'r3');
      final result = await exporter(
        _FakeNative(tree)..synced = false,
      ).exportToFolder(p, treeUri: tree.path);
      expect(
        rideExportSummary(result),
        endsWith(
          'Copied and checked; the storage app may still be saving them.',
        ),
      );
    });

    test('a failed clip stops the run before the ride file', () async {
      final telemetry = await writeRide('r4', <File>[
        clip('a.mp4', 'aaaa'),
        clip('b.mp4', 'bbbb'),
      ]);
      final p = await plan(telemetry, 'r4');
      final native = _FakeNative(tree)..fail['a.mp4'] = 'WRITE_FAILED';
      final result = await exporter(
        native,
      ).exportToFolder(p, treeUri: tree.path);
      expect(result.outcome, RideExportOutcome.failed);
      expect(result.failedCount, 1);
      expect(result.failureCode, 'WRITE_FAILED');
      expect(namesIn(exportFolder(p)), <String>['b.mp4']);
      expect(
        rideExportSummary(result),
        'Could not copy 1 file (the folder may be full or was removed). '
        'Run Export again: files already exported are skipped.',
      );
    });

    test('a copy that reads back different is a failure', () async {
      final telemetry = await writeRide('r5', <File>[clip('a.mp4', 'aaaa')]);
      final p = await plan(telemetry, 'r5');
      final result = await exporter(
        _FakeNative(tree)..mismatch.add('a.mp4'),
      ).exportToFolder(p, treeUri: tree.path);
      expect(result.outcome, RideExportOutcome.failed);
      expect(result.failureCode, 'COPY_MISMATCH');
      expect(namesIn(exportFolder(p)), isEmpty);
    });

    test('a different file of the same name is never overwritten', () async {
      final telemetry = await writeRide('r6', <File>[clip('a.mp4', 'aaaa')]);
      final p = await plan(telemetry, 'r6');
      exportFolder(p).createSync(recursive: true);
      File('${exportFolder(p).path}${_sep}a.mp4').writeAsStringSync('zzzz');
      final result = await exporter(
        _FakeNative(tree),
      ).exportToFolder(p, treeUri: tree.path);
      expect(result.outcome, RideExportOutcome.failed);
      expect(
        rideExportSummary(result),
        'A different file named a.mp4 is already in the folder.',
      );
      expect(
        File('${exportFolder(p).path}${_sep}a.mp4').readAsStringSync(),
        'zzzz',
      );
    });

    test('a folder with other files is refused', () async {
      final telemetry = await writeRide('r7', <File>[clip('a.mp4', 'aaaa')]);
      final p = await plan(telemetry, 'r7');
      exportFolder(p).createSync(recursive: true);
      File('${exportFolder(p).path}${_sep}holiday.jpg').writeAsStringSync('x');
      final result = await exporter(
        _FakeNative(tree),
      ).exportToFolder(p, treeUri: tree.path);
      expect(result.outcome, RideExportOutcome.failed);
      expect(
        rideExportSummary(result),
        'This folder holds other files; pick another folder.',
      );
      expect(
        rideExportFailureText('NOT_WRITABLE'),
        'This folder cannot be written; pick another.',
      );
    });

    test('a renamed folder names the folder in the message', () async {
      final telemetry = await writeRide('r12', <File>[clip('a.mp4', 'aaaa')]);
      final p = await plan(telemetry, 'r12');
      final result = await exporter(
        _FakeNative(tree)..failPrepare = 'NAME_CONFLICT',
      ).exportToFolder(p, treeUri: tree.path);
      expect(result.outcome, RideExportOutcome.failed);
      expect(result.failureCode, 'NAME_CONFLICT');
      expect(
        rideExportSummary(result),
        'The folder app would not keep the name '
        '"MotoCam ride r12 (all clips)"; pick another folder.',
      );
    });

    test(
      'a clip that differs from its recorded hash is labelled, not failed',
      () async {
        final a = clip('a.mp4', 'aaaa');
        final telemetry = await writeRide('r8', <File>[a, clip('b.mp4', 'bb')]);
        a.writeAsStringSync('AAAA');
        final p = await plan(telemetry, 'r8');
        final read = await exportAndRead(p);
        expect(read.result.sourceDiffers, 1);
        final files = (read.manifest['files'] as List)
            .cast<Map<String, dynamic>>();
        expect(files.map((f) => f['recorded']), <String>['differs', 'match']);
        expect(
          _flat(read.readme),
          contains('Recorded hash: DIFFERS, recorded'),
        );
        expect(
          _flat(read.readme),
          contains(
            '1 of 2 exported clips match their recorded hash; 1 differ; 0 have none.',
          ),
        );
        expect(
          rideExportSummary(read.result),
          endsWith(
            '1 clip differs from the hash recorded when the ride was saved; '
            'this is noted in MOTOCAM-EXPORT.txt.',
          ),
        );
      },
    );

    test('a ride file changed during the export fails the run', () async {
      final telemetry = await writeRide('r9', <File>[clip('a.mp4', 'aaaa')]);
      final p = await plan(telemetry, 'r9');
      telemetry.writeAsStringSync('${telemetry.readAsStringSync()} ');
      final result = await exporter(
        _FakeNative(tree),
      ).exportToFolder(p, treeUri: tree.path);
      expect(result.outcome, RideExportOutcome.failed);
      expect(result.failureCode, 'RIDE_DATA_CHANGED');
      expect(
        rideExportSummary(result),
        'The ride file changed during export; run Export again.',
      );
      expect(namesIn(exportFolder(p)), isNot(contains('manifest.json')));
    });

    test('a recording that starts pauses the run at once', () async {
      final telemetry = await writeRide('r10', <File>[
        clip('a.mp4', 'aaaa'),
        clip('b.mp4', 'bbbb'),
      ]);
      final p = await plan(telemetry, 'r10');
      var recording = false;
      final native = _FakeNative(tree)
        ..slow.add('b.mp4')
        ..during = (name) {
          if (name == 'b.mp4') {
            recording = true;
          }
        };
      final result = await exporter(
        native,
        shouldPause: () => recording,
      ).exportToFolder(p, treeUri: tree.path);
      expect(result.outcome, RideExportOutcome.paused);
      expect(native.calls, contains('cancel'));
      expect(native.calls.last, isNot('export:ride_r10.telemetry.json'));
      expect(namesIn(exportFolder(p)), <String>['a.mp4']);
      expect(
        rideExportSummary(result),
        'Export stopped because a recording started. Run it again to continue.',
      );
    });

    test('the rider can cancel the run', () async {
      final telemetry = await writeRide('r11', <File>[
        clip('a.mp4', 'aaaa'),
        clip('b.mp4', 'bbbb'),
      ]);
      final p = await plan(telemetry, 'r11');
      final native = _FakeNative(tree)..slow.add('a.mp4');
      final run = exporter(native);
      native.during = (_) => unawaited(run.cancel());
      final result = await run.exportToFolder(p, treeUri: tree.path);
      expect(result.outcome, RideExportOutcome.cancelled);
      expect(native.calls.where((c) => c.startsWith('export:')), <String>[
        'export:a.mp4',
      ]);
      expect(rideExportSummary(result), startsWith('Export stopped.'));
    });

    test('a cancel made before the run starts is not lost', () async {
      final telemetry = await writeRide('r12', <File>[clip('a.mp4', 'aaaa')]);
      final p = await plan(telemetry, 'r12');
      final native = _FakeNative(tree);
      final run = exporter(native);
      await run.cancel();
      final result = await run.exportToFolder(p, treeUri: tree.path);
      expect(result.outcome, RideExportOutcome.cancelled);
      expect(native.calls, <String>['cancel']);
    });

    test('a cancel while the ride file lock waits is not lost', () async {
      final telemetry = await writeRide('r13', <File>[clip('a.mp4', 'aaaa')]);
      final p = await plan(telemetry, 'r13');
      final native = _FakeNative(tree);
      final run = exporter(native);
      // Someone else holds the ride file, so the ride-data step waits.
      final release = Completer<void>();
      final held = runExclusiveForPath(
        p.rideData!.sourcePath,
        () => release.future,
      );
      final running = run.exportToFolder(p, treeUri: tree.path);
      while (!native.calls.contains('export:a.mp4')) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await run.cancel();
      release.complete();
      await held;
      final result = await running;
      expect(result.outcome, RideExportOutcome.cancelled);
      // Native resets its cancel flag when a call starts, so the stop must
      // be checked before the ride file is sent at all.
      expect(native.calls, isNot(contains('export:${p.rideData!.name}')));
      expect(namesIn(exportFolder(p)), <String>['a.mp4']);
    });
  });

  group('section run', () {
    Future<RideExportPlan> sectionPlan(String id, int fromMs, int toMs) async {
      final telemetry = await writeRide(id, <File>[
        clip('a.mp4', 'aaaa'),
        clip('b.mp4', 'bbbb'),
        clip('c.mp4', 'cccc'),
      ]);
      return plan(
        telemetry,
        id,
        clips: RideExportClips.section,
        section: RideExportSection(fromMs, toMs),
      );
    }

    Directory trimDirectory() =>
        Directory('${cache.path}${_sep}ride_export${_sep}trim');

    test('trims cut clips with clip-local times, copies them with replace '
        'and deletes the temp files', () async {
      final p = await sectionPlan('t1', 30000, 150000);
      final native = _FakeNative(tree);
      final progress = <String>[];
      final result = await exporter(native).exportToFolder(
        p,
        treeUri: tree.path,
        onProgress: (done, total) => progress.add('$done/$total'),
      );
      expect(result.outcome, RideExportOutcome.done);
      expect(native.calls, <String>[
        'prepare',
        'trim:a.mp4:30000000-59800000',
        'export:a.mp4',
        'export:b.mp4',
        'trim:c.mp4:0-30000000',
        'export:c.mp4',
        'export:manifest.json',
        'export:MOTOCAM-EXPORT.txt',
      ]);
      // Only the trimmed outputs replace a file of the same name.
      expect(native.replaced, <String>['a.mp4', 'c.mp4']);
      expect(progress, <String>['1/5', '2/5', '3/5', '4/5', '5/5']);
      final folder = exportFolder(p).path;
      expect(
        File('$folder${_sep}a.mp4').readAsStringSync(),
        'trim1:30000000-59800000:aaaa',
      );
      expect(File('$folder${_sep}b.mp4').readAsStringSync(), 'bbbb');
      expect(result.clips.map((c) => c.trimmed), <bool>[true, false, true]);
      expect(result.clips.first.clipFromMs, 29400);
      expect(trimDirectory().listSync(), isEmpty);
      expect(
        rideExportSummary(result),
        'Exported 5 files (${formatFileSize(result.bytes)}) to '
        '"MotoCam ride t1 (section 00m30s to 02m30s)". All copies checked.',
      );

      // A re-run skips the whole clip and makes the trimmed ones again.
      final again = _FakeNative(tree)..trims = 5;
      final rerun = await exporter(again).exportToFolder(p, treeUri: tree.path);
      expect(rerun.outcome, RideExportOutcome.done);
      expect(rerun.skipped, 1);
      expect(again.replaced, <String>['a.mp4', 'c.mp4']);
      expect(
        File('$folder${_sep}a.mp4').readAsStringSync(),
        'trim6:30000000-59800000:aaaa',
      );
    });

    test('a trimmed clip ends at the last sample written, or at the '
        'requested end when the trim reports none', () async {
      // a is cut at its start and runs to its timeline end (59.8 s), but
      // its media ends at 58.6 s; c's trim reports no sample time.
      final p = await sectionPlan('t7', 30000, 150000);
      final native = _FakeNative(tree)
        ..lastUs['a.mp4'] = 58633333
        ..lastUs['c.mp4'] = -1;
      final result = await exporter(
        native,
      ).exportToFolder(p, treeUri: tree.path);
      expect(result.outcome, RideExportOutcome.done);
      expect(result.clips.map((c) => c.clipToMs), <int>[58633, 59800, 30000]);
      final folder = exportFolder(p).path;
      final manifest =
          jsonDecode(File('$folder${_sep}manifest.json').readAsStringSync())
              as Map<String, dynamic>;
      final files = (manifest['files'] as List).cast<Map<String, dynamic>>();
      expect(files.map((f) => f['clipToMs']), <int>[58633, 59800, 30000]);
      expect(
        File('$folder${_sep}MOTOCAM-EXPORT.txt').readAsStringSync(),
        contains('  In the clip: 00:29.400 to 00:58.633\n'),
      );
    });

    test('a section run clears temp files a killed run left behind', () async {
      final p = await sectionPlan('t0', 30000, 150000);
      final leftover = File('${trimDirectory().path}${_sep}old.mp4')
        ..createSync(recursive: true)
        ..writeAsStringSync('left by a killed run');
      final result = await exporter(
        _FakeNative(tree),
      ).exportToFolder(p, treeUri: tree.path);
      expect(result.outcome, RideExportOutcome.done);
      expect(leftover.existsSync(), isFalse);
      expect(trimDirectory().listSync(), isEmpty);
    });

    test('a failed trim fails the run and leaves no temp file', () async {
      final p = await sectionPlan('t2', 30000, 150000);
      final native = _FakeNative(tree)..fail['trim:c.mp4'] = 'TRIM_FAILED';
      final result = await exporter(
        native,
      ).exportToFolder(p, treeUri: tree.path);
      expect(result.outcome, RideExportOutcome.failed);
      expect(result.failureCode, 'TRIM_FAILED');
      expect(native.calls, isNot(contains('export:manifest.json')));
      expect(trimDirectory().listSync(), isEmpty);
      expect(
        rideExportSummary(result),
        'Could not cut c.mp4 for this section. Pick another section, or '
        'export whole clips.',
      );
    });

    test('the rider can cancel during a trim', () async {
      final p = await sectionPlan('t3', 30000, 150000);
      final native = _FakeNative(tree)..slow.add('trim:a.mp4');
      final run = exporter(native);
      native.during = (name) {
        if (name == 'trim:a.mp4') {
          unawaited(run.cancel());
        }
      };
      final result = await run.exportToFolder(p, treeUri: tree.path);
      expect(result.outcome, RideExportOutcome.cancelled);
      expect(native.calls, contains('cancel'));
      expect(native.calls.where((c) => c.startsWith('export:')), isEmpty);
      expect(namesIn(exportFolder(p)), isEmpty);
      expect(trimDirectory().listSync(), isEmpty);
    });

    test('a recording that starts pauses a trim at once', () async {
      final p = await sectionPlan('t4', 30000, 150000);
      var recording = false;
      final native = _FakeNative(tree)
        ..slow.add('trim:c.mp4')
        ..during = (name) {
          if (name == 'trim:c.mp4') {
            recording = true;
          }
        };
      final result = await exporter(
        native,
        shouldPause: () => recording,
      ).exportToFolder(p, treeUri: tree.path);
      expect(result.outcome, RideExportOutcome.paused);
      expect(native.calls, contains('cancel'));
      expect(native.calls, isNot(contains('export:c.mp4')));
      expect(namesIn(exportFolder(p)), <String>['a.mp4', 'b.mp4']);
      expect(trimDirectory().listSync(), isEmpty);
    });

    test('a share trims into its staging folder and shares the cut copies '
        'under their own names', () async {
      final p = await sectionPlan('t5', 30000, 90000);
      final native = _FakeNative(tree);
      final later = DateTime.now().add(const Duration(days: 2));
      final result = await exporter(native, now: () => later).share(p);
      expect(result.outcome, RideExportOutcome.done);
      expect(native.calls, <String>[
        'trim:a.mp4:30000000-59800000',
        'hash:a.mp4',
        'trim:b.mp4:0-30000000',
        'hash:b.mp4',
        'share',
      ]);
      final staging =
          '${cache.path}${_sep}ride_export$_sep${p.folderName}-'
          '${later.millisecondsSinceEpoch}';
      expect(native.sharedPaths, <String>[
        '$staging${_sep}a.mp4',
        '$staging${_sep}b.mp4',
        '$staging${_sep}manifest.json',
        '$staging${_sep}MOTOCAM-EXPORT.txt',
      ]);
      // The cut copies stay for the receiving app.
      expect(File('$staging${_sep}a.mp4').existsSync(), isTrue);
      final manifest =
          jsonDecode(File('$staging${_sep}manifest.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(manifest['sha256Of'], 'source');
      expect((manifest['files'] as List).first, <String, Object?>{
        'name': 'a.mp4',
        'bytes': File('$staging${_sep}a.mp4').lengthSync(),
        'sha256': sha256
            .convert(File('$staging${_sep}a.mp4').readAsBytesSync())
            .toString(),
        'trimmed': true,
        'clipFromMs': 29400,
        'clipToMs': 59800,
      });
    });

    test('a share stopped during a trim leaves no staging folder', () async {
      final p = await sectionPlan('t6', 30000, 90000);
      final native = _FakeNative(tree)..slow.add('trim:b.mp4');
      final run = exporter(native);
      native.during = (name) {
        if (name == 'trim:b.mp4') {
          unawaited(run.cancel());
        }
      };
      final result = await run.share(p);
      expect(result.outcome, RideExportOutcome.cancelled);
      expect(native.sharedPaths, isNull);
      expect(Directory('${cache.path}${_sep}ride_export').listSync(), isEmpty);
    });
  });

  group('manifest and README', () {
    test('a signed ride lists its key, the chain and fixed strings', () async {
      final telemetry = await writeRide(
        's1',
        <File>[clip('a.mp4', 'aaaa'), clip('b.mp4', 'bbbb')],
        locked: <File>[],
        seal: _Seal.v3,
        incidents: <Map<String, dynamic>>[
          <String, dynamic>{'elapsedMs': 200000},
        ],
      );
      final p = await plan(telemetry, 's1', clips: RideExportClips.all);
      final read = await exportAndRead(p);
      final manifest = read.manifest;
      expect(manifest['format'], 'motocam-ride-export');
      expect(manifest['formatVersion'], 1);
      expect(manifest['rideSessionId'], 's1');
      expect(manifest['exportedAt'], '2026-11-19T13:05:00.000Z');
      expect(manifest['destination'], 'folder');
      expect(manifest['clips'], 'all');
      expect(manifest['rideDataIncluded'], isTrue);
      expect(manifest['sha256Of'], 'copy');
      expect(manifest['integrity'], <String, Object?>{
        'state': 'signed',
        'signed': true,
        'alg': 'ES256',
        'keyId': phone.keyId,
        'publicKey': phone.publicKeyBase64,
        'signedBy': 'exportingPhone',
        'envelopeVersion': 3,
        'sessionComplete': true,
        'mockLocationDetected': false,
        'issues': <String>[],
      });
      final files = (manifest['files'] as List).cast<Map<String, dynamic>>();
      expect(files.first, <String, Object?>{
        'name': 'a.mp4',
        'kind': 'clip',
        'bytes': 4,
        'sha256': sha256.convert(utf8.encode('aaaa')).toString(),
        'recordedSha256': sha256.convert(utf8.encode('aaaa')).toString(),
        'recorded': 'match',
        'locked': false,
      });
      expect(manifest['rideData'], <String, Object?>{
        'name': 'ride_s1.telemetry.json',
        'bytes': telemetry.lengthSync(),
        'sha256': sha256.convert(telemetry.readAsBytesSync()).toString(),
      });
      expect(manifest['notExported'], isEmpty);

      final readme = read.readme;
      final flat = _flat(readme);
      expect(
        flat,
        contains(
          'SIGNED: the ride data and the listed clip hashes were not changed '
          'after the holder of this key signed them (ECDSA P-256, SHA-256).',
        ),
      );
      expect(
        flat,
        contains(
          'The key was made by the phone and is not certified by anyone. It '
          'identifies the signer only if you already know this key from '
          'another source (for example the rider\'s earlier exports). It '
          'does not prove the footage is genuine: a rooted phone or a '
          'modified app can sign anything.',
        ),
      );
      expect(readme, contains('\n${phone.publicKeyBase64}\n'));
      expect(
        readme,
        contains('\n${rideSigningKeyFingerprintOf(phone.publicKeyBase64)}\n'),
      );
      expect(readme, contains('keyId: ${phone.keyId}'));
      expect(flat, contains('not the short keyId'));
      expect(flat, contains('The phone that made this export holds this key.'));
      expect(
        flat,
        contains(
          'Recorded-hash results mean something only when the integrity line '
          'is SIGNED or Unsigned.',
        ),
      );
      expect(
        flat,
        contains(
          '2 of 2 exported clips match their recorded hash; 0 differ; 0 have none.',
        ),
      );
      expect(readme, contains('Exported: 2026-11-19T13:05:00.000Z (UTC)'));
      final local = exportedAt.toLocal();
      expect(
        readme,
        contains(
          'Local time: ${local.year}-${_two(local.month)}-${_two(local.day)} '
          '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}',
        ),
      );
      expect(readme, contains('Incident at 03:20 not in any kept clip'));
      expect(readme, contains('  printf %s PAYLOADHASH > m'));
      expect(
        readme,
        contains('  openssl dgst -sha256 -verify pub.pem -signature sig.der m'),
      );
      expect(readme, contains('-----BEGIN PUBLIC KEY-----'));
      expect(flat, contains('sha256sum FILE'));
      expect(flat, contains('certutil -hashfile FILE SHA256'));
      expect(
        readme,
        contains(
          '\nhttps://github.com/Sarthak195/MotoCam/blob/v0.1.19/docs/data-formats.md\n',
        ),
      );
      expect(
        readme,
        contains(
          "check.py:\n\n"
          "import hashlib, json, sys\n"
          "d = json.load(open(sys.argv[1], encoding='utf-8'))\n"
          "i = dict(d['integrity'])\n"
          "stored = i.pop('payloadHash')\n"
          "v = i.get('envelopeVersion')\n"
          "if v == 3: i.pop('signature', None)\n"
          "if v in (2, 3): d['integrity'] = i\n"
          "else: del d['integrity']\n"
          "s = json.dumps(d, sort_keys=True, separators=(',', ':'), "
          "ensure_ascii=False)\n"
          "h = hashlib.sha256(s.encode('utf-8')).hexdigest()\n"
          "print(h, 'MATCH' if h == stored else 'MISMATCH')\n\n",
        ),
      );
      expect(readme, contains('\n  python3 check.py RIDEDATA '));
      expect(readme, contains('\n  py check.py RIDEDATA '));
      expect(
        flat,
        contains(
          'so a MISMATCH from this recipe or another JSON encoder alone is '
          'not proof of tampering.',
        ),
      );
      expect(
        flat,
        contains(
          '3. Verify the signature (SIGNED rides) in a POSIX shell (Linux, '
          'macOS, or Git Bash or WSL on Windows):',
        ),
      );
      expect(readme, contains('\n  Verified OK\n  Verification failure\n'));
      expect(readme, isNot(contains('another language')));
      expect(
        flat,
        contains(
          'The folder you pick is shared storage: other apps with media or '
          'storage access, and gallery backups, may see these files.',
        ),
      );
      expect(
        flat,
        contains(
          'A folder without MOTOCAM-EXPORT.txt is an incomplete export.',
        ),
      );
      expect(flat, contains('manifest.json and this file are not signed.'));
      expect(
        flat,
        contains(
          'All exports from this phone carry the same public key, so they '
          'can be linked to each other.',
        ),
      );
      for (final line in readme.split('\n')) {
        if (line.contains(' ') &&
            !line.startsWith('  ') &&
            !line.startsWith('Ride data:') &&
            !line.startsWith('Clips:') &&
            // A line of the Python recipe, never wrapped.
            !line.startsWith('s = json.dumps(')) {
          expect(line.length, lessThanOrEqualTo(72), reason: line);
        }
      }
    });

    test('an unsigned version 2 ride says checksums only', () async {
      final telemetry = await writeRide('s2', <File>[clip('a.mp4', 'aaaa')]);
      final read = await exportAndRead(await plan(telemetry, 's2'));
      final integrity = read.manifest['integrity'] as Map<String, dynamic>;
      expect(integrity['state'], 'checksums');
      expect(integrity['signedBy'], 'none');
      expect(integrity['envelopeVersion'], 2);
      expect(integrity.containsKey('signed'), isFalse);
      expect(integrity.containsKey('publicKey'), isFalse);
      expect(
        _flat(read.readme),
        contains(
          'Unsigned: SHA-256 checksums only. They show accidental corruption, '
          'not deliberate edits: anyone who can edit the files can recompute '
          'them.',
        ),
      );
      expect(read.readme, isNot(contains('Signer key')));
    });

    test('a version 1 ride says its clip checksums are not bound', () async {
      final telemetry = await writeRide('s3', <File>[
        clip('a.mp4', 'aaaa'),
      ], seal: _Seal.v1);
      final read = await exportAndRead(await plan(telemetry, 's3'));
      final integrity = read.manifest['integrity'] as Map<String, dynamic>;
      expect(integrity['state'], 'checksumsUnbound');
      expect(integrity['envelopeVersion'], 1);
      expect(
        _flat(read.readme),
        contains(
          'Older format: the clip checksums are not covered by the ride '
          'checksum, so they show accidental corruption of the clips only.',
        ),
      );
    });

    test('a modified signed ride is failed and shows no key', () async {
      final telemetry = await writeRide('s4', <File>[
        clip('a.mp4', 'aaaa'),
      ], seal: _Seal.v3);
      final json =
          jsonDecode(telemetry.readAsStringSync()) as Map<String, dynamic>;
      json['distanceKm'] = 99.0;
      telemetry.writeAsStringSync(jsonEncode(json));
      final read = await exportAndRead(await plan(telemetry, 's4'));
      final integrity = read.manifest['integrity'] as Map<String, dynamic>;
      expect(integrity['state'], 'failed');
      expect(integrity['signedBy'], 'none');
      expect(integrity['issues'], contains('payload-hash-mismatch'));
      for (final key in <String>['signed', 'alg', 'keyId', 'publicKey']) {
        expect(integrity.containsKey(key), isFalse, reason: key);
      }
      expect(
        _flat(read.readme),
        contains('INTEGRITY CHECK FAILED when exported: payload-hash-mismatch'),
      );
      expect(read.readme, isNot(contains(phone.publicKeyBase64)));
      expect(read.readme, isNot(contains('keyId:')));
    });

    test('a ride without an envelope has no integrity data', () async {
      final telemetry = await writeRide('s5', <File>[
        clip('a.mp4', 'aaaa'),
      ], seal: _Seal.none);
      final read = await exportAndRead(await plan(telemetry, 's5'));
      final integrity = read.manifest['integrity'] as Map<String, dynamic>;
      expect(integrity['state'], 'none');
      expect(integrity['envelopeVersion'], isNull);
      expect(
        _flat(read.readme),
        contains(
          'No integrity data (older ride format or a video-only recovery).',
        ),
      );
      expect(
        _flat(read.readme),
        contains(
          '0 of 1 exported clips match their recorded hash; 0 differ; 1 have none.',
        ),
      );
      expect(read.readme, isNot(contains('Every step is required.')));
      expect(
        _flat(read.readme),
        contains(
          'Only step 1 applies: this ride has no integrity data, so steps 2 '
          'and 3 (payloadHash and signature) do not apply.',
        ),
      );
    });

    test('a video-only export of a failed ride names only the state', () async {
      final telemetry = await writeRide('s8', <File>[
        clip('a.mp4', 'aaaa'),
      ], seal: _Seal.v3);
      final json =
          jsonDecode(telemetry.readAsStringSync()) as Map<String, dynamic>;
      json['distanceKm'] = 99.0;
      telemetry.writeAsStringSync(jsonEncode(json));
      final read = await exportAndRead(
        await plan(telemetry, 's8', includeRideData: false),
      );
      expect(read.manifest['integrity'], <String, Object?>{'state': 'failed'});
      expect(
        _flat(read.readme),
        contains(
          'The phone\'s integrity check of this ride failed when exported, '
          'so the recorded hashes listed below cannot be relied on.',
        ),
      );
      expect(read.readme, isNot(contains(phone.publicKeyBase64)));
      expect(jsonEncode(read.manifest), isNot(contains(phone.keyId)));
    });

    test('an incomplete ride and simulated GPS add their sentences', () async {
      final telemetry = await writeRide(
        's6',
        <File>[clip('a.mp4', 'aaaa')],
        sessionComplete: false,
        mock: true,
      );
      final read = await exportAndRead(await plan(telemetry, 's6'));
      final integrity = read.manifest['integrity'] as Map<String, dynamic>;
      expect(integrity['sessionComplete'], isFalse);
      expect(integrity['mockLocationDetected'], isTrue);
      final flat = _flat(read.readme);
      expect(
        flat,
        contains(
          'This ride ended without Stop: the ride data ends at its last '
          'checkpoint; clips recorded after it are separate rides and are '
          'not covered.',
        ),
      );
      expect(
        flat,
        contains(
          'SIMULATED GPS: the phone reported mock locations during this ride.',
        ),
      );
    });

    test('a video-only export carries no key material', () async {
      final a = clip('a.mp4', 'aaaa');
      final telemetry = await writeRide(
        's7',
        <File>[a, clip('b.mp4', 'bbbb')],
        locked: <File>[a],
        seal: _Seal.v3,
      );
      final p = await plan(
        telemetry,
        's7',
        clips: RideExportClips.evidence,
        includeRideData: false,
      );
      expect(p.folderName, 'MotoCam ride s7 (locked clips, video only)');
      expect(p.rideData, isNull);
      final read = await exportAndRead(p);
      expect(read.manifest['integrity'], isNull);
      expect(read.manifest['rideData'], isNull);
      expect(read.manifest['rideDataIncluded'], isFalse);
      expect(read.manifest['clips'], 'evidence');
      expect(read.manifest.containsKey('section'), isTrue);
      expect(read.manifest['section'], isNull);
      final files = (read.manifest['files'] as List)
          .cast<Map<String, dynamic>>();
      expect(files.single['recordedSha256'], isNotNull);
      expect(files.single['locked'], isTrue);
      expect(read.manifest['notExported'], <Object?>[
        <String, Object?>{
          'name': 'b.mp4',
          'recordedSha256': sha256.convert(utf8.encode('bbbb')).toString(),
          'reason': 'notSelected',
        },
      ]);
      final fingerprint = rideSigningKeyFingerprintOf(phone.publicKeyBase64)!;
      final manifestText = jsonEncode(read.manifest);
      for (final secret in <String>[
        phone.publicKeyBase64,
        phone.keyId,
        fingerprint,
      ]) {
        expect(manifestText, isNot(contains(secret)));
        expect(read.readme, isNot(contains(secret)));
      }
      expect(namesIn(exportFolder(p)), <String>[
        'MOTOCAM-EXPORT.txt',
        'a.mp4',
        'manifest.json',
      ]);
    });

    test('a section exports its files, without ride data or key '
        'material', () async {
      final a = clip('a.mp4', 'aaaa');
      final b = clip('b.mp4', 'bbbb');
      final c = clip('c.mp4', 'cccc');
      final d = clip('d.mp4', 'dddd');
      final telemetry = await writeRide(
        's9',
        <File>[a, b, c, d],
        locked: <File>[b],
        seal: _Seal.v3,
        mock: true,
        sessionComplete: false,
      );
      // d is gone; a section from 00:30 to 03:30 cuts a and d.
      d.deleteSync();
      final p = await plan(
        telemetry,
        's9',
        clips: RideExportClips.section,
        section: const RideExportSection(30000, 210000),
      );
      expect(p.folderName, 'MotoCam ride s9 (section 00m30s to 03m30s)');
      final read = await exportAndRead(p);
      expect(namesIn(exportFolder(p)), <String>[
        'MOTOCAM-EXPORT.txt',
        'a.mp4',
        'b.mp4',
        'c.mp4',
        'manifest.json',
      ]);
      final folder = exportFolder(p).path;
      String hashOf(String name) => sha256
          .convert(File('$folder$_sep$name').readAsBytesSync())
          .toString();
      final manifest = read.manifest;
      expect(manifest['format'], 'motocam-ride-export');
      expect(manifest['clips'], 'section');
      expect(manifest['section'], <String, Object?>{
        'fromMs': 30000,
        'toMs': 210000,
        // a's trim snapped back to the keyframe at 29.4 s.
        'actualFromMs': 29400,
      });
      expect(manifest['rideDataIncluded'], isFalse);
      expect(manifest['rideData'], isNull);
      expect(manifest['integrity'], isNull);
      expect(manifest['sha256Of'], 'copy');
      expect(manifest['files'], <Object?>[
        <String, Object?>{
          'name': 'a.mp4',
          'bytes': File('$folder${_sep}a.mp4').lengthSync(),
          'sha256': hashOf('a.mp4'),
          'trimmed': true,
          'clipFromMs': 29400,
          'clipToMs': 59800,
        },
        <String, Object?>{
          'name': 'b.mp4',
          'bytes': 4,
          'sha256': sha256.convert(utf8.encode('bbbb')).toString(),
          'trimmed': false,
          'clipFromMs': 0,
          'clipToMs': 59800,
        },
        <String, Object?>{
          'name': 'c.mp4',
          'bytes': 4,
          'sha256': hashOf('c.mp4'),
          'trimmed': false,
          'clipFromMs': 0,
          'clipToMs': 59800,
        },
      ]);
      expect(manifest['notExported'], <Object?>[
        <String, Object?>{'name': 'd.mp4', 'reason': 'missing'},
      ]);

      final readme = read.readme;
      final ride = p.source.ride;
      expect(readme, contains('Ride: s9\n'));
      expect(
        readme,
        contains(
          'Section: 00:30 to 03:30 of the ride (clock time '
          '${rideExportClockText(ride, 30000)} to '
          '${rideExportClockText(ride, 210000)})\n',
        ),
      );
      expect(readme, contains('Ride data: not included (video only)\n'));
      expect(
        readme,
        contains(
          'a.mp4 (trimmed)\n'
          '  In the clip: 00:29.400 to 00:59.800\n'
          '  ${File('$folder${_sep}a.mp4').lengthSync()} bytes\n'
          '  SHA-256: ${hashOf('a.mp4')}\n'
          'b.mp4 (whole clip)\n'
          '  In the clip: 00:00.000 to 00:59.800\n'
          '  4 bytes\n',
        ),
      );
      expect(readme, contains('d.mp4: missing on the phone\n'));
      final flat = _flat(readme);
      expect(
        flat,
        contains(
          'Files keep their original clip names. Trimmed files are cut '
          'copies made without re-encoding: they are not the original '
          'recordings and do not match the original clips\' checksums. This '
          'export carries no ride data and no signature.',
        ),
      );
      expect(
        flat,
        contains(
          'Videos show other road users: share them only for your own '
          'records, the police or your insurer.',
        ),
      );
      expect(flat, contains('The folder you pick is shared storage'));
      for (final text in <String>[
        'Integrity',
        'SIGNED',
        'Recorded hash',
        'Recorded-hash',
        'How to check',
        'openssl',
        'payloadHash',
        'Public key',
        'keyId',
        'Fingerprint',
        'SIMULATED GPS',
        'ended without Stop',
        'same public key',
        'ride_s9.telemetry.json',
      ]) {
        expect(readme, isNot(contains(text)), reason: text);
      }
      final manifestText = jsonEncode(manifest);
      expect(manifestText, isNot(contains(phone.publicKeyBase64)));
      expect(readme, isNot(contains(phone.publicKeyBase64)));
      expect(manifestText, isNot(contains('recordedSha256')));
      expect(manifestText, isNot(contains('keyId')));
    });

    test('a section shared from Playback names the share sheet in its '
        'README', () async {
      final telemetry = await writeRide('s10', <File>[clip('a.mp4', 'aaaa')]);
      final p = await plan(
        telemetry,
        's10',
        clips: RideExportClips.section,
        section: const RideExportSection(1000, 2000),
      );
      final readme = buildExportReadme(
        p,
        clips: const <RideExportFileEntry>[],
        rideData: null,
        destination: RideExportDestination.share,
        exportedAt: exportedAt,
      );
      expect(readme, contains('Destination: the Android share sheet\n'));
      expect(readme, isNot(contains('The folder you pick')));
      final manifest = buildExportManifest(
        p,
        clips: const <RideExportFileEntry>[],
        rideData: null,
        destination: RideExportDestination.share,
        exportedAt: exportedAt,
      );
      expect(manifest['sha256Of'], 'source');
      expect(manifest['section'], <String, Object?>{
        'fromMs': 1000,
        'toMs': 2000,
        'actualFromMs': null,
      });
    });

    test('a video-only recovery exports its video without ride data', () async {
      final video = clip('REC_9.mp4', 'video');
      final ride = await RideRecord.fromVideoFile(video, loadSamples: false);
      final source = await loadRideExportSource(ride);
      expect(source.hasRideData, isFalse);
      final p = await planRideExport(
        source,
        clips: RideExportClips.all,
        includeRideData: true,
      );
      expect(p.includeRideData, isFalse);
      expect(p.folderName, 'MotoCam ride REC_9 (all clips, video only)');
      final read = await exportAndRead(p);
      expect(read.manifest['integrity'], <String, Object?>{'state': 'none'});
      expect(
        _flat(read.readme),
        contains(
          'This ride has no integrity data, so the recorded hashes listed '
          'below cannot be relied on.',
        ),
      );
      expect(
        _flat(read.readme),
        contains(
          'No integrity data (older ride format or a video-only recovery).',
        ),
      );
    });

    test('issue strings lose private paths and control characters', () {
      expect(
        sanitizeExportIssue(
          'segment-hash-mismatch:/data/user/0/com.example.motocam/files/'
          'MotoCam Recordings/REC_1.mp4',
        ),
        'segment-hash-mismatch:REC_1.mp4',
      );
      expect(sanitizeExportIssue('bad\nline\u0007'), 'badline');
      expect(sanitizeExportIssue('x' * 200).length, 80);
      expect(
        sanitizeExportIssue('quarantined-segment-paths:2'),
        'quarantined-segment-paths:2',
      );
    });

    test('names and recorded hashes cannot inject README lines', () async {
      final kept = '${rides.path}${_sep}a\nINJECTED: kept\u202E.mp4';
      final gone = '${rides.path}${_sep}b\r\nINJECTED: gone.mp4';
      final ride = RideRecord(
        videoPath: gone,
        segmentPaths: <String>[kept, gone],
        lockedSegmentPaths: const <String>[],
        createdAt: DateTime.utc(2026, 11, 19, 10),
        telemetryPath: null,
        rideSessionId: 'r\nINJECTED: id${'x' * 300}',
        isSessionComplete: true,
        distanceKm: 0,
        maxSpeedKmh: 0,
        averageSpeedKmh: 0,
        segmentTimeline: const <RideSegmentTimelineEntry>[],
        samples: const [],
        integrity: const RideIntegrityReport.verified(),
        quarantinedSegmentPaths: const <String>[],
        expectedSegmentHashes: <String, String>{
          kept: 'junk\nINJECTED: Recorded hash: matches',
          gone: 'A' * 64,
        },
      );
      final p = await planRideExport(
        RideExportSource(ride: ride, envelopeVersion: 2),
        clips: RideExportClips.all,
        includeRideData: true,
        stat: (path) async => path == kept
            ? const RideFileStamp(size: 4, modifiedUs: 0, changedUs: 0)
            : null,
      );
      expect(p.clips.single.recordedSha256, isNull);
      expect(p.clips.single.recordedInvalid, isTrue);
      expect(p.notExported.single.recordedSha256, isNull);
      expect(p.notExported.single.recordedInvalid, isTrue);
      final clips = <RideExportFileEntry>[
        for (final item in p.clips)
          RideExportFileEntry(
            name: item.name,
            bytes: item.bytes,
            sha256: 'b' * 64,
            recordedSha256: item.recordedSha256,
            recordedInvalid: item.recordedInvalid,
          ),
      ];
      final at = DateTime.utc(2026, 11, 19, 13, 5, 0, 123, 456);
      final readme = buildExportReadme(
        p,
        clips: clips,
        rideData: null,
        destination: RideExportDestination.folder,
        exportedAt: at,
      );
      final lines = readme.split('\n');
      for (final line in lines) {
        expect(line, isNot(startsWith('INJECTED')));
        expect(line, isNot(contains('\r')));
      }
      expect(readme, isNot(contains('\u202E')));
      expect(readme, isNot(contains('junk')));
      expect(readme, isNot(contains('A' * 64)));
      expect(readme, contains('  Recorded hash: invalid'));
      expect(readme, contains('  Recorded SHA-256: invalid'));
      expect(readme, contains('0 differ; 1 have none.'));
      final rideLine = lines.firstWhere((l) => l.startsWith('Ride: '));
      expect(rideLine.length, 'Ride: '.length + 120);
      expect(readme, contains('Exported: 2026-11-19T13:05:00.123Z (UTC)'));

      final manifest = buildExportManifest(
        p,
        clips: clips,
        rideData: null,
        destination: RideExportDestination.folder,
        exportedAt: at,
      );
      expect(manifest['exportedAt'], '2026-11-19T13:05:00.123Z');
      final file = (manifest['files'] as List).single as Map<String, Object?>;
      expect(file['recordedSha256'], isNull);
      expect(file['recorded'], 'none');
      final omitted =
          (manifest['notExported'] as List).single as Map<String, Object?>;
      expect(omitted.containsKey('recordedSha256'), isFalse);
      expect(omitted.containsKey('recorded'), isFalse);
    });
  });

  group('export source', () {
    test('a ride file that cannot be decoded is refused', () async {
      // The source is read in an isolate; the failure carries the rider's
      // sentence.
      final telemetry = File('${rides.path}${_sep}ride_bad.telemetry.json')
        ..writeAsStringSync('{not json');
      final ride = RideRecord(
        videoPath: '${rides.path}${_sep}a.mp4',
        segmentPaths: <String>['${rides.path}${_sep}a.mp4'],
        lockedSegmentPaths: const <String>[],
        createdAt: DateTime(2026, 11, 19),
        telemetryPath: telemetry.path,
        rideSessionId: 'bad',
        isSessionComplete: true,
        distanceKm: 0,
        maxSpeedKmh: 0,
        averageSpeedKmh: 0,
        segmentTimeline: const <RideSegmentTimelineEntry>[],
        samples: const [],
        integrity: const RideIntegrityReport.unknown(),
        quarantinedSegmentPaths: const <String>[],
      );
      await expectLater(
        loadRideExportSource(ride),
        throwsA(
          isA<RideExportFailure>()
              .having((f) => f.code, 'code', 'SOURCE_UNREADABLE')
              .having(
                (f) => f.message,
                'message',
                'The ride file could not be read.',
              ),
        ),
      );
    });

    test('the source keeps the hash and the signature facts', () async {
      final telemetry = await writeRide('h1', <File>[
        clip('a.mp4', 'aaaa'),
      ], seal: _Seal.v3);
      final source = await loadRideExportSource(
        await screenRecord(telemetry, 'h1'),
      );
      expect(
        source.rideDataSha256,
        sha256.convert(telemetry.readAsBytesSync()).toString(),
      );
      expect(source.rideDataBytes, telemetry.lengthSync());
      expect(source.envelopeVersion, 3);
      expect(source.signatureAlg, 'ES256');
      expect(source.signatureKeyId, phone.keyId);
      expect(source.ride.integrity.signedBy, RideSignedBy.thisDevice);
      expect(source.ride.samplesLoaded, isFalse);
    });
  });

  group('share', () {
    test(
      'hashes each file, stages the text files and opens the sheet',
      () async {
        final telemetry = await writeRide('sh1', <File>[
          clip('a.mp4', 'aaaa'),
          clip('b.mp4', 'bbbb'),
        ]);
        final p = await plan(telemetry, 'sh1');
        final old = Directory('${cache.path}${_sep}ride_export${_sep}old-1')
          ..createSync(recursive: true);
        final native = _FakeNative(tree);
        final later = DateTime.now().add(const Duration(days: 2));
        final result = await exporter(native, now: () => later).share(p);

        expect(result.outcome, RideExportOutcome.done);
        expect(old.existsSync(), isFalse);
        expect(native.calls, <String>[
          'hash:a.mp4',
          'hash:b.mp4',
          'hash:ride_sh1.telemetry.json',
          'share',
        ]);
        final paths = native.sharedPaths!;
        expect(paths.length, 5);
        expect(paths.take(3), <String>[
          '${rides.path}${_sep}a.mp4',
          '${rides.path}${_sep}b.mp4',
          telemetry.path,
        ]);
        final staging =
            '${cache.path}${_sep}ride_export$_sep${p.folderName}-'
            '${later.millisecondsSinceEpoch}';
        expect(paths.skip(3), <String>[
          '$staging${_sep}manifest.json',
          '$staging${_sep}MOTOCAM-EXPORT.txt',
        ]);
        expect(native.sharedMimeTypes, <String>[
          'video/mp4',
          'video/mp4',
          'application/json',
          'application/json',
          'text/plain',
        ]);
        final manifest =
            jsonDecode(File(paths[3]).readAsStringSync())
                as Map<String, dynamic>;
        expect(manifest['destination'], 'share');
        expect(manifest['sha256Of'], 'source');
        final readme = File(paths[4]).readAsStringSync();
        expect(readme, isNot(contains('The folder you pick')));
        expect(
          rideExportSummary(result),
          'Opened the share sheet with 5 files. Check that the receiving app '
          'got all of them.',
        );
      },
    );

    test('a file that cannot be read shares nothing', () async {
      final telemetry = await writeRide('sh2', <File>[clip('a.mp4', 'aaaa')]);
      final p = await plan(telemetry, 'sh2');
      final native = _FakeNative(tree)..fail['a.mp4'] = 'READ_FAILED';
      final result = await exporter(native).share(p);
      expect(result.outcome, RideExportOutcome.failed);
      expect(result.failureCode, 'READ_FAILED');
      expect(native.sharedPaths, isNull);
      expect(
        Directory('${cache.path}${_sep}ride_export').existsSync(),
        isFalse,
      );
    });

    test('a ride file that changed is not shared', () async {
      final telemetry = await writeRide('sh3', <File>[clip('a.mp4', 'aaaa')]);
      final p = await plan(telemetry, 'sh3');
      telemetry.writeAsStringSync('${telemetry.readAsStringSync()} ');
      final native = _FakeNative(tree);
      final result = await exporter(native).share(p);
      expect(result.outcome, RideExportOutcome.failed);
      expect(result.failureCode, 'RIDE_DATA_CHANGED');
      expect(native.sharedPaths, isNull);
    });

    test('a recording that starts stops the share', () async {
      final telemetry = await writeRide('sh4', <File>[clip('a.mp4', 'aaaa')]);
      final p = await plan(telemetry, 'sh4');
      var recording = false;
      final native = _FakeNative(tree)
        ..slow.add('a.mp4')
        ..during = (_) => recording = true;
      final result = await exporter(
        native,
        shouldPause: () => recording,
      ).share(p);
      expect(result.outcome, RideExportOutcome.paused);
      expect(native.sharedPaths, isNull);
      expect(
        rideExportSummary(result),
        'Share stopped because a recording started. Run it again.',
      );
    });
  });
}
