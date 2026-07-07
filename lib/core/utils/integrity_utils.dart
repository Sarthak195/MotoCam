/// Shared integrity and hashing utilities for telemetry and ride-record
/// persistence.
///
/// These helpers produce deterministic SHA-256 hashes of JSON payloads and
/// video segment files, and provide an atomic-write primitive for telemetry
/// JSON files.
library;

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
    final normalizedEntries = value.entries
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
  if (!await file.exists()) {
    return null;
  }

  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// Writes [content] to [telemetryFile] atomically via a temporary `.tmp`
/// file, falling back to copy-then-delete when rename fails (e.g. across
/// filesystems).
Future<void> writeTelemetryAtomically({
  required File telemetryFile,
  required String content,
}) async {
  final parent = telemetryFile.parent;
  if (!await parent.exists()) {
    await parent.create(recursive: true);
  }

  final tempFile = File('${telemetryFile.path}.tmp');
  await tempFile.writeAsString(content, flush: true);

  try {
    if (await telemetryFile.exists()) {
      await telemetryFile.delete();
    }
    await tempFile.rename(telemetryFile.path);
  } catch (_) {
    await tempFile.copy(telemetryFile.path);
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
  }
}
