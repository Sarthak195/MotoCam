/// Shared integrity and hashing utilities for telemetry and ride-record
/// persistence.
///
/// These helpers produce deterministic SHA-256 hashes of JSON payloads and
/// video segment files, build and re-seal the ride integrity envelope, and
/// provide an atomic-replace write primitive for telemetry JSON files.
///
/// The envelope is an unkeyed SHA-256 checksum: it shows that a ride is
/// unmodified since it was recorded (or accidentally corrupted), but anyone
/// who can rewrite the files can also recompute it. It is not tamper-proof.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Value of the envelope's `algo` field.
const String integrityAlgorithmSha256 = 'sha256';

/// Envelope format whose `payloadHash` covers the ride JSON *and* every
/// envelope field except `payloadHash` itself (so `segmentHashes`,
/// `segmentCount` and `generatedAt` are bound into the hash).
///
/// Envelopes without an `envelopeVersion` field are legacy (version 1):
/// their `payloadHash` covers only the ride JSON minus `integrity`.
const int boundIntegrityEnvelopeVersion = 2;

/// First ride-JSON `schemaVersion` for which the integrity envelope is
/// mandatory on completed rides (`sessionComplete` not `false`). Readers
/// treat a missing envelope on such files as modified instead of as a
/// legacy ride.
const int mandatoryIntegritySchemaVersion = 3;

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

/// Returns the envelope format version of [envelope]: the integer value of
/// `envelopeVersion`, or 1 (legacy) when the field is absent or not numeric.
int integrityEnvelopeVersionOf(Map<dynamic, dynamic> envelope) {
  final raw = envelope['envelopeVersion'];
  if (raw is num) {
    return raw.toInt();
  }
  return 1;
}

/// Computes the `payloadHash` for a ride JSON map ([rideJson] may or may not
/// contain its `integrity` envelope).
///
/// * Bound envelopes (`envelopeVersion` >= [boundIntegrityEnvelopeVersion]):
///   hashes the whole ride JSON with the envelope's `payloadHash` removed.
/// * Legacy envelopes, or no envelope: hashes the ride JSON minus
///   `integrity`, which is how files written before version 2 were sealed.
String computeRidePayloadHash(Map<String, dynamic> rideJson) {
  final hashed = Map<String, dynamic>.from(rideJson);
  final rawIntegrity = hashed['integrity'];
  if (rawIntegrity is Map &&
      integrityEnvelopeVersionOf(rawIntegrity) >=
          boundIntegrityEnvelopeVersion) {
    hashed['integrity'] = Map<dynamic, dynamic>.from(rawIntegrity)
      ..remove('payloadHash');
  } else {
    hashed.remove('integrity');
  }
  return hashJsonCanonical(hashed);
}

/// Builds a bound (version 2) integrity envelope for [payload].
///
/// [payload] is the ride JSON without its `integrity` key. [segmentHashes]
/// maps each declared segment path to its SHA-256 digest, and
/// [segmentCount] is the number of declared segments. The returned map is
/// meant to be stored as the ride JSON's `integrity` value.
Map<String, dynamic> buildIntegrityEnvelope({
  required Map<String, dynamic> payload,
  required Map<String, String> segmentHashes,
  required int segmentCount,
  DateTime? generatedAt,
}) {
  final envelope = <String, dynamic>{
    'algo': integrityAlgorithmSha256,
    'envelopeVersion': boundIntegrityEnvelopeVersion,
    'segmentCount': segmentCount,
    'hashedSegmentCount': segmentHashes.length,
    'segmentHashes': Map<String, String>.from(segmentHashes),
    'generatedAt': (generatedAt ?? DateTime.now()).toIso8601String(),
  };
  final unsealed = Map<String, dynamic>.from(payload)..['integrity'] = envelope;
  envelope['payloadHash'] = computeRidePayloadHash(unsealed);
  return envelope;
}

/// Recomputes the `payloadHash` of the envelope already stored in
/// [rideJson] after other fields changed, keeping its `segmentHashes` and
/// other fields as they are and upgrading it to the bound format.
///
/// Callers must verify the ride (including its segment hashes) before
/// re-sealing, otherwise this would seal unverified data. Throws a
/// [StateError] when [rideJson] has no envelope map.
void resealIntegrityEnvelope(Map<String, dynamic> rideJson) {
  final rawIntegrity = rideJson['integrity'];
  if (rawIntegrity is! Map) {
    throw StateError('Ride JSON has no integrity envelope to re-seal.');
  }

  final envelope =
      rawIntegrity.map((key, value) => MapEntry(key.toString(), value))
        ..remove('payloadHash')
        ..['envelopeVersion'] = boundIntegrityEnvelopeVersion;
  rideJson['integrity'] = envelope;
  envelope['payloadHash'] = computeRidePayloadHash(rideJson);
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
