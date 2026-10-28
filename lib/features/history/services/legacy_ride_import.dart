// lib/features/history/services/legacy_ride_import.dart
//
// Imports rides from the public folder that v0.1.11 and v0.1.12 recorded
// to (Movies/MotoCam/Recordings, Android only), through a picked Storage
// Access Framework tree, into the private recordings root. It follows the
// recordings migration's rules (staging outside every scanned root, size
// checks, rename into place, a journal replaced atomically, the JSON last
// and byte for byte, collisions by name and size) but never deletes a
// source: deleting the originals is a separate, confirmed step.
// [LegacyRideImporter] is free of platform code (the documents come from a
// [LegacyRideDocumentSource]); [LegacyRideImportController] holds the state
// the UI shows. CameraProvider decides when an import may run.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/ride_file/ride_telemetry_codec.dart' as ride_codec;
import '../../../core/services/legacy_recordings_access.dart';
import '../../../core/utils/integrity_utils.dart' as integrity_utils;
import '../../../core/utils/path_utils.dart' as path_utils;

/// Name of the journal file inside the import work directory.
const String legacyImportJournalFileName = 'import_journal.json';

/// Name of the staging directory inside the import work directory.
const String legacyImportStagingDirectoryName = 'staging';

/// Suffix of a file being copied into staging. Like the migration's, it is
/// never `.tmp`, `.telemetry.json` or a video extension.
const String legacyImportStagingSuffix = '.importing';

/// Why a ride (or a lone video) was not imported.
enum LegacyImportSkipReason {
  /// A different file with the same name is already in private storage.
  nameCollision,

  /// A file could not be copied or its copy did not match.
  copyFailed,
}

/// A ride (by its JSON name, or a lone video's name) that was not imported.
@immutable
class LegacyImportSkip {
  /// Creates a skip record.
  const LegacyImportSkip({required this.name, required this.reason});

  /// File name of the ride JSON or the lone video.
  final String name;

  /// Why it was not imported.
  final LegacyImportSkipReason reason;
}

/// How an import run ended.
enum LegacyImportOutcome {
  /// Every ride was handled (imported, already there, skipped or failed).
  completed,

  /// Recording started (or the app is closing); the rest was not imported.
  paused,

  /// Private storage has no room for the next file plus the reserve.
  lowStorage,

  /// The folder could not be listed.
  listFailed,
}

/// Progress of a run: [done] of [total] rides and lone videos.
@immutable
class LegacyImportProgress {
  /// Creates a progress record.
  const LegacyImportProgress({
    required this.done,
    required this.total,
    this.inFlightPaths = const <String>{},
  });

  /// Rides and lone videos handled so far.
  final int done;

  /// Rides and lone videos found in the folder.
  final int total;

  /// Normalised destination paths of the ride being imported now; empty
  /// between rides. Ride History hides them until the ride is whole.
  final Set<String> inFlightPaths;
}

/// What an import run did.
@immutable
class LegacyImportSummary {
  /// Creates a summary.
  const LegacyImportSummary({
    required this.outcome,
    required this.total,
    required this.imported,
    required this.alreadyImported,
    required this.skipped,
    required this.remaining,
    required this.importedDocuments,
  });

  /// How the run ended.
  final LegacyImportOutcome outcome;

  /// Rides and lone videos found in the folder.
  final int total;

  /// Rides and lone videos copied into private storage in this run.
  final int imported;

  /// Rides and lone videos whose files were already in private storage
  /// with the same name and size (for a JSON, the same bytes).
  final int alreadyImported;

  /// Rides and lone videos left out, and why.
  final List<LegacyImportSkip> skipped;

  /// Rides and lone videos not handled because the run stopped.
  final int remaining;

  /// Documents with a verified copy in private storage (imported now or
  /// already there): the only ones the rider may delete afterwards.
  final List<LegacyRideDocument> importedDocuments;

  /// Rides left out because a different file with the same name exists.
  int get collisions => skipped
      .where((skip) => skip.reason == LegacyImportSkipReason.nameCollision)
      .length;

  /// Rides left out because a copy failed.
  int get failed => skipped
      .where((skip) => skip.reason == LegacyImportSkipReason.copyFailed)
      .length;

  /// Rider-facing summary, for example 'Imported 3 rides. 1 ride was
  /// skipped: a different file with the same name is already in private
  /// storage.'.
  String get message {
    String rides(int n) => '$n ride${n == 1 ? '' : 's'}';
    if (outcome == LegacyImportOutcome.listFailed) {
      return 'Could not read the selected folder. Nothing was imported.';
    }
    final sentences = <String>[];
    if (total == 0) {
      sentences.add('No rides were found in the selected folder');
    } else {
      sentences.add('Imported ${rides(imported)}');
      if (alreadyImported > 0) {
        sentences.add('${rides(alreadyImported)} had been imported before');
      }
    }
    if (collisions > 0) {
      sentences.add(
        '${rides(collisions)} skipped: a different file with the same name '
        'is already in private storage',
      );
    }
    if (failed > 0) {
      sentences.add('${rides(failed)} failed: a file could not be copied');
    }
    switch (outcome) {
      case LegacyImportOutcome.paused:
        sentences.add(
          'The import stopped because recording started; import again to '
          'continue with the remaining ${rides(remaining)}',
        );
      case LegacyImportOutcome.lowStorage:
        sentences.add(
          'Not enough free space for the remaining ${rides(remaining)}',
        );
      case LegacyImportOutcome.completed:
      case LegacyImportOutcome.listFailed:
        break;
    }
    return '${sentences.join('. ')}.';
  }
}

/// A ride (its videos, then its JSON) or a lone video in the folder.
class _ImportUnit {
  _ImportUnit({required this.name, required this.videos, this.json});

  final String name;
  final List<LegacyRideDocument> videos;
  final LegacyRideDocument? json;

  List<LegacyRideDocument> get documents => <LegacyRideDocument>[
    ...videos,
    ?json,
  ];
}

enum _UnitResult {
  imported,
  alreadyThere,
  collision,
  failed,
  paused,
  lowStorage,
}

class _Paused implements Exception {
  const _Paused();
}

/// Imports the rides of one picked folder ([source]) into [recordingsRoot].
///
/// Planning: every ride JSON (`*.telemetry.json`, not a temp file) is
/// copied to staging and read; its videos are the folder's video files
/// named by its `segmentPaths` and `videoPath` (by file name), or the
/// `<base>.mp4` of a legacy-named `<base>.telemetry.json`. Videos no ride
/// names are imported one by one. Other files and names with a path
/// separator are ignored.
///
/// For each ride: if a file with the same name is already in
/// [recordingsRoot], it counts as already imported only when its size
/// matches (for the JSON, its bytes); otherwise the whole ride is skipped
/// and reported. The free space of [recordingsRoot]'s volume must cover
/// the files still to copy plus [reserveBytes] ([freeBytes] `null` means
/// unknown and does not block). Each video is streamed into a staging file
/// under [workDirectory], checked against the size the provider reported
/// and the bytes copied, renamed into [recordingsRoot] and checked again;
/// the JSON goes last, byte for byte, so its `payloadHash` and signature
/// stay valid. A source is never modified or deleted.
///
/// [shouldPause] is checked before each ride and file and, while a copy
/// runs, every [pollInterval]; the copy is then cancelled, its staging
/// file deleted, and the run returns [LegacyImportOutcome.paused].
///
/// The journal in [workDirectory] (replaced atomically) names the ride in
/// flight; the next run imports it first. Staging is discarded at the
/// start of each run, so no file is ever left only in staging.
class LegacyRideImporter {
  /// Creates an importer. [workDirectory] must lie outside
  /// [recordingsRoot].
  LegacyRideImporter({
    required this.source,
    required this.recordingsRoot,
    required this.workDirectory,
    required this.freeBytes,
    required this.reserveBytes,
    bool Function()? shouldPause,
    this.pollInterval = const Duration(milliseconds: 200),
  }) : shouldPause = shouldPause ?? _never {
    if (path_utils.isPathInsideDirectory(workDirectory, recordingsRoot)) {
      throw ArgumentError.value(
        workDirectory,
        'workDirectory',
        'must not lie inside the recordings root',
      );
    }
  }

  static bool _never() => false;

  /// The picked folder.
  final LegacyRideDocumentSource source;

  /// The private recordings root rides are imported into.
  final String recordingsRoot;

  /// Holds the journal and the staging directory.
  final String workDirectory;

  /// Free bytes on the volume that holds the given path, or `null`.
  final Future<int?> Function(String path) freeBytes;

  /// Bytes that must stay free after each copy.
  final int reserveBytes;

  /// Whether the run must stop now.
  final bool Function() shouldPause;

  /// How often [shouldPause] is checked while a copy runs.
  final Duration pollInterval;

  String get _sep => Platform.pathSeparator;

  String get _journalPath => '$workDirectory$_sep$legacyImportJournalFileName';

  String get _stagingPath =>
      '$workDirectory$_sep$legacyImportStagingDirectoryName';

  String _destinationFor(String name) => '$recordingsRoot$_sep$name';

  String _stagingFor(String name) =>
      '$_stagingPath$_sep$name$legacyImportStagingSuffix';

  static bool _isSafeName(String name) =>
      name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.contains('/') &&
      !name.contains('\\');

  static bool _isRideJsonName(String name) =>
      name.toLowerCase().endsWith(ride_codec.rideTelemetryFileSuffix) &&
      !integrity_utils.isTelemetryTempFilePath(name);

  /// Runs the import and reports progress through [onProgress].
  Future<LegacyImportSummary> run({
    void Function(LegacyImportProgress progress)? onProgress,
  }) async {
    final journal = await _readJournal();
    await _discardStaging();

    List<LegacyRideDocument> documents;
    try {
      documents = await source.list();
    } catch (_) {
      return const LegacyImportSummary(
        outcome: LegacyImportOutcome.listFailed,
        total: 0,
        imported: 0,
        alreadyImported: 0,
        skipped: <LegacyImportSkip>[],
        remaining: 0,
        importedDocuments: <LegacyRideDocument>[],
      );
    }

    List<_ImportUnit> units;
    try {
      units = await _plan(documents, journal);
    } on _Paused {
      await _discardStaging();
      return LegacyImportSummary(
        outcome: LegacyImportOutcome.paused,
        total: 0,
        imported: 0,
        alreadyImported: 0,
        skipped: const <LegacyImportSkip>[],
        remaining: 0,
        importedDocuments: const <LegacyRideDocument>[],
      );
    }

    final total = units.length;
    var done = 0;
    var imported = 0;
    var alreadyThere = 0;
    final skipped = <LegacyImportSkip>[];
    final verified = <LegacyRideDocument>[];
    var outcome = LegacyImportOutcome.completed;
    onProgress?.call(LegacyImportProgress(done: 0, total: total));

    for (final unit in units) {
      if (shouldPause()) {
        outcome = LegacyImportOutcome.paused;
        break;
      }
      onProgress?.call(
        LegacyImportProgress(
          done: done,
          total: total,
          inFlightPaths: <String>{
            for (final document in unit.documents)
              path_utils.normalizePath(_destinationFor(document.name)),
          },
        ),
      );
      final result = await _importUnit(unit);
      if (result == _UnitResult.paused) {
        outcome = LegacyImportOutcome.paused;
        break;
      }
      if (result == _UnitResult.lowStorage) {
        outcome = LegacyImportOutcome.lowStorage;
        break;
      }
      switch (result) {
        case _UnitResult.imported:
          imported++;
          verified.addAll(unit.documents);
        case _UnitResult.alreadyThere:
          alreadyThere++;
          verified.addAll(unit.documents);
        case _UnitResult.collision:
          skipped.add(
            LegacyImportSkip(
              name: unit.name,
              reason: LegacyImportSkipReason.nameCollision,
            ),
          );
        case _UnitResult.failed:
          skipped.add(
            LegacyImportSkip(
              name: unit.name,
              reason: LegacyImportSkipReason.copyFailed,
            ),
          );
        case _UnitResult.paused:
        case _UnitResult.lowStorage:
          break;
      }
      done++;
      onProgress?.call(LegacyImportProgress(done: done, total: total));
    }

    await _discardStaging();
    return LegacyImportSummary(
      outcome: outcome,
      total: total,
      imported: imported,
      alreadyImported: alreadyThere,
      skipped: List<LegacyImportSkip>.unmodifiable(skipped),
      remaining: total - done,
      importedDocuments: List<LegacyRideDocument>.unmodifiable(verified),
    );
  }

  /// Groups [documents] into rides (videos, then the JSON) and lone videos;
  /// the journal's ride in flight goes first.
  Future<List<_ImportUnit>> _plan(
    List<LegacyRideDocument> documents,
    Map<String, dynamic> journal,
  ) async {
    final byName = <String, LegacyRideDocument>{};
    for (final document in documents) {
      if (_isSafeName(document.name)) {
        byName.putIfAbsent(document.name, () => document);
      }
    }
    final names = byName.keys.toList()..sort();
    final claimed = <String>{};
    final units = <_ImportUnit>[];
    for (final name in names) {
      if (!_isRideJsonName(name)) {
        continue;
      }
      final json = byName[name]!;
      claimed.add(name);
      final videos = <LegacyRideDocument>[];
      for (final videoName in await _declaredVideoNames(json)) {
        final video = byName[videoName];
        if (video != null &&
            ride_codec.isRideVideoFilePath(videoName) &&
            claimed.add(videoName)) {
          videos.add(video);
        }
      }
      units.add(_ImportUnit(name: name, videos: videos, json: json));
    }
    for (final name in names) {
      if (ride_codec.isRideVideoFilePath(name) && claimed.add(name)) {
        units.add(
          _ImportUnit(name: name, videos: <LegacyRideDocument>[byName[name]!]),
        );
      }
    }
    final inFlight = journal['ride'];
    if (inFlight is Map && inFlight['name'] is String) {
      final index = units.indexWhere((unit) => unit.name == inFlight['name']);
      if (index > 0) {
        units.insert(0, units.removeAt(index));
      }
    }
    return units;
  }

  /// File names the ride JSON [json] declares as its videos, in order; an
  /// unreadable JSON declares none (it is still imported, as it is).
  Future<List<String>> _declaredVideoNames(LegacyRideDocument json) async {
    final staged = File(_stagingFor(json.name));
    final names = <String>[];
    try {
      await Directory(_stagingPath).create(recursive: true);
      await _copyWithPause(json, staged.path);
      final decoded = await ride_codec.readRideFileJson(staged);
      if (decoded != null) {
        final rawSegments = decoded['segmentPaths'];
        final declared = ride_codec.normalizeSegmentPathList(
          rawSegments is List ? rawSegments : const <Object?>[],
        );
        final videoPath = decoded['videoPath']?.toString().trim() ?? '';
        if (videoPath.isNotEmpty) {
          declared.add(videoPath);
        }
        for (final path in declared) {
          final name = path_utils.fileNameFromPath(path.replaceAll('\\', '/'));
          if (_isSafeName(name) && !names.contains(name)) {
            names.add(name);
          }
        }
      }
    } on _Paused {
      rethrow;
    } catch (_) {
      // Unreadable: no declared videos.
    } finally {
      await _deleteQuietly(staged);
    }
    // A legacy `<video base>.telemetry.json` names its video by its own.
    final base = json.name.substring(
      0,
      json.name.length - ride_codec.rideTelemetryFileSuffix.length,
    );
    for (final extension in ride_codec.rideVideoFileExtensions) {
      final candidate = '$base$extension';
      if (!names.contains(candidate)) {
        names.add(candidate);
      }
    }
    return names;
  }

  Future<_UnitResult> _importUnit(_ImportUnit unit) async {
    // Collisions are checked for the whole ride before anything is copied.
    final toCopy = <LegacyRideDocument>[];
    var bytesToCopy = 0;
    try {
      for (final video in unit.videos) {
        final destination = File(_destinationFor(video.name));
        if (await destination.exists()) {
          final size = video.size;
          if (size == null || await destination.length() != size) {
            return _UnitResult.collision;
          }
          continue;
        }
        toCopy.add(video);
        bytesToCopy += video.size ?? 0;
      }
      final json = unit.json;
      var jsonThere = false;
      if (json != null) {
        final destination = File(_destinationFor(json.name));
        if (await destination.exists()) {
          final staged = await _stage(json);
          if (staged == null) {
            return _UnitResult.failed;
          }
          final same = listEquals(
            await staged.readAsBytes(),
            await destination.readAsBytes(),
          );
          await _deleteQuietly(staged);
          if (!same) {
            return _UnitResult.collision;
          }
          jsonThere = true;
        } else {
          bytesToCopy += json.size ?? 0;
        }
      }
      if (toCopy.isEmpty && (json == null || jsonThere)) {
        return _UnitResult.alreadyThere;
      }
      if (!await _hasRoomFor(bytesToCopy)) {
        return _UnitResult.lowStorage;
      }

      await _writeJournal(<String, dynamic>{
        'version': 1,
        'ride': <String, dynamic>{
          'name': unit.name,
          'files': <String>[for (final d in unit.documents) d.name],
        },
      });
      for (final video in toCopy) {
        if (shouldPause()) {
          return _UnitResult.paused;
        }
        final result = await _importFile(video);
        if (result != _UnitResult.imported) {
          return result;
        }
      }
      if (json != null && !jsonThere) {
        if (shouldPause()) {
          return _UnitResult.paused;
        }
        final result = await _importFile(json, isJson: true);
        if (result != _UnitResult.imported) {
          return result;
        }
      }
      await _writeJournal(<String, dynamic>{'version': 1, 'ride': null});
      return _UnitResult.imported;
    } on _Paused {
      return _UnitResult.paused;
    } on FileSystemException {
      return _UnitResult.failed;
    }
  }

  /// Copies [document] into staging and checks its size; returns the
  /// staging file, or `null` when the copy failed (the staging file is
  /// then deleted). Throws [_Paused].
  Future<File?> _stage(LegacyRideDocument document) async {
    final staged = File(_stagingFor(document.name));
    try {
      await Directory(_stagingPath).create(recursive: true);
      final copied = await _copyWithPause(document, staged.path);
      final length = await staged.length();
      final expected = document.size;
      if (length != copied || (expected != null && length != expected)) {
        await _deleteQuietly(staged);
        return null;
      }
      return staged;
    } on _Paused {
      await _deleteQuietly(staged);
      rethrow;
    } catch (_) {
      await _deleteQuietly(staged);
      return null;
    }
  }

  Future<_UnitResult> _importFile(
    LegacyRideDocument document, {
    bool isJson = false,
  }) async {
    final staged = await _stage(document);
    if (staged == null) {
      return _UnitResult.failed;
    }
    final destination = File(_destinationFor(document.name));
    final size = await staged.length();
    // A file that appeared since the check is never overwritten.
    if (await destination.exists()) {
      await _deleteQuietly(staged);
      return _UnitResult.collision;
    }
    await Directory(recordingsRoot).create(recursive: true);
    await staged.rename(destination.path);
    if (await destination.length() != size) {
      return _UnitResult.failed;
    }
    return _UnitResult.imported;
  }

  /// Copies [document] to [targetPath], cancelling the copy when
  /// [shouldPause] turns true. Throws [_Paused] then.
  Future<int> _copyWithPause(
    LegacyRideDocument document,
    String targetPath,
  ) async {
    if (shouldPause()) {
      throw const _Paused();
    }
    var cancelled = false;
    final poll = Timer.periodic(pollInterval, (_) {
      if (!cancelled && shouldPause()) {
        cancelled = true;
        unawaited(source.cancelCopy());
      }
    });
    try {
      return await source.copyTo(document, targetPath);
    } on LegacyCopyCancelled {
      throw const _Paused();
    } finally {
      poll.cancel();
    }
  }

  Future<bool> _hasRoomFor(int bytes) async {
    int? free;
    try {
      free = await freeBytes(recordingsRoot);
    } catch (_) {
      free = null;
    }
    return free == null || free >= bytes + reserveBytes;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Discarded at the start of the next run.
    }
  }

  Future<void> _discardStaging() async {
    final staging = Directory(_stagingPath);
    try {
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
    } catch (_) {
      // Retried at the start of the next run; staging is never scanned.
    }
  }

  Future<Map<String, dynamic>> _readJournal() async {
    try {
      final pending = File('$_journalPath.new');
      if (await pending.exists()) {
        await pending.delete();
      }
      final file = File(_journalPath);
      if (!await file.exists()) {
        return <String, dynamic>{};
      }
      final json = jsonDecode(await file.readAsString());
      return json is Map<String, dynamic> ? json : <String, dynamic>{};
    } catch (_) {
      // Only a hint; the files are the truth.
      return <String, dynamic>{};
    }
  }

  Future<void> _writeJournal(Map<String, dynamic> journal) async {
    await Directory(workDirectory).create(recursive: true);
    final pending = File('$_journalPath.new');
    await pending.writeAsString(jsonEncode(journal), flush: true);
    await pending.rename(_journalPath);
  }
}

/// Deletes the originals of an import: the ride JSONs first (they hold the
/// GPS trail), then the videos. Returns the documents that could not be
/// deleted (including those the provider marks as not deletable, which are
/// not attempted).
Future<List<LegacyRideDocument>> deleteImportedOriginals(
  LegacyRideDocumentSource source,
  List<LegacyRideDocument> documents,
) async {
  final ordered = <LegacyRideDocument>[
    ...documents.where((d) => _isJsonName(d.name)),
    ...documents.where((d) => !_isJsonName(d.name)),
  ];
  final deletable = ordered.where((d) => d.canDelete).toList();
  final notDeletable = ordered.where((d) => !d.canDelete).toList();
  List<String> failedUris;
  try {
    failedUris = await source.delete(deletable);
  } catch (_) {
    failedUris = <String>[for (final d in deletable) d.uri];
  }
  final failed = failedUris.toSet();
  return <LegacyRideDocument>[
    ...notDeletable,
    ...deletable.where((d) => failed.contains(d.uri)),
  ];
}

bool _isJsonName(String name) =>
    name.toLowerCase().endsWith(ride_codec.rideTelemetryFileSuffix);

/// State of the legacy-folder import for the UI, and its idle signal for
/// the other bulk file work (the migration, the storage budget).
class LegacyRideImportController extends ChangeNotifier {
  Future<LegacyImportSummary>? _running;
  LegacyImportProgress? _progress;

  /// Whether an import is copying files now.
  bool get isRunning => _running != null;

  /// Whether no import is in progress.
  bool get isIdle => _running == null;

  /// Progress of the current run.
  LegacyImportProgress? get progress => _progress;

  /// Normalised destination paths of the ride being imported; empty when
  /// no run is in progress.
  Set<String> get inFlightPaths => _running == null
      ? const <String>{}
      : _progress?.inFlightPaths ?? const <String>{};

  /// Banner text while a run imports, for example 'Importing rides from
  /// the old folder (2 of 5)'; `null` otherwise.
  String? get bannerText {
    final progress = _progress;
    if (_running == null) {
      return null;
    }
    if (progress == null || progress.total == 0) {
      return 'Reading the old folder';
    }
    final current = (progress.done + 1).clamp(1, progress.total);
    return 'Importing rides from the old folder ($current of '
        '${progress.total})';
  }

  /// Runs [importer] unless a run is in progress (then returns `null`).
  Future<LegacyImportSummary?> run(LegacyRideImporter importer) async {
    if (_running != null) {
      return null;
    }
    _progress = null;
    final run = importer.run(
      onProgress: (progress) {
        _progress = progress;
        notifyListeners();
      },
    );
    _running = run;
    notifyListeners();
    try {
      return await run;
    } finally {
      _running = null;
      _progress = null;
      notifyListeners();
    }
  }
}
