// lib/features/camera/providers/recordings_migration.dart
//
// Moves rides from the legacy recordings roots (on Android: app-specific
// external storage, the documents directory and the cache directory) into
// the private recordings root. [RecordingsMigrator] does the file work and
// is free of camera-plugin and platform-channel code, so it can be tested
// against temporary directories with injected faults;
// [RecordingsMigrationController] holds the state the UI shows.
// [CameraProvider] decides when a run may start and when it must pause.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/ride_file/ride_telemetry_codec.dart' as ride_codec;
import '../../../core/utils/integrity_utils.dart' as integrity_utils;
import '../../../core/utils/path_utils.dart' as path_utils;

/// Name of the journal file inside the migration work directory.
const String recordingsMigrationJournalFileName = 'migration_journal.json';

/// Name of the staging directory inside the migration work directory.
const String recordingsMigrationStagingDirectoryName = 'staging';

/// Suffix of a file being copied into the staging directory. It never ends
/// in `.tmp`, `.telemetry.json` or a video extension, so no sweeper or
/// scanner treats a staging file as a temp file, a ride or a video.
const String recordingsMigrationStagingSuffix = '.migrating';

/// Name of the probe file the recording screen writes to check that the
/// recordings directory is writable (ignored by the migration).
const String recordingsWriteProbeFileName = '.__motocam_write_probe.tmp';

/// Ride JSONs larger than this are not decoded while planning a run: they
/// move as they are, and their videos move as lone videos. Far above any
/// ride file the app writes.
const int recordingsMigrationMaxDecodedRideBytes = 64 * 1024 * 1024;

/// Points in a file move where a test can simulate the process being killed
/// (the hook throws).
@visibleForTesting
enum RecordingsMigrationFault {
  /// Before the file is renamed or copied.
  beforeCopy,

  /// After the staging copy is complete, before it is renamed into the
  /// recordings root.
  afterCopyBeforeRename,

  /// After the copy is renamed into the recordings root, before the source
  /// is deleted.
  afterRenameBeforeSourceDelete,

  /// After the new journal is written to its temporary file, before it
  /// replaces the journal.
  duringJournalWrite,
}

/// Called at each [RecordingsMigrationFault] point with the file concerned
/// (the staging file, the destination or the journal).
@visibleForTesting
typedef RecordingsMigrationFaultHook =
    FutureOr<void> Function(RecordingsMigrationFault point, String path);

/// Renames [from] to [to]; throws when that is not possible (for example
/// across file systems).
typedef RecordingsMigrationRename =
    Future<void> Function(String from, String to);

/// Why a ride was left in its legacy root.
enum RecordingsMigrationSkipReason {
  /// A different file with the same name is already in the recordings root.
  nameCollision,

  /// The ride JSON is unlocked and none of its videos is left. In the
  /// recordings root the orphan prune would delete it, so it stays where it
  /// is (still listed in Ride History).
  noVideoFiles,

  /// A file could not be read, copied or verified.
  copyFailed,
}

/// A ride (or a video without a ride JSON) left in its legacy root.
@immutable
class RecordingsMigrationSkip {
  /// Creates a skip record.
  const RecordingsMigrationSkip({required this.name, required this.reason});

  /// File name of the ride JSON (or of the video).
  final String name;

  /// Why it was not moved.
  final RecordingsMigrationSkipReason reason;

  /// Key under which the journal remembers that this skip was reported.
  String get reportKey => '${reason.name}:$name';
}

/// Progress of a run: [done] of [total] rides, and the files of the ride
/// being moved now.
@immutable
class RecordingsMigrationProgress {
  /// Creates a progress record.
  const RecordingsMigrationProgress({
    required this.done,
    required this.total,
    this.inFlightPaths = const <String>{},
  });

  /// Rides (and lone videos) handled so far: moved or skipped.
  final int done;

  /// Rides (and lone videos) found in the legacy roots at the start.
  final int total;

  /// Normalised paths (see `normalizePath`) of every source and destination
  /// file of the ride being moved; empty between rides.
  final Set<String> inFlightPaths;
}

/// How a run ended.
enum RecordingsMigrationOutcome {
  /// Every ride was handled (moved or skipped).
  completed,

  /// The run stopped because recording started or maintenance needs the
  /// files; it resumes later.
  paused,

  /// The recordings volume does not have room for the next copy plus the
  /// reserve; the remaining rides stay where they are.
  lowStorage,
}

/// What a run did.
@immutable
class RecordingsMigrationSummary {
  /// Creates a summary.
  const RecordingsMigrationSummary({
    required this.outcome,
    required this.total,
    required this.moved,
    required this.skipped,
    required this.remaining,
    required this.shouldNotify,
    this.splitPaths = const <String>{},
  });

  /// How the run ended.
  final RecordingsMigrationOutcome outcome;

  /// Rides (and lone videos) found at the start.
  final int total;

  /// Rides (and lone videos) now in the recordings root.
  final int moved;

  /// Rides left in their legacy roots, and why.
  final List<RecordingsMigrationSkip> skipped;

  /// Rides not handled because the run paused or stopped.
  final int remaining;

  /// Whether the rider should see [message]: something moved, or a skip or
  /// a low-storage stop that no earlier run reported.
  final bool shouldNotify;

  /// Normalised paths (source and destination) of every file of the rides
  /// left split between a legacy root and the recordings root (a stop for
  /// low storage, or a copy that failed, in the middle of a ride). Ride
  /// History leaves them out; a later run finishes them.
  final Set<String> splitPaths;

  /// Rider-facing summary.
  String get message {
    String rides(int n) => '$n ride${n == 1 ? '' : 's'}';
    final parts = <String>[
      if (moved > 0) 'Moved ${rides(moved)} to private storage',
    ];
    final byReason = <RecordingsMigrationSkipReason, int>{};
    for (final skip in skipped) {
      byReason[skip.reason] = (byReason[skip.reason] ?? 0) + 1;
    }
    for (final entry in byReason.entries) {
      final why = switch (entry.key) {
        RecordingsMigrationSkipReason.nameCollision =>
          'a different file with the same name is already in private storage',
        RecordingsMigrationSkipReason.noVideoFiles => 'no video files are left',
        RecordingsMigrationSkipReason.copyFailed =>
          'a file could not be copied',
      };
      parts.add('${rides(entry.value)} left in the old folder ($why)');
    }
    if (outcome == RecordingsMigrationOutcome.lowStorage) {
      parts.add(
        'not enough free space for the remaining ${rides(remaining)}, '
        'which ${remaining == 1 ? 'stays' : 'stay'} in the old folder',
      );
    }
    if (parts.isEmpty) {
      return 'No rides needed moving.';
    }
    final text = parts.join('; ');
    return '${text[0].toUpperCase()}${text.substring(1)}.';
  }
}

/// A ride (its videos, then its JSON) or a lone video in a legacy root.
class _MigrationUnit {
  _MigrationUnit({
    required this.root,
    required this.name,
    required this.files,
    this.skipReason,
  });

  final String root;
  final String name;

  /// Source paths in move order; a ride JSON is always last.
  final List<String> files;

  /// Set when the unit is known to stay where it is.
  RecordingsMigrationSkipReason? skipReason;
}

enum _FileResult { moved, vanished, collision, paused, lowStorage, failed }

/// Thrown inside a copy when the run must pause.
class _PauseRequested implements Exception {
  const _PauseRequested();
}

/// Moves the rides in [legacyRoots] into [recordingsRoot].
///
/// A ride moves as a unit: its trusted, existing segment files and main
/// video (as `resolveRideSegments` resolves them), then its telemetry JSON.
/// Videos that no ride JSON references move one by one. `.nomedia`,
/// telemetry temp files and the write probe are ignored; other files and
/// subdirectories stay where they are. Each file is renamed first; only
/// when the rename fails (another file system) it is streamed into a
/// staging copy under [workDirectory], flushed, checked against the source
/// size, renamed into [recordingsRoot] and checked again, and only then is
/// the source deleted. The JSON is copied byte for byte, so its payload
/// hash, its signature and its signed-ride registration stay valid.
///
/// Before a ride is copied, the free space of [recordingsRoot]'s volume
/// ([freeBytes], `null` when unknown) must cover the rest of the ride plus
/// [reserveBytes]; otherwise no further file is copied in this run (rides
/// that are only renamed still move) and the run ends with
/// [RecordingsMigrationOutcome.lowStorage]. A destination with the same
/// name counts as already moved only when its size (and for a JSON, its
/// bytes) match; otherwise the whole ride stays in its legacy root.
///
/// The migration is one-shot. The first run records every file it plans to
/// move (the snapshot) in the journal before moving anything; later runs
/// move only files of that snapshot, so a file that appears in a legacy
/// root afterwards is never moved into the private root. Once a run
/// completes with no ride left split, the journal is marked done and every
/// later run returns at once. A ride JSON larger than
/// [recordingsMigrationMaxDecodedRideBytes] is not decoded: it moves as it
/// is and its videos move as lone videos.
///
/// [shouldPause] is checked before each ride JSON is planned, before each
/// ride, before each file and between copy chunks: a copy in flight is
/// abandoned (its staging file deleted, the source untouched) and the run
/// returns [RecordingsMigrationOutcome.paused].
///
/// The journal in [workDirectory] (replaced atomically) names the ride in
/// flight. The file system is the source of truth: every step can be
/// repeated, so a run after a kill at any point rolls forward. Staging
/// files are discarded at the start of a run, and a source is never
/// deleted before a verified copy exists in [recordingsRoot], so no file is
/// ever left only in staging.
///
/// A legacy root left with nothing but ignored files is deleted after a
/// completed run.
class RecordingsMigrator {
  /// Creates a migrator. [workDirectory] must lie outside [recordingsRoot]
  /// and every legacy root, so that no scanner sees the staging files.
  RecordingsMigrator({
    required this.recordingsRoot,
    required List<String> legacyRoots,
    required this.workDirectory,
    required this.freeBytes,
    required this.reserveBytes,
    bool Function()? shouldPause,
    RecordingsMigrationRename? renameFile,
    @visibleForTesting this.debugFault,
    @visibleForTesting this.copyChunkBytes = 1024 * 1024,
    @visibleForTesting
    this.maxDecodedRideBytes = recordingsMigrationMaxDecodedRideBytes,
  }) : legacyRoots = List<String>.unmodifiable(
         legacyRoots.where(
           (root) =>
               root.trim().isNotEmpty &&
               path_utils.normalizePath(root) !=
                   path_utils.normalizePath(recordingsRoot),
         ),
       ),
       shouldPause = shouldPause ?? _never,
       renameFile = renameFile ?? _defaultRename {
    for (final root in <String>[recordingsRoot, ...this.legacyRoots]) {
      if (path_utils.isPathInsideDirectory(workDirectory, root)) {
        throw ArgumentError.value(
          workDirectory,
          'workDirectory',
          'must not lie inside the scanned root $root',
        );
      }
    }
  }

  static bool _never() => false;

  static Future<void> _defaultRename(String from, String to) async {
    await File(from).rename(to);
  }

  /// The private recordings root rides move into.
  final String recordingsRoot;

  /// Roots rides move out of (the recordings root itself is dropped).
  final List<String> legacyRoots;

  /// Holds the journal and the staging directory.
  final String workDirectory;

  /// Free bytes on the volume that holds the given path, or `null`.
  final Future<int?> Function(String path) freeBytes;

  /// Bytes that must stay free after each copy.
  final int reserveBytes;

  /// Whether the run must pause now.
  final bool Function() shouldPause;

  /// Renames a file; injectable so tests can force the copy path.
  final RecordingsMigrationRename renameFile;

  /// Test hook called at each [RecordingsMigrationFault] point.
  final RecordingsMigrationFaultHook? debugFault;

  /// Size of each read during a copy.
  final int copyChunkBytes;

  /// Ride JSONs larger than this are moved without being decoded.
  final int maxDecodedRideBytes;

  /// Legacy roots where a rename failed during this run, so further files
  /// from them are copied.
  final Set<String> _copyRoots = <String>{};

  /// Normalised paths of the files this migration may move, or `null`
  /// before the first run has planned (see the class documentation).
  Set<String>? _snapshot;

  /// Whether listing a legacy root failed during this run's plan, so no
  /// snapshot is recorded from it.
  bool _listingFailed = false;

  /// Whether a copy did not fit during this run: no further file is
  /// copied, only renamed.
  bool _stoppedForSpace = false;

  /// The fewest bytes a ride that did not fit needed (without the
  /// reserve), kept in the journal so a later run with no more room
  /// returns before planning.
  int? _lowStorageBytes;

  String get _sep => Platform.pathSeparator;

  String get _journalPath =>
      '$workDirectory$_sep$recordingsMigrationJournalFileName';

  String get _stagingPath =>
      '$workDirectory$_sep$recordingsMigrationStagingDirectoryName';

  String _destinationFor(String source) =>
      '$recordingsRoot$_sep${path_utils.fileNameFromPath(source)}';

  /// Whether [path] is a file the migration ignores (and may delete with an
  /// emptied legacy root).
  static bool isIgnoredFile(String path) {
    final name = path_utils.fileNameFromPath(path).toLowerCase();
    return name == '.nomedia' ||
        name == recordingsWriteProbeFileName ||
        integrity_utils.isTelemetryTempFilePath(path);
  }

  static bool _isRideJson(String path) =>
      path.toLowerCase().endsWith(ride_codec.rideTelemetryFileSuffix) &&
      !integrity_utils.isTelemetryTempFilePath(path);

  Future<List<File>> _listFiles(String root) async {
    final directory = Directory(root);
    try {
      if (!await directory.exists()) {
        return const <File>[];
      }
      final files = <File>[];
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File) {
          files.add(entity);
        }
      }
      files.sort((a, b) => a.path.compareTo(b.path));
      return files;
    } catch (_) {
      // An unavailable root (for example an unmounted card) is skipped.
      _listingFailed = true;
      return const <File>[];
    }
  }

  bool _inSnapshot(String path) {
    final snapshot = _snapshot;
    return snapshot == null ||
        snapshot.contains(path_utils.normalizePath(path));
  }

  void _noteLowStorage(int bytes) {
    _stoppedForSpace = true;
    final known = _lowStorageBytes;
    _lowStorageBytes = known == null || bytes < known ? bytes : known;
  }

  /// Runs the migration and reports progress through [onProgress].
  Future<RecordingsMigrationSummary> run({
    void Function(RecordingsMigrationProgress progress)? onProgress,
  }) async {
    final journal = await _readJournal();
    final reportedSkips = journal['reportedSkips'];
    final reported = <String>{
      if (reportedSkips is List)
        for (final key in reportedSkips) key.toString(),
    };
    if (journal['done'] == true) {
      return const RecordingsMigrationSummary(
        outcome: RecordingsMigrationOutcome.completed,
        total: 0,
        moved: 0,
        skipped: <RecordingsMigrationSkip>[],
        remaining: 0,
        shouldNotify: false,
      );
    }
    final snapshot = journal['snapshot'];
    if (snapshot is List) {
      _snapshot = <String>{
        for (final path in snapshot) path_utils.normalizePath(path.toString()),
      };
    }
    final split = journal['split'];
    final knownSplitPaths = <String>{
      if (split is List)
        for (final path in split) path.toString(),
    };
    final neededBytes = journal['lowStorageBytes'];
    if (_snapshot != null &&
        neededBytes is int &&
        !await _hasRoomFor(neededBytes)) {
      // Still no room for the smallest ride that did not fit last time;
      // everything else was handled then, so there is nothing to plan.
      return RecordingsMigrationSummary(
        outcome: RecordingsMigrationOutcome.lowStorage,
        total: 0,
        moved: 0,
        skipped: const <RecordingsMigrationSkip>[],
        remaining: 0,
        shouldNotify: false,
        splitPaths: Set<String>.unmodifiable(knownSplitPaths),
      );
    }
    await _discardStaging();

    final List<_MigrationUnit> planned;
    try {
      planned = await _plan(journal);
    } on _PauseRequested {
      return const RecordingsMigrationSummary(
        outcome: RecordingsMigrationOutcome.paused,
        total: 0,
        moved: 0,
        skipped: <RecordingsMigrationSkip>[],
        remaining: 0,
        shouldNotify: false,
      );
    }
    if (_snapshot == null && !_listingFailed) {
      // Recorded before anything moves: only these files ever will.
      _snapshot = <String>{
        for (final unit in planned)
          for (final path in unit.files) path_utils.normalizePath(path),
      };
      await _saveJournal(
        ride: journal['ride'],
        file: journal['file'],
        reported: reported,
      );
    }

    // Skips reported by an earlier run are not counted again (they stay in
    // the summary so the journal keeps their keys).
    final skipped = <RecordingsMigrationSkip>[];
    final units = <_MigrationUnit>[];
    for (final unit in planned) {
      final presetReason = unit.skipReason;
      final skip = presetReason == null
          ? null
          : RecordingsMigrationSkip(name: unit.name, reason: presetReason);
      if (skip != null && reported.contains(skip.reportKey)) {
        skipped.add(skip);
      } else {
        units.add(unit);
      }
    }
    final total = units.length;
    var done = 0;
    var moved = 0;
    var outcome = RecordingsMigrationOutcome.completed;
    final splitPaths = <String>{};
    _lowStorageBytes = null;
    onProgress?.call(RecordingsMigrationProgress(done: 0, total: total));

    for (final unit in units) {
      if (shouldPause()) {
        outcome = RecordingsMigrationOutcome.paused;
        break;
      }
      final presetReason = unit.skipReason;
      if (presetReason != null) {
        skipped.add(
          RecordingsMigrationSkip(name: unit.name, reason: presetReason),
        );
        done++;
        onProgress?.call(RecordingsMigrationProgress(done: done, total: total));
        continue;
      }
      if (_stoppedForSpace && _copyRoots.contains(unit.root)) {
        // Left where it is; rides that are only renamed still move.
        continue;
      }

      final result = await _moveUnit(unit, reported, onProgress, done, total);
      if (result == _FileResult.paused) {
        outcome = RecordingsMigrationOutcome.paused;
        break;
      }
      if (result != _FileResult.moved &&
          result != _FileResult.vanished &&
          await _isSplit(unit)) {
        splitPaths.addAll(_unitPaths(unit));
      }
      if (result == _FileResult.lowStorage) {
        continue;
      }
      if (result == _FileResult.collision) {
        skipped.add(
          RecordingsMigrationSkip(
            name: unit.name,
            reason: RecordingsMigrationSkipReason.nameCollision,
          ),
        );
      } else if (result == _FileResult.failed) {
        skipped.add(
          RecordingsMigrationSkip(
            name: unit.name,
            reason: RecordingsMigrationSkipReason.copyFailed,
          ),
        );
      } else if (result == _FileResult.moved) {
        moved++;
      }
      done++;
      onProgress?.call(RecordingsMigrationProgress(done: done, total: total));
    }
    if (outcome == RecordingsMigrationOutcome.completed && _stoppedForSpace) {
      outcome = RecordingsMigrationOutcome.lowStorage;
    }

    if (outcome == RecordingsMigrationOutcome.completed) {
      await _removeEmptiedLegacyRoots();
    }

    final newlyReported = <String>{
      for (final skip in skipped) skip.reportKey,
      if (outcome == RecordingsMigrationOutcome.lowStorage) 'lowStorage',
    };
    final shouldNotify =
        moved > 0 || newlyReported.difference(reported).isNotEmpty;
    // A paused run keeps the journal naming the ride in flight.
    if (outcome != RecordingsMigrationOutcome.paused) {
      await _saveJournal(
        reported: newlyReported,
        split: splitPaths,
        // Only from a run that reached its end, so every ride that is only
        // renamed was handled before a later run may skip planning.
        lowStorageBytes: _lowStorageBytes,
        done:
            outcome == RecordingsMigrationOutcome.completed &&
            splitPaths.isEmpty &&
            _snapshot != null,
      );
    }
    return RecordingsMigrationSummary(
      outcome: outcome,
      total: total,
      moved: moved,
      skipped: List<RecordingsMigrationSkip>.unmodifiable(skipped),
      remaining: total - done,
      shouldNotify: shouldNotify,
      splitPaths: Set<String>.unmodifiable(splitPaths),
    );
  }

  /// Normalised source and destination paths of every file of [unit].
  Set<String> _unitPaths(_MigrationUnit unit) => <String>{
    for (final source in unit.files) ...<String>{
      path_utils.normalizePath(source),
      path_utils.normalizePath(_destinationFor(source)),
    },
  };

  /// Whether some files of [unit] are already in the recordings root while
  /// others are still in the legacy root.
  Future<bool> _isSplit(_MigrationUnit unit) async {
    var inRoot = false;
    var inLegacyRoot = false;
    for (final source in unit.files) {
      if (await File(source).exists()) {
        inLegacyRoot = true;
      } else if (await File(_destinationFor(source)).exists()) {
        inRoot = true;
      }
    }
    return inRoot && inLegacyRoot;
  }

  /// Lists the units: the journal's ride in flight first, then every ride
  /// JSON in each legacy root, then the videos no ride references. Only
  /// files of the snapshot are listed, once there is one. Throws
  /// [_PauseRequested] when [shouldPause] asks for it between rides.
  Future<List<_MigrationUnit>> _plan(Map<String, dynamic> journal) async {
    final units = <_MigrationUnit>[];
    final claimed = <String>{};
    final inFlight = journal['ride'];
    String? inFlightJson;
    if (inFlight is Map && inFlight['telemetry'] is String) {
      inFlightJson = path_utils.normalizePath(inFlight['telemetry'] as String);
    }

    for (final root in legacyRoots) {
      final files = await _listFiles(root);
      final rideUnits = <_MigrationUnit>[];
      for (final file in files) {
        if (!_isRideJson(file.path) || !_inSnapshot(file.path)) {
          continue;
        }
        if (shouldPause()) {
          throw const _PauseRequested();
        }
        rideUnits.add(await _planRide(root, file, claimed));
      }
      units.addAll(rideUnits);
      for (final file in files) {
        final key = path_utils.normalizePath(file.path);
        if (ride_codec.isRideVideoFilePath(file.path) &&
            !isIgnoredFile(file.path) &&
            _inSnapshot(file.path) &&
            claimed.add(key)) {
          units.add(
            _MigrationUnit(
              root: root,
              name: path_utils.fileNameFromPath(file.path),
              files: <String>[file.path],
            ),
          );
        }
      }
    }
    // The ride in flight goes first, whichever root it is in.
    if (inFlightJson != null) {
      final index = units.indexWhere(
        (unit) =>
            unit.files.isNotEmpty &&
            path_utils.normalizePath(unit.files.last) == inFlightJson,
      );
      if (index > 0) {
        units.insert(0, units.removeAt(index));
      }
    }
    return units;
  }

  /// Plans the move of the ride JSON [telemetryFile] in [root]. Videos
  /// already claimed by an earlier ride are not listed again.
  Future<_MigrationUnit> _planRide(
    String root,
    File telemetryFile,
    Set<String> claimed,
  ) async {
    final name = path_utils.fileNameFromPath(telemetryFile.path);
    claimed.add(path_utils.normalizePath(telemetryFile.path));
    final videos = <String>[];
    // Whether the ride still has a video here or already in the
    // recordings root (a ride interrupted half-way), or must move anyway.
    var keepsRide = false;
    try {
      final json = await telemetryFile.length() > maxDecodedRideBytes
          ? null
          : await ride_codec.readRideFileJson(telemetryFile);
      if (json == null) {
        // Unreadable or too large to decode here: moved as it is, and its
        // videos move as lone videos.
        keepsRide = true;
      } else {
        final lockedPaths = json['lockedSegmentPaths'];
        keepsRide = ride_codec
            .normalizeSegmentPathList(
              lockedPaths is List ? lockedPaths : const <Object?>[],
            )
            .isNotEmpty;
        final segments = await ride_codec.resolveRideSegments(
          telemetryFile: telemetryFile,
          json: json,
        );
        if (segments != null) {
          final missing = segments.missingSegmentPaths.toSet();
          for (final path in <String>{
            ...segments.segmentPaths,
            segments.videoPath,
          }) {
            if (path.isEmpty) {
              continue;
            }
            if (missing.contains(path)) {
              keepsRide =
                  keepsRide || await File(_destinationFor(path)).exists();
              continue;
            }
            if (!path_utils.isPathInsideDirectory(path, root) ||
                !_inSnapshot(path) ||
                !await File(path).exists()) {
              continue;
            }
            keepsRide = true;
            if (claimed.add(path_utils.normalizePath(path))) {
              videos.add(path);
            }
          }
        }
      }
    } catch (_) {
      keepsRide = true;
    }
    return _MigrationUnit(
      root: root,
      name: name,
      files: <String>[...videos, telemetryFile.path],
      skipReason: keepsRide ? null : RecordingsMigrationSkipReason.noVideoFiles,
    );
  }

  Future<_FileResult> _moveUnit(
    _MigrationUnit unit,
    Set<String> reported,
    void Function(RecordingsMigrationProgress progress)? onProgress,
    int done,
    int total,
  ) async {
    // Collisions are checked for the whole ride before any file moves.
    final sizes = <String, int>{};
    for (final source in unit.files) {
      final sourceFile = File(source);
      if (!await sourceFile.exists()) {
        continue;
      }
      final destination = File(_destinationFor(source));
      if (await destination.exists() &&
          !await _sameContent(
            sourceFile,
            destination,
            isJson: _isRideJson(source),
          )) {
        return _FileResult.collision;
      }
      sizes[source] = await sourceFile.length();
    }
    final bytesToMove = sizes.values.fold<int>(0, (sum, size) => sum + size);
    if (_copyRoots.contains(unit.root) &&
        (_stoppedForSpace || !await _hasRoomFor(bytesToMove))) {
      _noteLowStorage(bytesToMove);
      return _FileResult.lowStorage;
    }

    final inFlightPaths = _unitPaths(unit);
    onProgress?.call(
      RecordingsMigrationProgress(
        done: done,
        total: total,
        inFlightPaths: inFlightPaths,
      ),
    );
    final ride = <String, dynamic>{
      'root': unit.root,
      'name': unit.name,
      'telemetry': _isRideJson(unit.files.last) ? unit.files.last : null,
      'files': unit.files,
    };

    var anyMoved = false;
    var bytesLeft = bytesToMove;
    for (final source in unit.files) {
      if (shouldPause()) {
        return _FileResult.paused;
      }
      await _saveJournal(ride: ride, file: source, reported: reported);
      // The free-space check covers the rest of the ride, so a ride whose
      // first rename fails is not copied half-way.
      final result = await _moveFile(unit.root, source, bytesLeft);
      bytesLeft -= sizes[source] ?? 0;
      switch (result) {
        case _FileResult.moved:
          anyMoved = true;
        case _FileResult.vanished:
          break;
        case _FileResult.collision:
        case _FileResult.paused:
        case _FileResult.lowStorage:
        case _FileResult.failed:
          return result;
      }
    }
    await _saveJournal(reported: reported);
    return anyMoved || await _allInRoot(unit)
        ? _FileResult.moved
        : _FileResult.vanished;
  }

  Future<bool> _allInRoot(_MigrationUnit unit) async {
    for (final source in unit.files) {
      if (!await File(_destinationFor(source)).exists()) {
        return false;
      }
    }
    return unit.files.isNotEmpty;
  }

  /// Moves one file. Never deletes [source] unless a copy of the same size
  /// (for a JSON, the same bytes) is in the recordings root. Before a copy,
  /// the free space must cover [bytesLeft], the bytes the ride still has to
  /// move from this file on.
  Future<_FileResult> _moveFile(
    String root,
    String source,
    int bytesLeft,
  ) async {
    final sourceFile = File(source);
    final destinationPath = _destinationFor(source);
    final destination = File(destinationPath);
    final isJson = _isRideJson(source);

    if (!await sourceFile.exists()) {
      return await destination.exists()
          ? _FileResult.moved
          : _FileResult.vanished;
    }
    if (await destination.exists()) {
      // Moved before (for example the process was killed before the source
      // was deleted); the content check makes it safe to drop the source.
      if (!await _sameContent(sourceFile, destination, isJson: isJson)) {
        return _FileResult.collision;
      }
      await _deleteSource(sourceFile);
      return _FileResult.moved;
    }

    await debugFault?.call(RecordingsMigrationFault.beforeCopy, source);

    if (!_copyRoots.contains(root)) {
      try {
        await Directory(recordingsRoot).create(recursive: true);
        await renameFile(source, destinationPath);
        return _FileResult.moved;
      } catch (_) {
        // Another file system: copy from now on for this root.
        _copyRoots.add(root);
      }
    }

    final int size;
    try {
      size = await sourceFile.length();
    } on FileSystemException {
      return _FileResult.failed;
    }
    final needed = bytesLeft > size ? bytesLeft : size;
    if (_stoppedForSpace || !await _hasRoomFor(needed)) {
      _noteLowStorage(needed);
      return _FileResult.lowStorage;
    }

    final staging = File(
      '$_stagingPath$_sep${path_utils.fileNameFromPath(source)}'
      '$recordingsMigrationStagingSuffix',
    );
    try {
      await Directory(_stagingPath).create(recursive: true);
      await _copyFile(sourceFile, staging);
    } on _PauseRequested {
      await _deleteQuietly(staging);
      return _FileResult.paused;
    } on FileSystemException {
      await _deleteQuietly(staging);
      return _FileResult.failed;
    }

    await debugFault?.call(
      RecordingsMigrationFault.afterCopyBeforeRename,
      staging.path,
    );

    try {
      if (await staging.length() != size ||
          (isJson && !await _sameBytes(sourceFile, staging))) {
        await _deleteQuietly(staging);
        return _FileResult.failed;
      }
      // A file that appeared since the check is never overwritten.
      if (await destination.exists()) {
        await _deleteQuietly(staging);
        return _FileResult.collision;
      }
      await staging.rename(destinationPath);
      if (await destination.length() != size) {
        // Leave both: the source is still the trusted copy.
        return _FileResult.failed;
      }
    } on FileSystemException {
      await _deleteQuietly(staging);
      return _FileResult.failed;
    }

    await debugFault?.call(
      RecordingsMigrationFault.afterRenameBeforeSourceDelete,
      destinationPath,
    );
    await _deleteSource(sourceFile);
    return _FileResult.moved;
  }

  Future<bool> _hasRoomFor(int bytes) async {
    int? free;
    try {
      free = await freeBytes(recordingsRoot);
    } catch (_) {
      free = null;
    }
    // Unknown free space does not block, as for recording.
    return free == null || free >= bytes + reserveBytes;
  }

  Future<void> _copyFile(File source, File target) async {
    final input = await source.open();
    RandomAccessFile? output;
    try {
      output = await target.open(mode: FileMode.write);
      final buffer = Uint8List(copyChunkBytes);
      while (true) {
        if (shouldPause()) {
          throw const _PauseRequested();
        }
        final read = await input.readInto(buffer);
        if (read <= 0) {
          break;
        }
        await output.writeFrom(buffer, 0, read);
      }
      await output.flush();
    } finally {
      await output?.close();
      await input.close();
    }
  }

  Future<bool> _sameContent(
    File source,
    File destination, {
    required bool isJson,
  }) async {
    try {
      if (await source.length() != await destination.length()) {
        return false;
      }
      return !isJson || await _sameBytes(source, destination);
    } on FileSystemException {
      return false;
    }
  }

  Future<bool> _sameBytes(File a, File b) async {
    final bytesA = await a.readAsBytes();
    final bytesB = await b.readAsBytes();
    return listEquals(bytesA, bytesB);
  }

  Future<void> _deleteSource(File source) async {
    try {
      await source.delete();
    } on FileSystemException {
      // Left in place; the next run sees the verified copy and retries.
    }
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

  Future<void> _removeEmptiedLegacyRoots() async {
    for (final root in legacyRoots) {
      final directory = Directory(root);
      try {
        if (!await directory.exists()) {
          continue;
        }
        final entries = await directory.list(followLinks: false).toList();
        final onlyIgnored = entries.every(
          (entity) => entity is File && isIgnoredFile(entity.path),
        );
        if (!onlyIgnored) {
          continue;
        }
        for (final entity in entries) {
          await entity.delete();
        }
        await directory.delete();
      } catch (_) {
        // Kept; scanned again next time.
      }
    }
  }

  Future<Map<String, dynamic>> _readJournal() async {
    try {
      // A journal write interrupted before its rename left only this file.
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
      // A damaged journal is only a hint; the file system is the truth.
      return <String, dynamic>{};
    }
  }

  /// Writes the journal: the ride and file in flight (if any), the skips
  /// already reported, the snapshot, and after a run the split rides, the
  /// low-storage need and whether the migration is done. Every field but
  /// `version` is optional for readers.
  Future<void> _saveJournal({
    Object? ride,
    Object? file,
    required Iterable<String> reported,
    Set<String> split = const <String>{},
    int? lowStorageBytes,
    bool done = false,
  }) {
    final snapshot = _snapshot;
    return _writeJournal(<String, dynamic>{
      'version': 1,
      'ride': ride,
      'file': file,
      'reportedSkips': reported.toList()..sort(),
      if (snapshot != null) 'snapshot': snapshot.toList()..sort(),
      if (split.isNotEmpty) 'split': split.toList()..sort(),
      'lowStorageBytes': ?lowStorageBytes,
      if (done) 'done': true,
    });
  }

  Future<void> _writeJournal(Map<String, dynamic> journal) async {
    await Directory(workDirectory).create(recursive: true);
    final pending = File('$_journalPath.new');
    await pending.writeAsString(jsonEncode(journal), flush: true);
    await debugFault?.call(
      RecordingsMigrationFault.duringJournalWrite,
      pending.path,
    );
    await pending.rename(_journalPath);
  }
}

/// State of the recordings migration for the UI, and the "migration idle"
/// signal for other file maintenance.
///
/// [CameraProvider] owns one and starts runs through [start]; Ride History
/// and the recording screen listen to it.
class RecordingsMigrationController extends ChangeNotifier {
  Future<void>? _running;
  RecordingsMigrationProgress? _progress;
  RecordingsMigrationSummary? _lastSummary;
  String? _notice;
  bool _completed = false;

  /// Whether a run is moving files now.
  bool get isRunning => _running != null;

  /// Whether no run is in progress: no file is being renamed, copied or
  /// deleted by the migration. Import and storage maintenance must wait for
  /// this (see [whenIdle]).
  bool get isIdle => _running == null;

  /// Completes when no run is in progress.
  Future<void> whenIdle() => _running ?? Future<void>.value();

  /// Whether the last run finished (completed or stopped for low storage),
  /// so no further run starts in this process.
  bool get isFinished => _completed;

  /// Progress of the current or last run.
  RecordingsMigrationProgress? get progress => _progress;

  /// Normalised paths of the ride being moved while a run is running or
  /// paused in the middle of it, and after a finished run those of the
  /// rides it left split ([RecordingsMigrationSummary.splitPaths]). Ride
  /// History leaves these files out so a half-moved ride is not shown.
  Set<String> get inFlightPaths {
    final last = _lastSummary;
    if (_running == null &&
        last != null &&
        last.outcome != RecordingsMigrationOutcome.paused) {
      return last.splitPaths;
    }
    return _progress?.inFlightPaths ?? const <String>{};
  }

  /// Summary of the last finished run.
  RecordingsMigrationSummary? get lastSummary => _lastSummary;

  /// Banner text while rides are moving, for example
  /// 'Moving 3 rides to private storage (2 of 3)'; `null` otherwise.
  String? get bannerText {
    final progress = _progress;
    if (_running == null || progress == null || progress.total == 0) {
      return null;
    }
    final total = progress.total;
    final current = (progress.done + 1).clamp(1, total);
    return 'Moving $total ride${total == 1 ? '' : 's'} to private storage '
        '($current of $total)';
  }

  /// The last run's summary until the rider dismisses it ([dismissNotice]);
  /// `null` when nothing needs reporting.
  String? get notice => _notice;

  /// Hides [notice].
  void dismissNotice() {
    if (_notice == null) {
      return;
    }
    _notice = null;
    notifyListeners();
  }

  /// Starts [migrator] unless a run is in progress or an earlier run
  /// finished. [onError] receives an unexpected error; the run then counts
  /// as paused and may be started again.
  void start(
    RecordingsMigrator migrator, {
    void Function(Object error)? onError,
  }) {
    if (_running != null || _completed) {
      return;
    }
    final completer = Completer<void>();
    _running = completer.future;
    notifyListeners();
    unawaited(() async {
      try {
        final summary = await migrator.run(
          onProgress: (progress) {
            _progress = progress;
            notifyListeners();
          },
        );
        _lastSummary = summary;
        if (summary.outcome != RecordingsMigrationOutcome.paused) {
          _completed = true;
          if (summary.shouldNotify) {
            _notice = summary.message;
          }
        }
      } catch (error) {
        onError?.call(error);
      } finally {
        _running = null;
        completer.complete();
        notifyListeners();
      }
    }());
  }
}
