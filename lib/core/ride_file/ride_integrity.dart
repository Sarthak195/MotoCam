/// The SHA-256 integrity envelope stored under a ride JSON's `integrity`
/// key: building it for the writer, re-sealing it after a lock change, and
/// checking it when a ride is read.
///
/// The envelope is an unkeyed SHA-256 checksum: it shows that a ride is
/// unmodified since it was recorded (or accidentally corrupted), but anyone
/// who can rewrite the files can also recompute it. It is not tamper-proof.
///
/// Part of the ride-file codec; import it through
/// `ride_telemetry_codec.dart`.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../utils/integrity_utils.dart' as integrity_utils;
import '../utils/path_utils.dart' as path_utils;

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

/// Outcome of checking a ride's integrity envelope.
///
/// The envelope is an unkeyed SHA-256 checksum, so [verified] means the
/// checked data is unmodified since recording, not that it is tamper-proof.
enum RideIntegrityStatus {
  /// No envelope to check: a ride recorded before envelopes were written,
  /// an incomplete ride (`sessionComplete: false`) without an envelope (this
  /// app seals its checkpoints, so it does not write these), or a video-only
  /// ride with no JSON.
  unknown,

  /// Every check that ran passed.
  verified,

  /// At least one check failed, the envelope is missing where it is
  /// mandatory, or segment paths were quarantined.
  modified,
}

/// Result of an integrity check: a [status] plus machine-readable [issues]
/// such as `payload-hash-mismatch` or `segment-hash-mismatch:<path>`.
class RideIntegrityReport {
  const RideIntegrityReport._({
    required this.status,
    required this.hasMetadata,
    required this.issues,
  });

  /// Report for a ride without an integrity envelope.
  const RideIntegrityReport.unknown()
    : status = RideIntegrityStatus.unknown,
      hasMetadata = false,
      issues = const <String>[];

  /// Report for a ride whose checks all passed.
  const RideIntegrityReport.verified()
    : status = RideIntegrityStatus.verified,
      hasMetadata = true,
      issues = const <String>[];

  /// Report for a ride with at least one failed check listed in [issues].
  factory RideIntegrityReport.modified(
    List<String> issues, {
    bool hasMetadata = true,
  }) {
    return RideIntegrityReport._(
      status: RideIntegrityStatus.modified,
      hasMetadata: hasMetadata,
      issues: List<String>.unmodifiable(issues),
    );
  }

  /// Overall result.
  final RideIntegrityStatus status;

  /// Whether the ride JSON carried a usable integrity envelope.
  final bool hasMetadata;

  /// Failed checks; empty unless [status] is [RideIntegrityStatus.modified].
  final List<String> issues;

  /// Whether [status] is [RideIntegrityStatus.verified]. Only tests read it.
  @visibleForTesting
  bool get isVerified => status == RideIntegrityStatus.verified;
}

/// One trusted segment of a ride as the integrity check sees it: the
/// [resolvedPath] that is hashed and the [declaredPath] written in the JSON
/// (used to find its entry in `segmentHashes`).
class RideIntegritySegment {
  /// Creates a segment entry for [checkRideIntegrity].
  const RideIntegritySegment({
    required this.resolvedPath,
    required this.declaredPath,
    required this.isMissing,
  });

  /// Path of the file to hash.
  final String resolvedPath;

  /// Path as written in `segmentPaths` (or [resolvedPath] when the segment
  /// was not declared there).
  final String declaredPath;

  /// Whether the file did not exist when the segments were resolved.
  final bool isMissing;
}

/// Computes the SHA-256 of the segment file at [path], whose envelope
/// records [expectedHash], or returns `null` when it cannot be read.
///
/// [checkRideIntegrity] compares the result with [expectedHash]; a caller
/// may answer from a cache of earlier results for the same file content.
typedef SegmentFileHasher =
    Future<String?> Function(String path, String expectedHash);

/// The default [SegmentFileHasher]: hashes the file on this isolate.
Future<String?> hashSegmentFile(String path, String expectedHash) =>
    integrity_utils.hashFileSha256(path);

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
  return integrity_utils.hashJsonCanonical(hashed);
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

/// Checks the integrity envelope of [json] against the ride's trusted
/// [segments] (in recording order).
///
/// Fails closed: an invalid envelope, or a missing one on a completed ride
/// whose [schemaVersion] makes it mandatory, is reported as modified. A
/// segment that exists but has no hash is an issue; a segment whose file is
/// missing is not (readers report it as missing footage). Segment files are
/// hashed only when [verifySegments] is `true`, with [hashSegment]
/// (default [hashSegmentFile]).
Future<RideIntegrityReport> checkRideIntegrity({
  required Map<String, dynamic> json,
  required int schemaVersion,
  required bool sessionComplete,
  required List<RideIntegritySegment> segments,
  bool verifySegments = false,
  SegmentFileHasher hashSegment = hashSegmentFile,
}) async {
  final rawIntegrity = json['integrity'];
  if (rawIntegrity == null) {
    // Only a completed ride must carry an envelope. An incomplete one
    // (sessionComplete: false) without it is reported as unknown, not
    // modified; this app seals its checkpoints, so it never writes one.
    final isSealedSchema = schemaVersion >= mandatoryIntegritySchemaVersion;
    if (isSealedSchema && sessionComplete) {
      return RideIntegrityReport.modified(const <String>[
        'missing-integrity',
      ], hasMetadata: false);
    }
    return const RideIntegrityReport.unknown();
  }
  if (rawIntegrity is! Map) {
    return RideIntegrityReport.modified(const <String>[
      'invalid-integrity',
    ], hasMetadata: false);
  }

  final integrity = rawIntegrity.map(
    (key, value) => MapEntry(key.toString(), value),
  );
  final issues = <String>[];

  final algorithm = (integrity['algo']?.toString().trim().toLowerCase() ?? '');
  if (algorithm != integrityAlgorithmSha256) {
    issues.add('unsupported-integrity-algorithm:$algorithm');
  }

  final rawEnvelopeVersion = integrity['envelopeVersion'];
  final envelopeVersion = integrityEnvelopeVersionOf(integrity);
  if (rawEnvelopeVersion != null &&
      (rawEnvelopeVersion is! num ||
          envelopeVersion < 1 ||
          envelopeVersion > boundIntegrityEnvelopeVersion)) {
    issues.add('unsupported-integrity-version:$rawEnvelopeVersion');
  }

  final expectedPayloadHash =
      integrity['payloadHash']?.toString().trim().toLowerCase() ?? '';
  if (expectedPayloadHash.isEmpty) {
    issues.add('missing-payload-hash');
  } else {
    final actualPayloadHash = computeRidePayloadHash(json);
    if (actualPayloadHash != expectedPayloadHash) {
      issues.add('payload-hash-mismatch');
    }
  }

  final expectedSegmentHashes = _readExpectedSegmentHashes(integrity);
  final matchedHashKeys = <String>{};
  for (final segment in segments) {
    final segmentPath = segment.resolvedPath;
    final hashKey = _segmentHashKey(
      expectedSegmentHashes,
      declaredPath: segment.declaredPath,
      resolvedPath: segmentPath,
    );
    if (hashKey == null) {
      if (!segment.isMissing) {
        issues.add('missing-segment-hash:$segmentPath');
      }
      continue;
    }
    matchedHashKeys.add(hashKey);

    if (!verifySegments || segment.isMissing) {
      continue;
    }

    final expectedHash = expectedSegmentHashes[hashKey]!;
    final actualHash = await hashSegment(segmentPath, expectedHash);
    if (actualHash == null) {
      if (await File(segmentPath).exists()) {
        issues.add('unreadable-segment-file:$segmentPath');
      }
      continue;
    }

    if (actualHash != expectedHash) {
      issues.add('segment-hash-mismatch:$segmentPath');
    }
  }

  for (final hashedPath in expectedSegmentHashes.keys) {
    if (!matchedHashKeys.contains(hashedPath)) {
      issues.add('orphan-integrity-hash:$hashedPath');
    }
  }

  if (issues.isEmpty) {
    return const RideIntegrityReport.verified();
  }
  return RideIntegrityReport.modified(issues);
}

/// Returns [integrity] downgraded to modified, with the extra issue
/// `quarantined-segment-paths:<count>`, when any path was quarantined;
/// otherwise returns it unchanged.
RideIntegrityReport applyQuarantineToIntegrity(
  RideIntegrityReport integrity,
  List<String> quarantinedPaths,
) {
  if (quarantinedPaths.isEmpty) {
    return integrity;
  }

  final issues = <String>[
    ...integrity.issues,
    'quarantined-segment-paths:${quarantinedPaths.length}',
  ];
  return RideIntegrityReport.modified(
    issues,
    hasMetadata: integrity.hasMetadata,
  );
}

/// The SHA-256 the envelope of [json] records for each of [segments], keyed
/// by resolved path, found the way [checkRideIntegrity] finds it (declared
/// path, then resolved path, then plain file name). Segments without a
/// recorded hash, and every segment of a ride without an envelope map, are
/// absent.
Map<String, String> expectedSegmentHashesOf(
  Map<String, dynamic> json,
  List<RideIntegritySegment> segments,
) {
  final rawIntegrity = json['integrity'];
  if (rawIntegrity is! Map) {
    return const <String, String>{};
  }
  final expected = _readExpectedSegmentHashes(
    rawIntegrity.map((key, value) => MapEntry(key.toString(), value)),
  );
  final result = <String, String>{};
  for (final segment in segments) {
    final hashKey = _segmentHashKey(
      expected,
      declaredPath: segment.declaredPath,
      resolvedPath: segment.resolvedPath,
    );
    if (hashKey != null) {
      result[segment.resolvedPath] = expected[hashKey]!;
    }
  }
  return Map<String, String>.unmodifiable(result);
}

/// Finds the `segmentHashes` key for a segment: its declared path, its
/// resolved path, or its plain file name (for writers that store names
/// relative to the recordings directory).
String? _segmentHashKey(
  Map<String, String> expectedSegmentHashes, {
  required String declaredPath,
  required String resolvedPath,
}) {
  for (final candidate in <String>[
    declaredPath,
    resolvedPath,
    path_utils.fileNameFromPath(resolvedPath),
  ]) {
    if (expectedSegmentHashes.containsKey(candidate)) {
      return candidate;
    }
  }
  return null;
}

Map<String, String> _readExpectedSegmentHashes(Map<String, dynamic> integrity) {
  final raw = integrity['segmentHashes'];
  if (raw is! Map) {
    return const <String, String>{};
  }

  final parsed = <String, String>{};
  for (final entry in raw.entries) {
    final path = entry.key.toString().trim();
    final hash = entry.value.toString().trim().toLowerCase();
    if (path.isEmpty || hash.isEmpty) {
      continue;
    }
    parsed[path] = hash;
  }
  return Map<String, String>.unmodifiable(parsed);
}
