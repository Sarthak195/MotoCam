/// The one codec for MotoCam's per-ride telemetry JSON
/// (`ride_<id>.telemetry.json`).
///
/// It owns every rule of the file format, for the writer
/// (`TelemetryProvider`), the reader and lock-state rewrite (`RideRecord`)
/// and playback:
///
/// * decoding a ride JSON map: [decodeRideFileSummary] (every field except
///   the samples), [decodeRideSamples] (the samples, parsed by the caller),
///   [resolveRideSegments] (segment paths against the telemetry file's
///   directory, with quarantine), and [decodeRideFile], which combines them
///   with the timeline, the locks and the integrity check;
/// * the segment-list rule ([normalizeSegmentPathList]) and the timeline
///   rule ([normalizeRideTimeline], [normalizeTimelineSpan]);
/// * encoding the writer's JSON ([resolveRideFileContent],
///   [encodeRidePayload], [sealRidePayload], [encodeRideFileJson]) and the
///   lock-state rewrite ([applyLockState]);
/// * the integrity envelope (exported from `ride_integrity.dart`).
///
/// The rules are described in docs/data-formats.md.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../utils/path_utils.dart' as path_utils;
import 'ride_integrity.dart';

export 'ride_integrity.dart';

/// `schemaVersion` written by the current writer.
const int rideFileSchemaVersion = 3;

/// `storagePolicy` written by the current writer (ignored by readers).
const String rideFileStoragePolicy = 'hybrid-private-primary';

/// Relative path of the opt-in Android gallery copies of locked clips
/// (`MediaStore` `RELATIVE_PATH`), also written as the ride JSON's
/// `publicExportRelativePath`.
const String publicExportRelativePath = 'Movies/MotoCam/Recordings';

/// The public folder that v0.1.11 and v0.1.12 recorded rides to on
/// Android (primary user only).
///
/// This is the only copy of that path in the app. It is meant only for
/// deciding whether that legacy root is trusted and for discovering rides
/// left there; today nothing reads it (the folder is neither trusted nor
/// scanned), and a later legacy-root migration imports it from here.
const String legacyPublicRecordingsDirectory =
    '/storage/emulated/0/$publicExportRelativePath';

/// Suffix of every ride telemetry file name (current and legacy names).
const String rideTelemetryFileSuffix = '.telemetry.json';

/// Lower-case file extensions treated as ride video files.
const List<String> rideVideoFileExtensions = <String>[
  '.mp4',
  '.mov',
  '.mkv',
  '.avi',
];

/// An incident detected live during a ride (an entry of the ride JSON's
/// optional top-level `incidents` list).
class RideIncident {
  /// Creates an incident record.
  const RideIncident({
    required this.elapsedMs,
    this.timestamp,
    this.gForce,
    this.triggerGForce,
    this.reason,
  });

  /// Parses one `incidents` entry, or returns `null` when it has no usable
  /// non-negative `elapsedMs`.
  static RideIncident? fromJson(Map<String, dynamic> json) {
    final rawElapsed = json['elapsedMs'];
    final elapsed = rawElapsed is num
        ? rawElapsed
        : num.tryParse(rawElapsed?.toString() ?? '');
    if (elapsed == null || !elapsed.isFinite || elapsed < 0) {
      return null;
    }
    double? readDouble(String key) {
      final raw = json[key];
      final value = raw is num ? raw : num.tryParse(raw?.toString() ?? '');
      return value == null || !value.isFinite ? null : value.toDouble();
    }

    final reason = json['reason']?.toString().trim();
    return RideIncident(
      elapsedMs: elapsed.toInt(),
      timestamp: DateTime.tryParse(
        json['timestamp']?.toString() ?? '',
      )?.toLocal(),
      gForce: readDouble('gForce'),
      triggerGForce: readDouble('triggerGForce'),
      reason: reason == null || reason.isEmpty ? null : reason,
    );
  }

  /// Milliseconds since ride start.
  final int elapsedMs;

  /// Wall-clock detection time (local), if recorded.
  final DateTime? timestamp;

  /// Peak g-force of the incident, if recorded.
  final double? gForce;

  /// Trigger threshold in g at detection time, if recorded.
  final double? triggerGForce;

  /// Detection reason, e.g. `auto-crash`.
  final String? reason;
}

/// Start and end offset, in milliseconds from ride start, of one segment.
class RideSegmentTimelineEntry {
  /// Creates a timeline entry for the segment at [path].
  const RideSegmentTimelineEntry({
    required this.path,
    required this.startMs,
    required this.endMs,
  });

  /// Resolved segment path.
  final String path;

  /// Offset of the segment's first frame.
  final int startMs;

  /// Offset of the segment's end; never before [startMs].
  final int endMs;

  /// The `segmentTimeline` entry the writer stores for this segment.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'path': path,
    'startMs': startMs,
    'endMs': endMs,
  };
}

/// Returns `true` when [path] ends with one of [rideVideoFileExtensions].
bool isRideVideoFilePath(String path) {
  final lower = path.trim().toLowerCase();
  return rideVideoFileExtensions.any(lower.endsWith);
}

/// The legacy telemetry file name of a video: `<video path without
/// extension>.telemetry.json` (builds before commit 76974c1).
String legacyTelemetryPathForVideo(String videoPath) {
  final dotIndex = videoPath.lastIndexOf('.');
  if (dotIndex <= 0) {
    return '$videoPath$rideTelemetryFileSuffix';
  }
  return '${videoPath.substring(0, dotIndex)}$rideTelemetryFileSuffix';
}

// ---------------------------------------------------------------------------
// Shared normalisation rules.
// ---------------------------------------------------------------------------

/// The segment-list rule: every entry trimmed (`toString()` first), empty
/// entries and repeats dropped, order kept, then [videoPath] (trimmed)
/// appended when it is non-empty and not already listed.
///
/// The writer and playback apply it to the declared paths. The reader
/// applies it in two steps because path resolution can rewrite or
/// quarantine entries: it normalises `segmentPaths` (falling back to
/// `[videoPath]` only when the list is empty), resolves and trust-checks
/// the entries, and only then appends the resolved `videoPath` when it is
/// missing (see [resolveRideSegments]).
List<String> normalizeSegmentPathList(
  Iterable<Object?> paths, {
  String videoPath = '',
}) {
  final ordered = <String>[];
  final seen = <String>{};
  for (final value in paths) {
    final path = value.toString().trim();
    if (path.isEmpty || !seen.add(path)) {
      continue;
    }
    ordered.add(path);
  }

  final video = videoPath.trim();
  if (video.isNotEmpty && seen.add(video)) {
    ordered.add(video);
  }
  return ordered;
}

/// The span rule of a timeline entry: a negative [startMs] is clamped to 0
/// and [endMs] (defaulting to the clamped start) is raised to at least the
/// start.
({int startMs, int endMs}) normalizeTimelineSpan(int startMs, int? endMs) {
  final start = startMs < 0 ? 0 : startMs;
  final end = endMs ?? start;
  return (startMs: start, endMs: end >= start ? end : start);
}

/// The timeline rule: keeps the entries of [rawTimeline] (a non-list counts
/// as empty; non-object entries are skipped) whose path, mapped through
/// [resolvePath], is non-empty, in [knownPaths] and not seen before; applies
/// [normalizeTimelineSpan]; and sorts the result by start.
///
/// `startMs` and `endMs` are read as numbers (missing: 0 and the start)
/// only for kept entries; a non-number there throws, which makes readers
/// drop the ride.
List<RideSegmentTimelineEntry> normalizeRideTimeline(
  Object? rawTimeline, {
  required Set<String> knownPaths,
  required String Function(String declaredPath) resolvePath,
}) {
  final entries = <RideSegmentTimelineEntry>[];
  final seenPaths = <String>{};
  if (rawTimeline is! List) {
    return entries;
  }

  for (final rawEntry in rawTimeline.whereType<Map>()) {
    final entry = rawEntry.map((key, value) => MapEntry(key.toString(), value));
    final path = resolvePath(entry['path']?.toString() ?? '');
    if (path.isEmpty ||
        !knownPaths.contains(path) ||
        seenPaths.contains(path)) {
      continue;
    }

    final span = normalizeTimelineSpan(
      (entry['startMs'] as num?)?.toInt() ?? 0,
      (entry['endMs'] as num?)?.toInt(),
    );
    entries.add(
      RideSegmentTimelineEntry(
        path: path,
        startMs: span.startMs,
        endMs: span.endMs,
      ),
    );
    seenPaths.add(path);
  }

  entries.sort((a, b) => a.startMs.compareTo(b.startMs));
  return entries;
}

// ---------------------------------------------------------------------------
// Reading.
// ---------------------------------------------------------------------------

/// Reads and decodes [telemetryFile], returning `null` when the JSON root is
/// not an object. Read and decode errors propagate.
Future<Map<String, dynamic>?> readRideFileJson(File telemetryFile) async {
  final decoded = jsonDecode(await telemetryFile.readAsString());
  if (decoded is! Map) {
    return null;
  }
  return decoded.map((key, value) => MapEntry(key.toString(), value));
}

/// The summary fields of a ride JSON: everything except the samples, the
/// segment paths (see [resolveRideSegments]) and the timeline.
class RideFileSummary {
  /// Creates a summary. Prefer [decodeRideFileSummary].
  const RideFileSummary({
    required this.schemaVersion,
    required this.rideSessionId,
    required this.sessionComplete,
    required this.startedAt,
    required this.distanceKm,
    required this.maxSpeedKmh,
    required this.averageSpeedKmh,
    required this.mockLocationDetected,
    required this.incidents,
  });

  /// `schemaVersion`; a number is truncated, a string parsed, anything else
  /// is 0.
  final int schemaVersion;

  /// `rideSessionId` trimmed, or `null` when missing or empty.
  final String? rideSessionId;

  /// `sessionComplete` (default `true`).
  final bool sessionComplete;

  /// `startedAt` in local time, or `null` when missing or unparsable.
  final DateTime? startedAt;

  /// `distanceKm` (missing or `null`: 0).
  final double distanceKm;

  /// `maxSpeedKmh` (missing or `null`: 0).
  final double maxSpeedKmh;

  /// `averageSpeedKmh` (missing or `null`: 0).
  final double averageSpeedKmh;

  /// `mockLocationDetected` (default `false`).
  final bool mockLocationDetected;

  /// Incidents sorted by `elapsedMs`, or `null` when the key is absent.
  final List<RideIncident>? incidents;
}

/// Decodes the summary fields of [json] without touching its samples.
///
/// Throws when `distanceKm`, `maxSpeedKmh` or `averageSpeedKmh` holds a
/// non-number; readers then drop the ride.
RideFileSummary decodeRideFileSummary(Map<String, dynamic> json) {
  return RideFileSummary(
    schemaVersion: rideFileSchemaVersionOf(json),
    rideSessionId: _readOptionalString(json, 'rideSessionId'),
    sessionComplete: readRideFileBool(
      json,
      'sessionComplete',
      defaultValue: true,
    ),
    // New files store UTC ('Z'); show local wall-clock time. Offset-less
    // old files already parse as local.
    startedAt: DateTime.tryParse(
      json['startedAt']?.toString() ?? '',
    )?.toLocal(),
    distanceKm: _readJsonDouble(json, 'distanceKm'),
    maxSpeedKmh: _readJsonDouble(json, 'maxSpeedKmh'),
    averageSpeedKmh: _readJsonDouble(json, 'averageSpeedKmh'),
    mockLocationDetected: readRideFileBool(
      json,
      'mockLocationDetected',
      defaultValue: false,
    ),
    incidents: _readIncidents(json),
  );
}

/// Parses the `samples` of [json] with [parse], in file order. A non-list
/// counts as empty, non-object entries are ignored, and an entry that makes
/// [parse] throw is skipped.
List<T> decodeRideSamples<T>(
  Map<String, dynamic> json,
  T Function(Map<String, dynamic> sample) parse,
) {
  final samplesJson = json['samples'];
  final samples = <T>[];
  if (samplesJson is! List) {
    return samples;
  }

  for (final raw in samplesJson.whereType<Map>()) {
    try {
      final normalized = raw.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      samples.add(parse(normalized));
    } catch (_) {
      // Keep loading the ride even if a single sample is malformed.
    }
  }

  return samples;
}

/// `schemaVersion` of [json]: a number truncated to int, a numeric string
/// parsed, otherwise 0.
int rideFileSchemaVersionOf(Map<String, dynamic> json) {
  final raw = json['schemaVersion'];
  if (raw is num) {
    return raw.toInt();
  }
  return int.tryParse(raw?.toString() ?? '') ?? 0;
}

/// Reads a ride-file flag: a bool, the string `true` or `false` (trimmed,
/// any case), or a number (non-zero is `true`); anything else gives
/// [defaultValue].
bool readRideFileBool(
  Map<String, dynamic> json,
  String key, {
  required bool defaultValue,
}) {
  final raw = json[key];
  if (raw is bool) {
    return raw;
  }
  if (raw is String) {
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'true') {
      return true;
    }
    if (normalized == 'false') {
      return false;
    }
  }
  if (raw is num) {
    return raw != 0;
  }
  return defaultValue;
}

double _readJsonDouble(Map<String, dynamic> json, String key) =>
    (json[key] as num?)?.toDouble() ?? 0;

String? _readOptionalString(Map<String, dynamic> json, String key) {
  final raw = json[key]?.toString().trim();
  if (raw == null || raw.isEmpty) {
    return null;
  }
  return raw;
}

List<RideIncident>? _readIncidents(Map<String, dynamic> json) {
  if (!json.containsKey('incidents')) {
    return null;
  }
  final raw = json['incidents'];
  final incidents = <RideIncident>[];
  for (final entry in raw is List ? raw : const <dynamic>[]) {
    if (entry is! Map) {
      continue;
    }
    final incident = RideIncident.fromJson(
      entry.map((key, value) => MapEntry(key.toString(), value)),
    );
    if (incident != null) {
      incidents.add(incident);
    }
  }
  incidents.sort((a, b) => a.elapsedMs.compareTo(b.elapsedMs));
  return List<RideIncident>.unmodifiable(incidents);
}

/// The segment paths of a ride JSON resolved against the directory that
/// holds its telemetry file.
class ResolvedRideSegments {
  /// Creates a resolution result. Prefer [resolveRideSegments].
  const ResolvedRideSegments({
    required this.segmentPaths,
    required this.missingSegmentPaths,
    required this.quarantinedSegmentPaths,
    required this.videoPath,
    required this.resolvedByDeclared,
    required this.declaredByResolved,
  });

  /// Trusted segment paths in recording order, `videoPath` included.
  final List<String> segmentPaths;

  /// Entries of [segmentPaths] whose files did not exist.
  final List<String> missingSegmentPaths;

  /// Declared paths rejected because they lie outside the trusted root.
  final List<String> quarantinedSegmentPaths;

  /// The ride's main (last) video path.
  final String videoPath;

  /// Resolved form of each declared path (trimmed key).
  final Map<String, String> resolvedByDeclared;

  /// Declared form (as written in the JSON) of each resolved path.
  final Map<String, String> declaredByResolved;

  /// Resolved form of a declared path, or the path itself when it was not
  /// declared in the segment list.
  String resolve(String declaredPath) {
    final declared = declaredPath.trim();
    return resolvedByDeclared[declared] ?? declared;
  }

  /// Declared form (as written in the JSON) of a resolved path.
  String declaredPathFor(String resolvedPath) =>
      declaredByResolved[resolvedPath] ?? resolvedPath;

  /// The trusted segments as [checkRideIntegrity] expects them.
  List<RideIntegritySegment> get integritySegments {
    final missing = missingSegmentPaths.toSet();
    return <RideIntegritySegment>[
      for (final path in segmentPaths)
        RideIntegritySegment(
          resolvedPath: path,
          declaredPath: declaredPathFor(path),
          isMissing: missing.contains(path),
        ),
    ];
  }
}

/// Trusted roots come only from a location the app controls: the
/// directory the telemetry file was discovered in. Fields of the JSON being
/// checked (such as `storageDirectory` or `videoPath`) are never trusted,
/// and [legacyPublicRecordingsDirectory] is not a trusted root.
List<String> trustedRootsForTelemetryFile(File telemetryFile) {
  // No hard-coded public path: it differs for secondary users and work
  // profiles, and ride JSON never references exported gallery copies.
  final roots = <String>[telemetryFile.parent.path];

  final normalized = <String>{};
  for (final rawRoot in roots) {
    final candidate = rawRoot.trim();
    if (candidate.isEmpty) {
      continue;
    }
    normalized.add(path_utils.normalizePath(candidate));
  }
  return List<String>.unmodifiable(normalized.toList());
}

bool _isPathInsideAnyTrustedRoot(String filePath, List<String> trustedRoots) {
  for (final trustedRoot in trustedRoots) {
    if (path_utils.isPathInsideDirectory(filePath, trustedRoot)) {
      return true;
    }
  }
  return false;
}

/// Resolves the declared segment and video paths of [json] (read from
/// [telemetryFile]), applies the trusted-root check and records which files
/// are missing. Returns `null` when no video path can be determined.
///
/// Each declared path is mapped by [resolveDeclaredRidePath]. Paths outside
/// the telemetry file's directory are quarantined. When no trusted segment
/// remains, the sibling video of a legacy-named telemetry file is
/// recovered. An empty or quarantined `videoPath` is replaced by the last
/// existing segment (or the last trusted one), and `videoPath` is appended
/// to the segment list when it is missing.
Future<ResolvedRideSegments?> resolveRideSegments({
  required File telemetryFile,
  required Map<String, dynamic> json,
}) async {
  final telemetryDirectory = telemetryFile.parent.path;
  final trustedRoots = trustedRootsForTelemetryFile(telemetryFile);
  final resolvedByDeclared = <String, String>{};
  final declaredByResolved = <String, String>{};

  Future<String> resolve(String declaredPath) async {
    final declared = declaredPath.trim();
    final cached = resolvedByDeclared[declared];
    if (cached != null) {
      return cached;
    }
    final resolvedPath = await resolveDeclaredRidePath(
      declared,
      telemetryDirectory: telemetryDirectory,
    );
    resolvedByDeclared[declared] = resolvedPath;
    declaredByResolved.putIfAbsent(resolvedPath, () => declared);
    return resolvedPath;
  }

  final declaredVideoPath = json['videoPath']?.toString().trim() ?? '';
  final allowed = <String>[];
  final quarantined = <String>[];
  final seen = <String>{};

  void addQuarantined(String path) {
    if (!quarantined.contains(path)) {
      quarantined.add(path);
    }
  }

  final rawSegmentPaths = json['segmentPaths'];
  final declaredSegmentPaths = normalizeSegmentPathList(
    rawSegmentPaths is List ? rawSegmentPaths : const <Object?>[],
  );
  if (declaredSegmentPaths.isEmpty && declaredVideoPath.isNotEmpty) {
    declaredSegmentPaths.add(declaredVideoPath);
  }

  for (final declared in declaredSegmentPaths) {
    final path = await resolve(declared);
    if (path.isEmpty || !seen.add(path)) {
      continue;
    }
    if (_isPathInsideAnyTrustedRoot(path, trustedRoots)) {
      allowed.add(path);
    } else {
      addQuarantined(path);
      if (kDebugMode) {
        debugPrint(
          'RideRecord: quarantined out-of-scope segment path from ${telemetryFile.path} -> $path',
        );
      }
    }
  }

  var existing = await _existingPathsInOrder(allowed);

  if (allowed.isEmpty) {
    final recoveredPath = await _recoverVideoPathFromTelemetryFile(
      telemetryFile,
    );
    if (recoveredPath != null) {
      declaredByResolved.putIfAbsent(recoveredPath, () => recoveredPath);
      if (_isPathInsideAnyTrustedRoot(recoveredPath, trustedRoots)) {
        allowed.add(recoveredPath);
        existing = <String>[...existing, recoveredPath];
      } else {
        addQuarantined(recoveredPath);
      }
    }
  }

  var videoPath = declaredVideoPath.isEmpty
      ? ''
      : await resolve(declaredVideoPath);
  if (videoPath.isNotEmpty &&
      !_isPathInsideAnyTrustedRoot(videoPath, trustedRoots)) {
    addQuarantined(videoPath);
    videoPath = '';
  }

  if (videoPath.isEmpty) {
    if (existing.isNotEmpty) {
      videoPath = existing.last;
    } else if (allowed.isNotEmpty) {
      videoPath = allowed.last;
    }
  }

  if (videoPath.isEmpty) {
    return null;
  }
  if (!allowed.contains(videoPath)) {
    allowed.add(videoPath);
    if (await File(videoPath).exists()) {
      existing = <String>[...existing, videoPath];
    }
  }

  final existingSet = existing.toSet();
  return ResolvedRideSegments(
    segmentPaths: List<String>.unmodifiable(allowed),
    missingSegmentPaths: List<String>.unmodifiable(
      allowed.where((path) => !existingSet.contains(path)),
    ),
    quarantinedSegmentPaths: List<String>.unmodifiable(quarantined),
    videoPath: videoPath,
    resolvedByDeclared: Map<String, String>.unmodifiable(resolvedByDeclared),
    declaredByResolved: Map<String, String>.unmodifiable(declaredByResolved),
  );
}

/// Maps a declared path to the file to use:
///
/// * a plain file name (no separator) is resolved inside
///   [telemetryDirectory];
/// * an existing path is kept;
/// * a missing path whose file name exists inside [telemetryDirectory] is
///   relocated there (the data directory moved since recording);
/// * anything else is kept as declared.
Future<String> resolveDeclaredRidePath(
  String declaredPath, {
  required String telemetryDirectory,
}) async {
  final path = declaredPath.trim();
  if (path.isEmpty) {
    return path;
  }

  final name = path_utils.fileNameFromPath(path);
  if (name.isEmpty || name == '.' || name == '..') {
    return path;
  }

  final candidatePath = '$telemetryDirectory${Platform.pathSeparator}$name';
  if (name == path) {
    return candidatePath;
  }
  if (await File(path).exists()) {
    return path;
  }
  if (await File(candidatePath).exists()) {
    return candidatePath;
  }
  return path;
}

Future<List<String>> _existingPathsInOrder(Iterable<String> paths) async {
  final existingPaths = <String>[];
  final seen = <String>{};

  for (final path in paths) {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty || seen.contains(normalizedPath)) {
      continue;
    }
    if (await File(normalizedPath).exists()) {
      existingPaths.add(normalizedPath);
      seen.add(normalizedPath);
    }
  }

  return existingPaths;
}

Future<String?> _recoverVideoPathFromTelemetryFile(File telemetryFile) async {
  if (!telemetryFile.path.toLowerCase().endsWith(rideTelemetryFileSuffix)) {
    return null;
  }

  final basePath = telemetryFile.path.substring(
    0,
    telemetryFile.path.length - rideTelemetryFileSuffix.length,
  );

  for (final extension in rideVideoFileExtensions) {
    final candidate = File('$basePath$extension');
    if (await candidate.exists()) {
      return candidate.path;
    }
  }

  return null;
}

/// Reads `segmentTimeline` with [normalizeRideTimeline], mapping each
/// entry's declared path to its resolved segment path.
List<RideSegmentTimelineEntry> decodeRideTimeline(
  Map<String, dynamic> json, {
  required ResolvedRideSegments segments,
}) {
  return normalizeRideTimeline(
    json['segmentTimeline'],
    knownPaths: segments.segmentPaths.toSet(),
    resolvePath: segments.resolve,
  );
}

/// Reads `lockedSegmentPaths`: each entry mapped to its resolved segment
/// path and kept only when it is one of the ride's trusted segments; a
/// non-list counts as empty, and repeats are dropped.
List<String> decodeLockedSegmentPaths(
  Map<String, dynamic> json, {
  required ResolvedRideSegments segments,
}) {
  final raw = json['lockedSegmentPaths'];
  if (raw is! List || raw.isEmpty) {
    return const [];
  }

  final segmentSet = segments.segmentPaths.toSet();
  final locked = <String>[];
  for (final value in raw) {
    final path = segments.resolve(value.toString());
    if (path.isNotEmpty &&
        segmentSet.contains(path) &&
        !locked.contains(path)) {
      locked.add(path);
    }
  }
  return locked;
}

/// Checks the envelope of [json] for the trusted [segments] and then
/// applies the quarantine rule ([applyQuarantineToIntegrity]). Segment
/// files are hashed with [hashSegment] when [verifySegments] is `true`.
Future<RideIntegrityReport> checkRideFileIntegrity({
  required Map<String, dynamic> json,
  required ResolvedRideSegments segments,
  bool verifySegments = false,
  SegmentFileHasher hashSegment = hashSegmentFile,
}) async {
  return applyQuarantineToIntegrity(
    await checkRideIntegrity(
      json: json,
      schemaVersion: rideFileSchemaVersionOf(json),
      sessionComplete: readRideFileBool(
        json,
        'sessionComplete',
        defaultValue: true,
      ),
      segments: segments.integritySegments,
      verifySegments: verifySegments,
      hashSegment: hashSegment,
    ),
    segments.quarantinedSegmentPaths,
  );
}

/// The SHA-256 recorded in the envelope of [json] for each trusted segment
/// of [segments], keyed by resolved path ([expectedSegmentHashesOf]).
Map<String, String> expectedSegmentHashesFor(
  Map<String, dynamic> json, {
  required ResolvedRideSegments segments,
}) => expectedSegmentHashesOf(json, segments.integritySegments);

/// Everything a ride JSON says except its samples.
class DecodedRideFile {
  /// Creates a decoded ride. Prefer [decodeRideFile].
  const DecodedRideFile({
    required this.summary,
    required this.segments,
    required this.segmentTimeline,
    required this.lockedSegmentPaths,
    required this.integrity,
  });

  /// Summary fields.
  final RideFileSummary summary;

  /// Resolved, trusted, missing and quarantined segment paths.
  final ResolvedRideSegments segments;

  /// Normalised timeline of the trusted segments.
  final List<RideSegmentTimelineEntry> segmentTimeline;

  /// Locked trusted segments.
  final List<String> lockedSegmentPaths;

  /// Integrity report, quarantine applied.
  final RideIntegrityReport integrity;
}

/// Decodes [json] (read from [telemetryFile]) without its samples, or
/// returns `null` when it names no video. Throws on type errors that make
/// the file unreadable (see [decodeRideFileSummary] and
/// [normalizeRideTimeline]).
///
/// The payload hash is always checked; segment files are hashed only when
/// [verifySegments] is `true`.
Future<DecodedRideFile?> decodeRideFile({
  required File telemetryFile,
  required Map<String, dynamic> json,
  bool verifySegments = false,
}) async {
  final segments = await resolveRideSegments(
    telemetryFile: telemetryFile,
    json: json,
  );
  if (segments == null) {
    return null;
  }

  final segmentTimeline = decodeRideTimeline(json, segments: segments);
  final integrity = await checkRideFileIntegrity(
    json: json,
    segments: segments,
    verifySegments: verifySegments,
  );
  return DecodedRideFile(
    summary: decodeRideFileSummary(json),
    segments: segments,
    segmentTimeline: segmentTimeline,
    lockedSegmentPaths: decodeLockedSegmentPaths(json, segments: segments),
    integrity: integrity,
  );
}

/// Sets `lockedSegmentPaths` of [json] in place: every segment of the ride
/// in the form written in the file when [locked], or `[]` otherwise. Every
/// other key keeps its value and position. With [reseal] the envelope gets
/// a new payload hash ([resealIntegrityEnvelope]); callers pass it only for
/// a fully verified ride.
void applyLockState(
  Map<String, dynamic> json, {
  required ResolvedRideSegments segments,
  required bool locked,
  required bool reseal,
}) {
  json['lockedSegmentPaths'] = locked
      ? segments.segmentPaths.map(segments.declaredPathFor).toList()
      : <String>[];
  if (reseal) {
    resealIntegrityEnvelope(json);
  }
}

// ---------------------------------------------------------------------------
// Writing.
// ---------------------------------------------------------------------------

/// What the recorder knows about a ride's files when it saves: the paths as
/// `CameraProvider` reports them.
class RideFileInput {
  /// Creates a writer input.
  const RideFileInput({
    required this.videoPath,
    required this.segmentPaths,
    required this.lockedSegmentPaths,
    required this.segmentTimeline,
    required this.recordingSettings,
  });

  /// The last (main) segment.
  final String videoPath;

  /// Session segments in recording order.
  final List<String> segmentPaths;

  /// Locked segments.
  final List<String> lockedSegmentPaths;

  /// `SegmentTimelineEntry.toJson` maps (`path`, `startMs`, `endMs`).
  final List<Map<String, dynamic>> segmentTimeline;

  /// Requested and applied capture settings.
  final Map<String, dynamic> recordingSettings;
}

/// The file-related part of a ride JSON as the writer stores it.
class RideFileContent {
  /// Creates writer content. Prefer [resolveRideFileContent].
  const RideFileContent({
    required this.videoPath,
    required this.storageDirectory,
    required this.segmentPaths,
    required this.lockedSegmentPaths,
    required this.segmentTimeline,
    required this.recordingSettings,
  });

  /// `videoPath`, trimmed.
  final String videoPath;

  /// `storageDirectory`: the parent of [videoPath], or `''`.
  final String storageDirectory;

  /// `segmentPaths`.
  final List<String> segmentPaths;

  /// `lockedSegmentPaths`.
  final List<String> lockedSegmentPaths;

  /// `segmentTimeline`.
  final List<RideSegmentTimelineEntry> segmentTimeline;

  /// `recordingSettings`.
  final Map<String, dynamic> recordingSettings;

  /// Returns a copy that keeps only the segments in [keep]; the video path
  /// falls back to the last kept segment.
  RideFileContent restrictedTo(Set<String> keep) {
    final segments = segmentPaths.where(keep.contains).toList();
    return RideFileContent(
      videoPath: keep.contains(videoPath)
          ? videoPath
          : (segments.isEmpty ? '' : segments.last),
      storageDirectory: storageDirectory,
      segmentPaths: segments,
      lockedSegmentPaths: lockedSegmentPaths.where(keep.contains).toList(),
      segmentTimeline: segmentTimeline
          .where((entry) => keep.contains(entry.path))
          .toList(),
      recordingSettings: recordingSettings,
    );
  }
}

/// Applies the writer's rules to [input]:
///
/// * the segment list follows [normalizeSegmentPathList] (with `videoPath`);
/// * only paths inside the parent directory of `videoPath` (when it is
///   non-empty) and only files that exist are kept; if none remain and the
///   video file exists, the list is `[videoPath]`;
/// * locked paths are trimmed, de-duplicated and restricted to the kept
///   segments;
/// * the timeline follows [normalizeRideTimeline] for the kept segments;
/// * recording settings get trimmed, non-empty keys and primitive values
///   (anything else becomes its `toString()`).
Future<RideFileContent> resolveRideFileContent(RideFileInput input) async {
  final canonicalVideoPath = input.videoPath.trim();
  final storageDirectory = canonicalVideoPath.isEmpty
      ? ''
      : File(canonicalVideoPath).parent.path;
  final normalizedSegmentPaths = normalizeSegmentPathList(
    input.segmentPaths,
    videoPath: canonicalVideoPath,
  );
  final insideDirectory = storageDirectory.trim().isEmpty
      ? normalizedSegmentPaths
      : <String>[
          for (final path in normalizedSegmentPaths)
            if (path_utils.isPathInsideDirectory(path, storageDirectory)) path,
        ];
  final segmentPaths = <String>[];
  for (final path in insideDirectory) {
    if (await File(path).exists()) {
      segmentPaths.add(path);
    } else {
      debugPrint('Telemetry: dropping missing segment path $path');
    }
  }
  if (segmentPaths.isEmpty && canonicalVideoPath.isNotEmpty) {
    if (await File(canonicalVideoPath).exists()) {
      segmentPaths.add(canonicalVideoPath);
    }
  }

  final knownPaths = segmentPaths.toSet();
  return RideFileContent(
    videoPath: canonicalVideoPath,
    storageDirectory: storageDirectory,
    segmentPaths: segmentPaths,
    lockedSegmentPaths: <String>[
      for (final path in normalizeSegmentPathList(input.lockedSegmentPaths))
        if (knownPaths.contains(path)) path,
    ],
    segmentTimeline: normalizeRideTimeline(
      input.segmentTimeline,
      knownPaths: knownPaths,
      resolvePath: (path) => path.trim(),
    ),
    recordingSettings: _normalizeRecordingSettings(input.recordingSettings),
  );
}

Map<String, dynamic> _normalizeRecordingSettings(
  Map<String, dynamic> settings,
) {
  final normalized = <String, dynamic>{};
  for (final entry in settings.entries) {
    final key = entry.key.trim();
    if (key.isEmpty) {
      continue;
    }

    final value = entry.value;
    if (value == null || value is num || value is bool || value is String) {
      normalized[key] = value;
      continue;
    }

    normalized[key] = value.toString();
  }
  return normalized;
}

/// The ride-level values the writer stores next to the file content.
class RideFileSnapshot {
  /// Creates a snapshot of an active or just-stopped ride.
  const RideFileSnapshot({
    required this.sessionId,
    required this.startedAt,
    required this.endedAt,
    required this.samples,
    required this.incidents,
    required this.distanceKm,
    required this.maxSpeedKmh,
    required this.averageSpeedKmh,
    required this.mockLocationDetected,
  });

  /// `rideSessionId`.
  final String sessionId;

  /// Ride start (written as UTC ISO 8601).
  final DateTime startedAt;

  /// Ride end, or the checkpoint time (written as UTC ISO 8601).
  final DateTime endedAt;

  /// `TelemetryData.toJson` maps in capture order.
  final List<Map<String, dynamic>> samples;

  /// Incident maps in detection order.
  final List<Map<String, dynamic>> incidents;

  /// Cumulative distance in km.
  final double distanceKm;

  /// Maximum speed of samples with a fix, km/h.
  final double maxSpeedKmh;

  /// Mean speed of samples with a fix, km/h.
  final double averageSpeedKmh;

  /// Whether any fix came from a mock location provider.
  final bool mockLocationDetected;
}

/// Builds the unsealed ride JSON in the documented key order, with every
/// non-finite double replaced by `null` ([sanitizeJsonValue]).
Map<String, dynamic> encodeRidePayload({
  required RideFileSnapshot ride,
  required RideFileContent files,
  required bool sessionComplete,
  required int sampleRateMs,
}) {
  final payload = <String, dynamic>{
    'schemaVersion': rideFileSchemaVersion,
    'rideSessionId': ride.sessionId,
    'sessionComplete': sessionComplete,
    'storagePolicy': rideFileStoragePolicy,
    'publicExportRelativePath': publicExportRelativePath,
    'storageDirectory': files.storageDirectory,
    'sampleRateMs': sampleRateMs,
    'videoPath': files.videoPath,
    'videoFileName': path_utils.fileNameFromPath(files.videoPath),
    'segmentPaths': files.segmentPaths,
    'lockedSegmentPaths': files.lockedSegmentPaths,
    'segmentTimeline': <Map<String, dynamic>>[
      for (final entry in files.segmentTimeline) entry.toJson(),
    ],
    'recordingSettings': files.recordingSettings,
    'startedAt': ride.startedAt.toUtc().toIso8601String(),
    'endedAt': ride.endedAt.toUtc().toIso8601String(),
    'distanceKm': ride.distanceKm,
    'maxSpeedKmh': ride.maxSpeedKmh,
    'averageSpeedKmh': ride.averageSpeedKmh,
    'mockLocationDetected': ride.mockLocationDetected,
    'incidents': ride.incidents,
    'samples': ride.samples,
  };
  return sanitizeJsonValue(payload) as Map<String, dynamic>;
}

/// Returns a copy of [value] in which every non-finite double (NaN or
/// infinity, which `jsonEncode` rejects) is replaced by `null`.
Object? sanitizeJsonValue(Object? value) {
  if (value is double) {
    return value.isFinite ? value : null;
  }
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): sanitizeJsonValue(entry.value),
    };
  }
  if (value is List) {
    return [for (final item in value) sanitizeJsonValue(item)];
  }
  return value;
}

/// Returns [payload] with a bound integrity envelope
/// ([buildIntegrityEnvelope]) under `integrity`. The envelope is built in a
/// background isolate; only [payload], [segmentHashes] and the counts cross
/// the isolate boundary.
Future<Map<String, dynamic>> sealRidePayload(
  Map<String, dynamic> payload, {
  required Map<String, String> segmentHashes,
  required int segmentCount,
  required DateTime generatedAt,
}) async {
  final envelope = await Isolate.run(
    () => buildIntegrityEnvelope(
      payload: payload,
      segmentHashes: segmentHashes,
      segmentCount: segmentCount,
      generatedAt: generatedAt,
    ),
  );
  return <String, dynamic>{...payload, 'integrity': envelope};
}

/// The file content of a ride JSON map: compact `jsonEncode`.
String encodeRideFileJson(Map<String, dynamic> json) => jsonEncode(json);

/// The telemetry file path of a ride: `ride_<rideSessionId>.telemetry.json`
/// (every character outside `[a-zA-Z0-9_-]` replaced by `_`) in the parent
/// directory of the first of [segmentPaths], else of [videoPath], else a
/// bare file name.
String rideTelemetryPathFor({
  required String rideSessionId,
  required String videoPath,
  required List<String> segmentPaths,
}) {
  String? directoryPath;
  if (segmentPaths.isNotEmpty) {
    directoryPath = File(segmentPaths.first).parent.path;
  } else if (videoPath.isNotEmpty) {
    directoryPath = File(videoPath).parent.path;
  }

  final safeSessionId = rideSessionId.replaceAll(
    RegExp(r'[^a-zA-Z0-9_-]'),
    '_',
  );
  final fileName = 'ride_$safeSessionId$rideTelemetryFileSuffix';

  if (directoryPath == null || directoryPath.isEmpty) {
    return fileName;
  }
  return '$directoryPath${Platform.pathSeparator}$fileName';
}
