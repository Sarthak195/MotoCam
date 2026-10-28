/// Shared hashing and file-write utilities for telemetry and ride-record
/// persistence.
///
/// These helpers produce deterministic SHA-256 hashes of JSON payloads and
/// video segment files, serialise read-modify-write cycles per path, and
/// provide an atomic-replace write primitive for telemetry JSON files. The
/// ride integrity envelope built from these hashes lives in the ride-file
/// codec (`lib/core/ride_file/ride_integrity.dart`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Returns the SHA-256 hex digest of [payload] after recursively sorting all
/// map keys to ensure a canonical representation.
///
/// This is used to create integrity hashes that are independent of
/// serialisation order.
String hashJsonCanonical(Map<String, dynamic> payload) {
  final canonical = canonicalizeJsonValue(payload);
  final encoded = utf8.encode(jsonEncode(canonical));
  return sha256.convert(encoded).toString();
}

/// Recursively sorts map keys and normalises non-primitive values so that
/// the output of `jsonEncode` is deterministic.
Object? canonicalizeJsonValue(Object? value) {
  if (value is Map) {
    final normalizedEntries =
        value.entries
            .map((entry) => MapEntry(entry.key.toString(), entry.value))
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));

    final normalized = <String, Object?>{};
    for (final entry in normalizedEntries) {
      normalized[entry.key] = canonicalizeJsonValue(entry.value);
    }
    return normalized;
  }

  if (value is List) {
    return value.map(canonicalizeJsonValue).toList(growable: false);
  }

  if (value == null || value is String || value is num || value is bool) {
    return value;
  }

  return value.toString();
}

/// Returns the SHA-256 hex digest of the file at [path], or `null` if the
/// path is empty, the file does not exist, or reading fails.
Future<String?> hashFileSha256(String path) async {
  final candidate = path.trim();
  if (candidate.isEmpty) {
    return null;
  }

  final file = File(candidate);
  try {
    if (!await file.exists()) {
      return null;
    }

    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  } on FileSystemException {
    return null;
  }
}

final Map<String, Future<void>> _pathLocks = <String, Future<void>>{};
int _tempFileCounter = 0;

/// Runs [action] after every earlier [runExclusiveForPath] call for the same
/// [path] has finished, so read-modify-write cycles on one file do not
/// interleave within this isolate.
Future<T> runExclusiveForPath<T>(String path, Future<T> Function() action) {
  final key = path.trim();
  final previous = _pathLocks[key] ?? Future<void>.value();
  final completer = Completer<void>();
  final current = completer.future;
  _pathLocks[key] = current;

  return previous.then((_) => action()).whenComplete(() {
    completer.complete();
    if (identical(_pathLocks[key], current)) {
      unawaited(_pathLocks.remove(key));
    }
  });
}

/// Writes [content] to [telemetryFile] through a uniquely named temporary
/// file in the same directory, then renames it over the target.
///
/// The rename replaces an existing target in one step, so the target is
/// never deleted first and concurrent writers cannot share a temp file.
/// Writes to the same target from this isolate are queued, and the last one
/// wins. If the rename fails (e.g. across filesystems) the temp file is
/// copied onto the target instead, which is not atomic. The temp file is
/// always removed afterwards.
Future<void> writeTelemetryAtomically({
  required File telemetryFile,
  required String content,
}) {
  // A separate key from runExclusiveForPath(path) so callers holding that
  // lock for a read-modify-write can still write.
  return runExclusiveForPath<void>(
    'write-lock:${telemetryFile.path}',
    () => _writeViaTempFile(telemetryFile: telemetryFile, content: content),
  );
}

Future<void> _writeViaTempFile({
  required File telemetryFile,
  required String content,
}) async {
  final parent = telemetryFile.parent;
  if (!await parent.exists()) {
    await parent.create(recursive: true);
  }

  final uniqueSuffix =
      '$pid-${DateTime.now().microsecondsSinceEpoch}-${_tempFileCounter++}';
  final tempFile = File('${telemetryFile.path}.$uniqueSuffix.tmp');

  try {
    await tempFile.writeAsString(content, flush: true);
    try {
      await tempFile.rename(telemetryFile.path);
    } catch (_) {
      await tempFile.copy(telemetryFile.path);
    }
  } finally {
    try {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    } catch (_) {
      // A leftover temp file is removed by pruneStaleTelemetryTempFiles.
    }
  }
}

/// Returns `true` when [path] names a temporary file left by
/// [writeTelemetryAtomically] (current or legacy naming).
bool isTelemetryTempFilePath(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.tmp') && lower.contains('.telemetry.json.');
}

/// Deletes telemetry temp files directly inside [directory] that are older
/// than [olderThan], and returns how many were deleted.
///
/// Intended to run once at startup to clean up after a process that was
/// killed mid-write. Errors are ignored.
Future<int> pruneStaleTelemetryTempFiles(
  Directory directory, {
  Duration olderThan = const Duration(minutes: 10),
}) async {
  var deleted = 0;
  try {
    if (!await directory.exists()) {
      return 0;
    }
    final cutoff = DateTime.now().subtract(olderThan);
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !isTelemetryTempFilePath(entity.path)) {
        continue;
      }
      try {
        if ((await entity.stat()).modified.isBefore(cutoff)) {
          await entity.delete();
          deleted++;
        }
      } catch (_) {
        // Skip files that vanish or cannot be deleted.
      }
    }
  } catch (_) {
    // Directory may be inaccessible.
  }
  return deleted;
}
