// lib/features/camera/providers/storage_budget.dart
//
// The global storage budget (setting recordings_storage_budget_gb): which
// whole rides to delete, oldest first, when the recordings root holds more
// than the budget. [selectRidesForStorageBudget] is pure; the scan that
// feeds it ([scanStorageBudgetInventory]) reads the recordings root on a
// background isolate. CameraProvider decides when to enforce and deletes
// through the shared ride deletion routine.

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/ride_file/ride_telemetry_codec.dart' as ride_codec;
import '../../../core/utils/integrity_utils.dart' as integrity_utils;
import '../../../core/utils/path_utils.dart' as path_utils;
import '../../history/models/ride_history_loader.dart';
import '../../history/models/ride_record.dart';
import '../../history/services/ride_deletion.dart';

/// One ride as the storage budget sees it: a ride JSON with its files, or
/// a video that no ride JSON references (a video-only ride).
@immutable
class StorageBudgetRide {
  /// Creates a budget ride.
  const StorageBudgetRide({
    required this.id,
    required this.createdAt,
    required this.files,
    this.rideSessionId,
    this.isLocked = false,
    this.hasQuarantinedPaths = false,
    this.lastModified,
  });

  /// The ride's telemetry JSON path, or its video path for a video-only
  /// ride.
  final String id;

  /// When the ride was recorded (a video-only ride: its file's
  /// modification time). Rides are deleted oldest first by this.
  final DateTime createdAt;

  /// Every file that deleting the ride removes (see `filesOfRide`).
  final List<String> files;

  /// The ride's `rideSessionId`, when it has a ride JSON.
  final String? rideSessionId;

  /// Whether any segment of the ride is locked.
  final bool isLocked;

  /// Whether the ride JSON declares paths outside its directory.
  final bool hasQuarantinedPaths;

  /// Newest modification time of [files], when known.
  final DateTime? lastModified;
}

/// What [selectRidesForStorageBudget] decided.
@immutable
class StorageBudgetSelection {
  /// Creates a selection.
  const StorageBudgetSelection({
    required this.budgetBytes,
    required this.totalBytes,
    required this.protectedBytes,
    required this.ridesToDelete,
    required this.bytesToFree,
    required this.attainable,
  });

  /// The budget (0 when off).
  final int budgetBytes;

  /// Bytes of every counted file in the recordings root.
  final int totalBytes;

  /// Bytes the budget may never delete: locked rides, the current
  /// recording session, quarantined rides and files of no ride.
  final int protectedBytes;

  /// Rides to delete, oldest first.
  final List<StorageBudgetRide> ridesToDelete;

  /// Bytes deleting [ridesToDelete] frees.
  final int bytesToFree;

  /// `false` when [protectedBytes] alone exceed the budget; nothing is then
  /// selected.
  final bool attainable;

  /// Whether the budget is on and the recordings exceed it.
  bool get isOverBudget => budgetBytes > 0 && totalBytes > budgetBytes;
}

/// Chooses whole rides to delete so that the files in [recordingsRoot]
/// fit [budgetBytes] (0 or less: off, nothing is selected).
///
/// [fileSizes] holds every counted file directly inside [recordingsRoot]
/// with its size; their sum is the total. [rides] lists the rides found
/// there, video-only rides included.
///
/// A ride is never selected when it has a locked segment, has quarantined
/// paths, has no file or a file that is not directly inside
/// [recordingsRoot] (a legacy-root ride not yet migrated, a staging file
/// or a gallery copy), belongs to the current recording session (its
/// `rideSessionId` is [currentRideSessionId], or any of its files is in
/// [currentSessionPaths], since segments exist before the session's
/// checkpoint JSON does), has a file modified at or after
/// [currentSessionStartedAt], has a file in [protectedPaths] (the ride the
/// migration or the import left half-moved, or the videos a ride JSON that
/// failed to decode may lock), or shares a file with any such ride.
///
/// The others are deleted oldest first (by `createdAt`, then id) until
/// the total is at or under the budget. When the protected bytes alone
/// exceed the budget, nothing is selected and
/// [StorageBudgetSelection.attainable] is `false`.
StorageBudgetSelection selectRidesForStorageBudget({
  required int budgetBytes,
  required Map<String, int> fileSizes,
  required List<StorageBudgetRide> rides,
  required String recordingsRoot,
  String? currentRideSessionId,
  Iterable<String> currentSessionPaths = const <String>[],
  DateTime? currentSessionStartedAt,
  Iterable<String> protectedPaths = const <String>[],
}) {
  final root = path_utils.normalizePath(recordingsRoot);
  final sizes = <String, int>{};
  fileSizes.forEach((path, size) {
    if (_isDirectlyInside(path, root)) {
      sizes[path_utils.normalizePath(path)] = size < 0 ? 0 : size;
    }
  });
  final total = sizes.values.fold<int>(0, (sum, size) => sum + size);

  if (budgetBytes <= 0 || total <= budgetBytes) {
    return StorageBudgetSelection(
      budgetBytes: budgetBytes <= 0 ? 0 : budgetBytes,
      totalBytes: total,
      protectedBytes: 0,
      ridesToDelete: const <StorageBudgetRide>[],
      bytesToFree: 0,
      attainable: true,
    );
  }

  final sessionPaths = <String>{
    for (final path in currentSessionPaths) path_utils.normalizePath(path),
  };
  final otherProtected = <String>{
    for (final path in protectedPaths) path_utils.normalizePath(path),
  };
  final protectedFiles = <String>{...sessionPaths, ...otherProtected};
  final unprotected = <StorageBudgetRide>[];
  for (final ride in rides) {
    final keys = ride.files.map(path_utils.normalizePath).toList();
    final isProtected =
        ride.isLocked ||
        keys.any(otherProtected.contains) ||
        ride.hasQuarantinedPaths ||
        keys.isEmpty ||
        keys.any((key) => !_isDirectlyInside(key, root)) ||
        (currentRideSessionId != null &&
            ride.rideSessionId == currentRideSessionId) ||
        keys.any(sessionPaths.contains) ||
        (currentSessionStartedAt != null &&
            ride.lastModified != null &&
            !ride.lastModified!.isBefore(currentSessionStartedAt));
    if (isProtected) {
      protectedFiles.addAll(keys);
    } else {
      unprotected.add(ride);
    }
  }

  final candidates =
      unprotected
          .where(
            (ride) => !ride.files
                .map(path_utils.normalizePath)
                .any(protectedFiles.contains),
          )
          .toList()
        ..sort((a, b) {
          final byDate = a.createdAt.compareTo(b.createdAt);
          return byDate != 0 ? byDate : a.id.compareTo(b.id);
        });

  final candidateFiles = <String>{
    for (final ride in candidates) ...ride.files.map(path_utils.normalizePath),
  };
  final candidateBytes = candidateFiles.fold<int>(
    0,
    (sum, key) => sum + (sizes[key] ?? 0),
  );
  final protectedBytes = total - candidateBytes;
  if (protectedBytes > budgetBytes) {
    return StorageBudgetSelection(
      budgetBytes: budgetBytes,
      totalBytes: total,
      protectedBytes: protectedBytes,
      ridesToDelete: const <StorageBudgetRide>[],
      bytesToFree: 0,
      attainable: false,
    );
  }

  final selected = <StorageBudgetRide>[];
  final freed = <String>{};
  var freedBytes = 0;
  for (final ride in candidates) {
    if (total - freedBytes <= budgetBytes) {
      break;
    }
    selected.add(ride);
    for (final key in ride.files.map(path_utils.normalizePath)) {
      if (freed.add(key)) {
        freedBytes += sizes[key] ?? 0;
      }
    }
  }
  return StorageBudgetSelection(
    budgetBytes: budgetBytes,
    totalBytes: total,
    protectedBytes: protectedBytes,
    ridesToDelete: List<StorageBudgetRide>.unmodifiable(selected),
    bytesToFree: freedBytes,
    attainable: true,
  );
}

bool _isDirectlyInside(String path, String normalizedRoot) {
  final normalized = path_utils.normalizePath(path);
  final separatorIndex = normalized.lastIndexOf(Platform.pathSeparator);
  return separatorIndex > 0 &&
      normalized.substring(0, separatorIndex) == normalizedRoot;
}

/// What [scanStorageBudgetInventory] found in the recordings root.
class StorageBudgetInventory {
  /// Creates an inventory.
  const StorageBudgetInventory({
    required this.fileSizes,
    required this.rides,
    required this.records,
    this.protectedPaths = const <String>{},
  });

  /// Every counted file directly inside the root with its size.
  final Map<String, int> fileSizes;

  /// The rides, video-only rides included.
  final List<StorageBudgetRide> rides;

  /// The ride record of each entry of [rides], by [StorageBudgetRide.id].
  final Map<String, RideRecord> records;

  /// Normalised paths the budget must never delete although no loaded ride
  /// locks them: when a ride JSON in the root failed to load, the files of
  /// every video-only ride (the lock state lives only in the ride JSON, so
  /// any of them may be a locked segment of that ride). Pass them to
  /// [selectRidesForStorageBudget] as `protectedPaths`.
  final Set<String> protectedPaths;
}

/// Whether [path] counts toward the budget: a ride video or a ride JSON
/// (telemetry temp files, `.nomedia` and the write probe do not).
bool isStorageBudgetFile(String path) {
  if (integrity_utils.isTelemetryTempFilePath(path)) {
    return false;
  }
  return ride_codec.isRideVideoFilePath(path) ||
      path.toLowerCase().endsWith(ride_codec.rideTelemetryFileSuffix);
}

/// Lists the top level of [recordingsRoot] (never a subdirectory, a legacy
/// root or a staging directory) and loads its rides through the ride
/// index at [indexFilePath] when given. When any ride JSON there fails to
/// load, every video-only ride goes into
/// [StorageBudgetInventory.protectedPaths]. Blocking-heavy (JSON decoding),
/// so run it off the UI isolate (`Isolate.run`).
Future<StorageBudgetInventory> scanStorageBudgetInventory(
  String recordingsRoot, {
  String? indexFilePath,
}) async {
  final fileSizes = <String, int>{};
  final modified = <String, DateTime>{};
  final directory = Directory(recordingsRoot);
  if (await directory.exists()) {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !isStorageBudgetFile(entity.path)) {
        continue;
      }
      try {
        final stat = await entity.stat();
        fileSizes[entity.path] = stat.size;
        modified[path_utils.normalizePath(entity.path)] = stat.modified;
      } catch (_) {
        // Vanished while listing.
      }
    }
  }
  final load = await loadRideHistoryIndexed(
    fileSizes.keys.toList(),
    indexFilePath: indexFilePath,
  );
  final loadedJsons = <String>{
    for (final record in load.rides)
      if (record.telemetryPath != null)
        path_utils.normalizePath(record.telemetryPath!),
  };
  final anyJsonFailed = fileSizes.keys.any(
    (path) =>
        path.toLowerCase().endsWith(ride_codec.rideTelemetryFileSuffix) &&
        !loadedJsons.contains(path_utils.normalizePath(path)),
  );
  final protectedPaths = <String>{};
  final rides = <StorageBudgetRide>[];
  final records = <String, RideRecord>{};
  for (final record in load.rides) {
    final id = record.telemetryPath ?? record.videoPath;
    final files = filesOfRide(record);
    if (anyJsonFailed && record.telemetryPath == null) {
      protectedPaths.addAll(files.map(path_utils.normalizePath));
    }
    DateTime? newest;
    for (final file in files) {
      final time = modified[path_utils.normalizePath(file)];
      if (time != null && (newest == null || time.isAfter(newest))) {
        newest = time;
      }
    }
    records[id] = record;
    rides.add(
      StorageBudgetRide(
        id: id,
        createdAt: record.createdAt,
        files: files,
        rideSessionId: record.rideSessionId,
        isLocked: record.isLocked,
        hasQuarantinedPaths: record.hasQuarantinedSegments,
        lastModified: newest,
      ),
    );
  }
  return StorageBudgetInventory(
    fileSizes: fileSizes,
    rides: rides,
    records: records,
    protectedPaths: protectedPaths,
  );
}

/// Rider-facing notice for what one recording session's budget runs did,
/// or `null` when there is nothing to say: for example 'Storage budget:
/// deleted 3 oldest unlocked rides (2.4 GB).'.
String? storageBudgetNotice({
  required int deletedRides,
  required int deletedBytes,
  required bool unattainable,
  required int budgetBytes,
  int failedFiles = 0,
}) {
  final parts = <String>[];
  if (deletedRides > 0) {
    parts.add(
      'Storage budget: deleted $deletedRides oldest unlocked '
      'ride${deletedRides == 1 ? '' : 's'} (${formatStorageGb(deletedBytes)})',
    );
  }
  if (failedFiles > 0) {
    parts.add('$failedFiles file(s) could not be deleted');
  }
  if (unattainable) {
    final gigabytes = budgetBytes ~/ (1024 * 1024 * 1024);
    parts.add(
      '${deletedRides > 0 ? 'the' : 'Storage'} budget of $gigabytes GB '
      'cannot be met: rides it never deletes (locked rides, the current '
      'recording) already use more, so nothing more was deleted',
    );
  }
  if (parts.isEmpty) {
    return null;
  }
  return '${parts.join('; ')}.';
}

/// [bytes] in GB (1024^3) with one decimal, for example '2.4 GB'.
String formatStorageGb(int bytes) =>
    '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
