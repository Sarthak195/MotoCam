/// The gallery export queue (Android): copies private segments to the
/// phone's gallery one at a time through `exportVideoToGallery`, with the
/// queue and the resulting links kept in the [GalleryLinkStore], so a queue
/// left behind by a killed process is retried and no segment is copied
/// twice.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../../core/utils/path_utils.dart' as path_utils;
import '../../history/services/gallery_copy_removal.dart';
import '../../history/services/gallery_links.dart';

/// A private segment to copy to the gallery.
class GalleryExportItem {
  /// Creates an item for the segment at [sourcePath] of the ride
  /// [rideSessionId] (`null` for a video without a ride id).
  const GalleryExportItem({
    required this.rideSessionId,
    required this.sourcePath,
  });

  /// The ride's id, or `null`.
  final String? rideSessionId;

  /// Where the segment is now.
  final String sourcePath;

  /// File name of the segment.
  String get fileName => path_utils.fileNameFromPath(sourcePath);

  /// The store key of the segment.
  String get key =>
      galleryLinkKey(rideSessionId: rideSessionId, fileName: fileName);
}

/// Copies the file at [sourcePath] to the gallery under [displayName] and
/// returns the copy's content URI (the `exportVideoToGallery` call).
/// [queuedAt] is when the segment was queued: only a copy added since then
/// may be reused instead of copying again.
typedef GalleryExportCall =
    Future<String?> Function({
      required String sourcePath,
      required String displayName,
      required DateTime queuedAt,
    });

/// Finds the file of a pending entry now, or returns `null` when it is gone.
typedef GalleryExportLocator =
    Future<String?> Function(PendingGalleryExport entry);

/// What [GalleryExporter.enqueue] did.
class GalleryEnqueueResult {
  /// Creates a result.
  const GalleryEnqueueResult({required this.keys, required this.alreadySaved});

  /// Keys of the given items that are now pending (queued by this call or
  /// already queued before).
  final Set<String> keys;

  /// Items left out because a gallery copy of them is already linked.
  final int alreadySaved;
}

/// What one [GalleryExporter.drain] did.
class GalleryExportRun {
  /// Creates a result.
  const GalleryExportRun({
    this.exported = 0,
    this.alreadySaved = 0,
    this.missing = 0,
    this.failed = 0,
    this.discarded = 0,
    this.awaitingPermission = 0,
    this.permissionDenied = false,
    this.paused = false,
  });

  /// Segments copied.
  final int exported;

  /// Pending entries dropped because a copy of them was already linked.
  final int alreadySaved;

  /// Pending entries dropped because their file is gone.
  final int missing;

  /// Segments that could not be copied in this run (they stay queued until
  /// [GalleryExporter.maxAttempts] failed attempts).
  final int failed;

  /// Copies deleted again at once because their entry was dropped from the
  /// queue while they were made (the ride was deleted or unlocked, or its
  /// copies removed).
  final int discarded;

  /// Segments left queued, without counting an attempt, because the
  /// storage permission was missing and this drain did not ask for it
  /// (Android 9 and lower).
  final int awaitingPermission;

  /// Whether at least one failure was the storage permission being denied
  /// (Android 9 and lower).
  final bool permissionDenied;

  /// Whether the run stopped early because it was asked to pause (for
  /// example a recording started); the rest stays queued.
  final bool paused;

  /// Whether the run copied or failed anything.
  bool get hasOutcome => exported > 0 || failed > 0;
}

/// Error code `exportVideoToGallery` returns on Android 9 and lower without
/// the storage permission.
const String galleryPermissionDeniedCode = 'PERMISSION_DENIED';

/// Finds a pending segment's file: its queued path when it still exists
/// inside one of [roots], otherwise a file of the same name directly in
/// one of [roots] (the recordings directory first, then the legacy roots),
/// because the migration or an import may have moved the ride. Returns
/// `null` when none exists. A path outside [roots] is never returned.
Future<String?> locateGalleryExportSource({
  required PendingGalleryExport entry,
  required List<String> roots,
  Future<bool> Function(String path)? exists,
}) async {
  final check = exists ?? (String path) => File(path).exists();
  Future<bool> safeCheck(String path) async {
    try {
      return await check(path);
    } catch (_) {
      return false;
    }
  }

  final queued = entry.sourcePath.trim();
  if (queued.isNotEmpty &&
      roots.any((root) => path_utils.isPathInsideDirectory(queued, root)) &&
      await safeCheck(queued)) {
    return queued;
  }
  for (final root in roots) {
    final candidate = '$root${Platform.pathSeparator}${entry.fileName}';
    if (await safeCheck(candidate)) {
      return candidate;
    }
  }
  return null;
}

/// The gallery export queue on top of a [GalleryLinkStore].
///
/// [enqueue] writes entries to the store's `pending` map before anything is
/// copied; [drain] copies them one at a time and moves each copied entry
/// to `links` with the content URI. A segment whose key is already linked
/// is never copied again. Drains run one at a time, in call order.
class GalleryExporter {
  /// Creates an exporter.
  ///
  /// [requestStoragePermission] asks for the storage permission (Android 9
  /// and lower) and returns whether it was granted; a drain calls it only
  /// when `askPermission` is true. [deleteCopies] deletes gallery copies
  /// by content URI (the app passes `GalleryCopies.delete`); without it a
  /// copy whose entry was dropped during the copy is linked instead.
  GalleryExporter({
    required this.store,
    required this.exportVideo,
    required this.locate,
    this.requestStoragePermission,
    this.deleteCopies,
    this.relativePath = 'Movies/MotoCam/Recordings',
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Failed attempts after which a pending entry is dropped.
  static const int maxAttempts = 3;

  /// The store holding the queue and the links.
  final GalleryLinkStore store;

  /// The native copy.
  final GalleryExportCall exportVideo;

  /// Finds a pending entry's file.
  final GalleryExportLocator locate;

  /// Asks for the storage permission; see the constructor.
  final Future<bool> Function()? requestStoragePermission;

  /// Deletes fresh copies whose entry was dropped; see the constructor.
  final GalleryCopyStatusCall? deleteCopies;

  /// The gallery folder copies go to (recorded in each link).
  final String relativePath;

  final DateTime Function() _now;
  Future<void> _tail = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Adds [items] to the persisted queue, skipping items already queued
  /// and items whose copy is already linked. Completes once the queue is
  /// written.
  Future<GalleryEnqueueResult> enqueue(Iterable<GalleryExportItem> items) {
    return _serialized(() async {
      final data = await store.read();
      final keys = <String>{};
      var alreadySaved = 0;
      final toAdd = <String, PendingGalleryExport>{};
      for (final item in items) {
        final sourcePath = item.sourcePath.trim();
        if (sourcePath.isEmpty) {
          continue;
        }
        final key = item.key;
        if (data.links.containsKey(key)) {
          alreadySaved++;
          continue;
        }
        keys.add(key);
        if (!data.pending.containsKey(key) && !toAdd.containsKey(key)) {
          toAdd[key] = PendingGalleryExport(
            rideSessionId: item.rideSessionId,
            fileName: item.fileName,
            sourcePath: sourcePath,
            queuedAt: _now(),
          );
        }
      }
      if (toAdd.isNotEmpty) {
        await store.update((data) => data.pending.addAll(toAdd));
      }
      return GalleryEnqueueResult(keys: keys, alreadySaved: alreadySaved);
    });
  }

  /// Forgets the links among [keys] whose gallery copy no longer exists
  /// (for example the rider deleted it in a gallery app), so the segment
  /// can be copied again. [existingUris] returns which of the given URIs
  /// still exist, or `null` when that cannot be checked (then nothing is
  /// forgotten). Returns how many links were forgotten.
  Future<int> forgetMissingLinks(
    Iterable<String> keys,
    Future<Set<String>?> Function(List<String> uris) existingUris,
  ) {
    return _serialized(() async {
      final data = await store.read();
      final links = <GalleryLink>[for (final key in keys) ?data.links[key]];
      if (links.isEmpty) {
        return 0;
      }
      final Set<String>? existing;
      try {
        existing = await existingUris(
          links.map((link) => link.contentUri).toList(growable: false),
        );
      } catch (_) {
        return 0;
      }
      if (existing == null) {
        return 0;
      }
      final gone = links
          .where((link) => !existing!.contains(link.contentUri))
          .map((link) => link.key)
          .toList(growable: false);
      if (gone.isNotEmpty) {
        await store.update((data) => gone.forEach(data.links.remove));
      }
      return gone.length;
    });
  }

  /// Copies the pending entries (only those in [onlyKeys] when given), in
  /// queue order, one at a time.
  ///
  /// For each entry: an entry whose key is already linked is dropped
  /// (never copied twice); its file is found with [locate] and the entry is
  /// dropped when the file is gone (on `SOURCE_NOT_FOUND` it is looked up
  /// once more and copied from its new place, because the migration may
  /// have just moved it); a copy moves it from `pending` to `links`. An
  /// entry dropped from the queue while its copy ran gets that copy deleted
  /// with [deleteCopies] (linked when that fails). A failed copy stays
  /// queued until [maxAttempts] failed attempts. On `PERMISSION_DENIED`,
  /// when [askPermission] is true, [requestStoragePermission] is asked once
  /// per drain and the segment is tried once more; when it is false the
  /// entry waits without counting an attempt. [shouldPause] is checked
  /// before each entry; when it returns true the drain stops and the rest
  /// stays queued.
  /// [onProgress] receives (entries done, entries to do).
  Future<GalleryExportRun> drain({
    Set<String>? onlyKeys,
    bool askPermission = false,
    bool Function()? shouldPause,
    void Function(int done, int total)? onProgress,
  }) {
    return _serialized(
      () => _drain(
        onlyKeys: onlyKeys,
        askPermission: askPermission,
        shouldPause: shouldPause,
        onProgress: onProgress,
      ),
    );
  }

  Future<GalleryExportRun> _drain({
    required Set<String>? onlyKeys,
    required bool askPermission,
    required bool Function()? shouldPause,
    required void Function(int done, int total)? onProgress,
  }) async {
    // The store's live data: an entry dropped while a copy runs (its ride
    // was deleted or unlocked, or its copies removed) is seen here.
    final data = await store.read();
    final keys = data.pending.keys
        .where((key) => onlyKeys == null || onlyKeys.contains(key))
        .toList(growable: false);
    var exported = 0;
    var alreadySaved = 0;
    var missing = 0;
    var failed = 0;
    var discarded = 0;
    var awaitingPermission = 0;
    var permissionDenied = false;
    var paused = false;
    final request = requestStoragePermission;
    final canAsk = askPermission && request != null;
    bool? permissionGranted;
    var done = 0;
    onProgress?.call(0, keys.length);

    for (final key in keys) {
      if (shouldPause?.call() ?? false) {
        paused = true;
        break;
      }
      final entry = data.pending[key];
      if (entry == null) {
        done++;
        continue;
      }
      if (data.links.containsKey(key)) {
        alreadySaved++;
        await store.update((data) => data.pending.remove(key));
        onProgress?.call(++done, keys.length);
        continue;
      }
      var path = await locate(entry);
      if (path == null) {
        missing++;
        await store.update((data) => data.pending.remove(key));
        onProgress?.call(++done, keys.length);
        continue;
      }

      String? uri;
      var sourceGone = false;
      var denied = false;
      Future<void> attempt(String from) async {
        sourceGone = false;
        denied = false;
        try {
          uri = await exportVideo(
            sourcePath: from,
            displayName: entry.fileName,
            queuedAt: entry.queuedAt,
          );
        } on PlatformException catch (e) {
          sourceGone = e.code == 'SOURCE_NOT_FOUND';
          denied = e.code == galleryPermissionDeniedCode;
        } catch (_) {
          // Counted as a failure below; the private copy stays.
        }
      }

      await attempt(path);
      if (sourceGone) {
        // The migration may have moved the file just now: look once more.
        final moved = await locate(entry);
        if (moved != null && moved != path) {
          path = moved;
          await attempt(moved);
        }
      }
      if (denied && canAsk) {
        if (permissionGranted == null) {
          try {
            permissionGranted = await request();
          } catch (_) {
            permissionGranted = false;
          }
        }
        if (permissionGranted) {
          await attempt(path);
        }
      }

      final copied = uri;
      if (copied != null && copied.isNotEmpty) {
        // Dropped from the queue while the copy ran: the copy is deleted
        // at once, or linked when that fails, so none is left untracked.
        if (!data.pending.containsKey(key) && await _discardCopy(copied)) {
          discarded++;
        } else {
          exported++;
          final link = GalleryLink(
            rideSessionId: entry.rideSessionId,
            fileName: entry.fileName,
            contentUri: copied,
            displayName: entry.fileName,
            relativePath: relativePath,
            exportedAt: _now(),
          );
          await store.update((data) {
            data.pending.remove(key);
            data.links[key] = link;
          });
        }
      } else if (sourceGone) {
        missing++;
        await store.update((data) => data.pending.remove(key));
      } else if (denied && !canAsk) {
        // Nobody was asked for the permission in this drain: the entry
        // waits, untouched, for a drain that may ask.
        awaitingPermission++;
      } else {
        failed++;
        permissionDenied = permissionDenied || denied;
        final attempts = entry.attempts + 1;
        await store.update((data) {
          if (!data.pending.containsKey(key)) {
            // Dropped meanwhile; never queued again here.
            return;
          }
          if (attempts >= maxAttempts) {
            data.pending.remove(key);
          } else {
            data.pending[key] = entry.withAttempts(attempts);
          }
        });
      }
      onProgress?.call(++done, keys.length);
    }

    return GalleryExportRun(
      exported: exported,
      alreadySaved: alreadySaved,
      missing: missing,
      failed: failed,
      discarded: discarded,
      awaitingPermission: awaitingPermission,
      permissionDenied: permissionDenied,
      paused: paused,
    );
  }

  /// Deletes the fresh gallery copy at [uri] with [deleteCopies]; returns
  /// whether it is gone.
  Future<bool> _discardCopy(String uri) async {
    final delete = deleteCopies;
    if (delete == null) {
      return false;
    }
    try {
      return (await delete(<String>[uri]))[uri]?.isRemoved ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// Rider-facing summary of a Save to gallery run of a ride.
String gallerySaveSummary(GalleryExportRun run) {
  String segments(int n) => '$n segment${n == 1 ? '' : 's'}';
  final parts = <String>[
    if (run.exported > 0)
      'Saved ${segments(run.exported)} to Movies/MotoCam/Recordings',
    if (run.alreadySaved > 0)
      '${segments(run.alreadySaved)} already in the gallery',
    if (run.missing > 0) '${segments(run.missing)} no longer on the phone',
    if (run.discarded > 0)
      '${segments(run.discarded)} not kept: the ride changed meanwhile',
    if (run.failed > 0)
      run.permissionDenied
          ? '${segments(run.failed)} not saved: storage access was denied. '
                'Allow Storage for MotoCam in the phone\'s settings to save '
                'to the gallery'
          : '${segments(run.failed)} could not be saved; try again',
    if (run.paused) 'saving paused for the recording and resumes after it',
  ];
  if (parts.isEmpty) {
    return 'Nothing to save: this ride has no video on the phone.';
  }
  final message = parts.join('; ');
  return '${message[0].toUpperCase()}${message.substring(1)}.';
}
