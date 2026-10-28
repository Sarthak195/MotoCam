import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/utils/integrity_utils.dart' as integrity_utils;
import '../../../core/utils/path_utils.dart' as path_utils;
import '../../telemetry/models/telemetry_data.dart';

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

/// Represents a persisted ride session loaded from a telemetry JSON file.
///
/// A ride record holds references to video segments, GPS/telemetry samples,
/// integrity verification results, and summary statistics (distance, speed).
/// It is the primary data model consumed by the ride history and playback
/// screens.
///
/// Segment paths are resolved against the directory that holds the
/// telemetry file: a declared absolute path that no longer exists (for
/// example after the iOS data-container path changed) is replaced by the
/// same file name in that directory when such a file exists. Only that
/// directory is trusted; declared paths outside it are quarantined.
class RideRecord {
  /// Creates a ride record. Prefer [fromTelemetryFile] or [fromVideoFile].
  RideRecord({
    required this.videoPath,
    required this.segmentPaths,
    required this.lockedSegmentPaths,
    required this.createdAt,
    required this.telemetryPath,
    required this.rideSessionId,
    required this.isSessionComplete,
    required this.distanceKm,
    required this.maxSpeedKmh,
    required this.averageSpeedKmh,
    required this.segmentTimeline,
    required this.samples,
    required this.integrity,
    required this.quarantinedSegmentPaths,
    this.missingSegmentPaths = const <String>[],
    this.incidents,
    this.mockLocationDetected = false,
  });

  /// Lower-case file extensions treated as ride video files.
  static const List<String> videoFileExtensions = <String>[
    '.mp4',
    '.mov',
    '.mkv',
    '.avi',
  ];

  /// Returns `true` when [path] ends with one of [videoFileExtensions].
  static bool isVideoFilePath(String path) {
    final lower = path.trim().toLowerCase();
    return videoFileExtensions.any(lower.endsWith);
  }

  /// Path of the ride's main (last) video segment.
  final String videoPath;

  /// Trusted segment paths in recording order, resolved against the
  /// telemetry file's directory. May include files that no longer exist;
  /// those are also listed in [missingSegmentPaths].
  final List<String> segmentPaths;

  /// Locked segments (manual LOCK or automatic incident locks); a subset of
  /// [segmentPaths].
  final List<String> lockedSegmentPaths;

  /// Ride start time in local time, or the file modification time when
  /// unknown.
  final DateTime createdAt;

  /// Path of the ride JSON, or `null` for a video-only (recovered) ride.
  final String? telemetryPath;

  /// Session identifier written by the recorder, if any.
  final String? rideSessionId;

  /// Whether the recorder marked the session as complete.
  final bool isSessionComplete;

  /// Total ride distance in kilometres.
  final double distanceKm;

  /// Maximum speed in km/h.
  final double maxSpeedKmh;

  /// Average speed in km/h.
  final double averageSpeedKmh;

  /// Start/end offsets of each segment within the ride, sorted by start.
  final List<RideSegmentTimelineEntry> segmentTimeline;

  /// Telemetry samples in file order (the recorder writes them by elapsed
  /// time); malformed entries are skipped.
  final List<TelemetryData> samples;

  /// Result of the most recent integrity check.
  final RideIntegrityReport integrity;

  /// Declared segment paths rejected because they lie outside the
  /// directory that holds the telemetry file.
  final List<String> quarantinedSegmentPaths;

  /// Entries of [segmentPaths] whose files no longer exist. A missing file
  /// makes the ride incomplete; on its own it is not an integrity failure.
  final List<String> missingSegmentPaths;

  /// Incidents detected live during the ride, from the optional top-level
  /// `incidents` list, or `null` for files written before that key existed
  /// (playback then derives markers from the samples).
  final List<RideIncident>? incidents;

  /// Whether the recorder saw a mock (simulated) location provider during
  /// the ride (optional top-level `mockLocationDetected`, default `false`).
  final bool mockLocationDetected;

  /// File name of [videoPath].
  String get fileName => path_utils.fileNameFromPath(videoPath);

  /// Whether any segment of the ride is locked.
  bool get isLocked => lockedSegmentPaths.isNotEmpty;

  /// Whether any declared segment path was quarantined.
  bool get hasQuarantinedSegments => quarantinedSegmentPaths.isNotEmpty;

  /// Whether any declared segment file no longer exists.
  bool get hasMissingSegments => missingSegmentPaths.isNotEmpty;

  /// Number of [segmentPaths] whose files still exist.
  int get availableSegmentCount =>
      segmentPaths.where((path) => !missingSegmentPaths.contains(path)).length;

  /// Ride duration taken from the last sample's elapsed time.
  Duration get duration {
    if (samples.isEmpty) {
      return Duration.zero;
    }
    return Duration(milliseconds: samples.last.elapsedMs);
  }

  /// Returns the telemetry at [position], linearly interpolated between the
  /// two nearest samples and clamped to the first and last sample.
  ///
  /// Position is never interpolated across a sample without a GPS fix: when
  /// either neighbour has `hasFix == false`, the neighbour with a fix
  /// supplies latitude, longitude and bearing (or the nearest sample is
  /// returned when neither has a fix). Bearing is interpolated along the
  /// shortest arc (see [interpolateBearing]).
  TelemetryData sampleForPosition(Duration position) {
    if (samples.isEmpty) {
      return TelemetryData.empty();
    }

    final targetMs = position.inMilliseconds;
    if (targetMs <= samples.first.elapsedMs) {
      return samples.first;
    }
    if (targetMs >= samples.last.elapsedMs) {
      return samples.last;
    }

    var low = 0;
    var high = samples.length - 1;

    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final sample = samples[mid];
      if (sample.elapsedMs == targetMs) {
        return sample;
      }
      if (sample.elapsedMs < targetMs) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }

    final upperIndex = low.clamp(1, samples.length - 1);
    final lowerIndex = (upperIndex - 1).clamp(0, samples.length - 1);
    final lower = samples[lowerIndex];
    final upper = samples[upperIndex];

    final spanMs = (upper.elapsedMs - lower.elapsedMs).abs();
    if (spanMs == 0) {
      return lower;
    }

    final t = ((targetMs - lower.elapsedMs) / spanMs).clamp(0.0, 1.0);
    final timestamp = lower.timestamp.add(
      Duration(milliseconds: targetMs - lower.elapsedMs),
    );

    if (!lower.hasFix || !upper.hasFix) {
      final nearest = t < 0.5 ? lower : upper;
      final TelemetryData? fixed = lower.hasFix
          ? lower
          : (upper.hasFix ? upper : null);
      if (fixed == null) {
        return nearest;
      }
      return TelemetryData(
        latitude: fixed.latitude,
        longitude: fixed.longitude,
        speed: fixed.speed,
        bearing: fixed.bearing,
        accelerationG: _lerp(lower.accelerationG, upper.accelerationG, t),
        elapsedMs: targetMs,
        distanceKm: _lerp(lower.distanceKm, upper.distanceKm, t),
        timestamp: timestamp,
        hasFix: true,
        fixAgeMs: fixed.fixAgeMs,
      );
    }

    return TelemetryData(
      latitude: _lerp(lower.latitude, upper.latitude, t),
      longitude: _lerp(lower.longitude, upper.longitude, t),
      speed: _lerp(lower.speed, upper.speed, t),
      bearing: interpolateBearing(lower.bearing, upper.bearing, t),
      accelerationG: _lerp(lower.accelerationG, upper.accelerationG, t),
      elapsedMs: targetMs,
      distanceKm: _lerp(lower.distanceKm, upper.distanceKm, t),
      timestamp: timestamp,
    );
  }

  /// Interpolates between bearings [a] and [b] (degrees) along the shortest
  /// arc, returning a value in `[0, 360)`. A negative bearing means
  /// "unavailable": the other value is returned instead (or `-1` when both
  /// are unavailable).
  static double interpolateBearing(double a, double b, double t) {
    final aValid = a.isFinite && a >= 0;
    final bValid = b.isFinite && b >= 0;
    if (!aValid && !bValid) {
      return -1;
    }
    if (!aValid) {
      return b % 360;
    }
    if (!bValid) {
      return a % 360;
    }
    var delta = (b - a) % 360; // [0, 360)
    if (delta > 180) {
      delta -= 360; // (-180, 180]
    }
    final result = (a + delta * t) % 360;
    return result < 0 ? result + 360 : result;
  }

  static double _lerp(double a, double b, double t) => a + ((b - a) * t);

  /// Builds a ride for a video file that no ride JSON references.
  ///
  /// If a `<video name>.telemetry.json` file sits next to the video and
  /// references it, the ride is loaded from it. Otherwise a video-only ride
  /// is returned with no telemetry, [RideIntegrityStatus.unknown] and
  /// [telemetryPath] `null` (so a sibling JSON that describes other
  /// segments is not listed a second time in place of this video).
  static Future<RideRecord> fromVideoFile(
    File videoFile, {
    bool verifySegments = false,
  }) async {
    final telemetryFile = File(_telemetryPathForVideo(videoFile.path));
    if (await telemetryFile.exists()) {
      final ride = await fromTelemetryFile(
        telemetryFile,
        verifySegments: verifySegments,
      );
      final videoKey = path_utils.normalizePath(videoFile.path);
      if (ride != null &&
          <String>[
            ride.videoPath,
            ...ride.segmentPaths,
          ].any((path) => path_utils.normalizePath(path) == videoKey)) {
        return ride;
      }
    }

    return RideRecord(
      videoPath: videoFile.path,
      segmentPaths: <String>[videoFile.path],
      lockedSegmentPaths: const <String>[],
      createdAt: (await videoFile.stat()).modified,
      telemetryPath: null,
      rideSessionId: null,
      isSessionComplete: true,
      distanceKm: 0,
      maxSpeedKmh: 0,
      averageSpeedKmh: 0,
      segmentTimeline: const <RideSegmentTimelineEntry>[],
      samples: const <TelemetryData>[],
      integrity: const RideIntegrityReport.unknown(),
      quarantinedSegmentPaths: const <String>[],
    );
  }

  /// Loads a ride from its telemetry JSON, or returns `null` when the file
  /// is missing, unreadable, malformed or names no video.
  ///
  /// The payload hash is always checked. Segment files are hashed only when
  /// [verifySegments] is `true` (see [verifySegmentIntegrity]).
  static Future<RideRecord?> fromTelemetryFile(
    File telemetryFile, {
    bool verifySegments = false,
  }) async {
    if (!await telemetryFile.exists()) {
      return null;
    }

    try {
      final json = await _readJsonMap(telemetryFile);
      if (json == null) {
        return null;
      }

      final resolved = await _resolveSegments(
        telemetryFile: telemetryFile,
        json: json,
      );
      if (resolved == null) {
        return null;
      }

      final samples = _readSamples(json);
      final segmentTimeline = _readSegmentTimeline(json, resolved: resolved);
      final integrity = _applyTrustToIntegrity(
        await _verifyIntegrity(
          json: json,
          resolved: resolved,
          verifySegments: verifySegments,
        ),
        resolved.quarantinedSegmentPaths,
      );

      return RideRecord(
        videoPath: resolved.videoPath,
        segmentPaths: resolved.segmentPaths,
        lockedSegmentPaths: _readLockedSegmentPaths(json, resolved: resolved),
        // New files store UTC ('Z'); show local wall-clock time. Offset-less
        // old files already parse as local.
        createdAt:
            DateTime.tryParse(json['startedAt']?.toString() ?? '')?.toLocal() ??
            (await telemetryFile.stat()).modified,
        telemetryPath: telemetryFile.path,
        rideSessionId: _readOptionalString(json, 'rideSessionId'),
        isSessionComplete: _readJsonBool(
          json,
          'sessionComplete',
          defaultValue: true,
        ),
        distanceKm: _readJsonDouble(json, 'distanceKm'),
        maxSpeedKmh: _readJsonDouble(json, 'maxSpeedKmh'),
        averageSpeedKmh: _readJsonDouble(json, 'averageSpeedKmh'),
        segmentTimeline: segmentTimeline,
        samples: samples,
        integrity: integrity,
        quarantinedSegmentPaths: resolved.quarantinedSegmentPaths,
        missingSegmentPaths: resolved.missingSegmentPaths,
        incidents: _readIncidents(json),
        mockLocationDetected: _readJsonBool(
          json,
          'mockLocationDetected',
          defaultValue: false,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _readJsonMap(File telemetryFile) async {
    final decoded = jsonDecode(await telemetryFile.readAsString());
    if (decoded is! Map) {
      return null;
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  static RideIntegrityReport _applyTrustToIntegrity(
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

  /// Resolves the declared segment and video paths of [json], applies the
  /// trusted-root check and records which files are missing. Returns `null`
  /// when no video path can be determined.
  static Future<_ResolvedSegments?> _resolveSegments({
    required File telemetryFile,
    required Map<String, dynamic> json,
  }) async {
    final telemetryDirectory = telemetryFile.parent.path;
    final trustedRoots = _trustedRootsForTelemetry(telemetryFile);
    final resolvedByDeclared = <String, String>{};
    final declaredByResolved = <String, String>{};

    Future<String> resolve(String declaredPath) async {
      final declared = declaredPath.trim();
      final cached = resolvedByDeclared[declared];
      if (cached != null) {
        return cached;
      }
      final resolvedPath = await _resolveDeclaredPath(
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

    for (final declared in _readSegmentPaths(
      json,
      fallbackPath: declaredVideoPath,
    )) {
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
    return _ResolvedSegments(
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
  static Future<String> _resolveDeclaredPath(
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

  static Future<List<String>> _existingPathsInOrder(
    Iterable<String> paths,
  ) async {
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

  static Future<String?> _recoverVideoPathFromTelemetryFile(
    File telemetryFile,
  ) async {
    const telemetrySuffix = '.telemetry.json';
    if (!telemetryFile.path.toLowerCase().endsWith(telemetrySuffix)) {
      return null;
    }

    final basePath = telemetryFile.path.substring(
      0,
      telemetryFile.path.length - telemetrySuffix.length,
    );

    for (final extension in videoFileExtensions) {
      final candidate = File('$basePath$extension');
      if (await candidate.exists()) {
        return candidate.path;
      }
    }

    return null;
  }

  static double _readJsonDouble(Map<String, dynamic> json, String key) =>
      (json[key] as num?)?.toDouble() ?? 0;

  static bool _readJsonBool(
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

  static List<RideIncident>? _readIncidents(Map<String, dynamic> json) {
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

  static String? _readOptionalString(Map<String, dynamic> json, String key) {
    final raw = json[key]?.toString().trim();
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return raw;
  }

  static List<String> _readSegmentPaths(
    Map<String, dynamic> json, {
    required String fallbackPath,
  }) {
    final raw = json['segmentPaths'];
    final paths = <String>[];
    final seen = <String>{};
    for (final value in raw is List ? raw : const <dynamic>[]) {
      final path = value.toString().trim();
      if (path.isEmpty || !seen.add(path)) {
        continue;
      }
      paths.add(path);
    }

    if (paths.isEmpty) {
      final fallback = fallbackPath.trim();
      if (fallback.isNotEmpty) {
        paths.add(fallback);
      }
    }
    return paths;
  }

  /// Trusted roots come only from a location the app controls: the
  /// directory the telemetry file was discovered in. Fields of the JSON
  /// being checked (such as `storageDirectory` or `videoPath`) are never
  /// trusted.
  static List<String> _trustedRootsForTelemetry(File telemetryFile) {
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

  static bool _isPathInsideAnyTrustedRoot(
    String filePath,
    List<String> trustedRoots,
  ) {
    for (final trustedRoot in trustedRoots) {
      if (path_utils.isPathInsideDirectory(filePath, trustedRoot)) {
        return true;
      }
    }
    return false;
  }

  static List<TelemetryData> _readSamples(Map<String, dynamic> json) {
    final samplesJson = json['samples'];
    final samples = <TelemetryData>[];
    if (samplesJson is! List) {
      return samples;
    }

    for (final raw in samplesJson.whereType<Map>()) {
      try {
        final normalized = raw.map(
          (key, value) => MapEntry(key.toString(), value),
        );
        samples.add(TelemetryData.fromJson(normalized));
      } catch (_) {
        // Keep loading the ride even if a single sample is malformed.
      }
    }

    return samples;
  }

  /// Reads `segmentTimeline`, maps each entry's declared path to its
  /// resolved segment path, drops entries for unknown or repeated segments,
  /// clamps negative starts to 0 (as the writer does) and sorts by start.
  static List<RideSegmentTimelineEntry> _readSegmentTimeline(
    Map<String, dynamic> json, {
    required _ResolvedSegments resolved,
  }) {
    final pathSet = resolved.segmentPaths.toSet();
    final rawTimeline = json['segmentTimeline'];
    final entries = <RideSegmentTimelineEntry>[];
    final seenPaths = <String>{};
    if (rawTimeline is! List) {
      return entries;
    }

    for (final rawEntry in rawTimeline.whereType<Map>()) {
      final entry = rawEntry.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      final path = resolved.resolve(entry['path']?.toString() ?? '');
      if (path.isEmpty || !pathSet.contains(path) || seenPaths.contains(path)) {
        continue;
      }

      final rawStartMs = (entry['startMs'] as num?)?.toInt() ?? 0;
      final startMs = rawStartMs < 0 ? 0 : rawStartMs;
      final endMs = (entry['endMs'] as num?)?.toInt() ?? startMs;
      final normalizedEndMs = endMs >= startMs ? endMs : startMs;
      entries.add(
        RideSegmentTimelineEntry(
          path: path,
          startMs: startMs,
          endMs: normalizedEndMs,
        ),
      );
      seenPaths.add(path);
    }

    entries.sort((a, b) => a.startMs.compareTo(b.startMs));
    return entries;
  }

  static List<String> _readLockedSegmentPaths(
    Map<String, dynamic> json, {
    required _ResolvedSegments resolved,
  }) {
    final raw = json['lockedSegmentPaths'];
    if (raw is! List || raw.isEmpty) {
      return const [];
    }

    final segmentSet = resolved.segmentPaths.toSet();
    final locked = <String>[];
    for (final value in raw) {
      final path = resolved.resolve(value.toString());
      if (path.isNotEmpty &&
          segmentSet.contains(path) &&
          !locked.contains(path)) {
        locked.add(path);
      }
    }
    return locked;
  }

  /// Locks ([locked] `true`) or unlocks every segment of this ride in its
  /// telemetry JSON, and returns whether the change was saved.
  ///
  /// The ride is re-read and fully re-verified, including segment hashes,
  /// first. The change is refused when any check fails or a path is
  /// quarantined. For a verified ride the existing segment hashes are kept
  /// and only the payload hash is recomputed; a legacy ride without an
  /// envelope is updated without creating one, so it stays unverified.
  Future<bool> setLockState(bool locked) async {
    if (integrity.status == RideIntegrityStatus.modified ||
        hasQuarantinedSegments) {
      return false;
    }

    final path = telemetryPath;
    if (path == null) {
      return false;
    }

    return integrity_utils.runExclusiveForPath<bool>(path, () async {
      try {
        final telemetryFile = File(path);
        if (!await telemetryFile.exists()) {
          return false;
        }

        final json = await _readJsonMap(telemetryFile);
        if (json == null) {
          return false;
        }

        final resolved = await _resolveSegments(
          telemetryFile: telemetryFile,
          json: json,
        );
        if (resolved == null || resolved.quarantinedSegmentPaths.isNotEmpty) {
          return false;
        }

        final report = await _verifyIntegrity(
          json: json,
          resolved: resolved,
          verifySegments: true,
        );
        if (report.status == RideIntegrityStatus.modified) {
          return false;
        }

        json['lockedSegmentPaths'] = locked
            ? resolved.segmentPaths.map(resolved.declaredPathFor).toList()
            : <String>[];

        if (report.status == RideIntegrityStatus.verified) {
          integrity_utils.resealIntegrityEnvelope(json);
        }

        await integrity_utils.writeTelemetryAtomically(
          telemetryFile: telemetryFile,
          content: jsonEncode(json),
        );
        return true;
      } catch (_) {
        return false;
      }
    });
  }

  static int _readSchemaVersion(Map<String, dynamic> json) {
    final raw = json['schemaVersion'];
    if (raw is num) {
      return raw.toInt();
    }
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  /// Checks the integrity envelope of [json].
  ///
  /// Fails closed: an invalid envelope, or a missing one on a completed
  /// ride whose `schemaVersion` makes it mandatory, is reported as modified.
  /// A declared segment that exists but has no hash is an issue; a segment
  /// whose file is missing is not (it is reported through
  /// `missingSegmentPaths`).
  static Future<RideIntegrityReport> _verifyIntegrity({
    required Map<String, dynamic> json,
    required _ResolvedSegments resolved,
    bool verifySegments = false,
  }) async {
    final schemaVersion = _readSchemaVersion(json);
    final rawIntegrity = json['integrity'];
    if (rawIntegrity == null) {
      // Only a completed ride must carry an envelope. An incomplete one
      // (sessionComplete: false) without it is reported as unknown, not
      // modified; this app seals its checkpoints, so it never writes one.
      final isSealedSchema =
          schemaVersion >= integrity_utils.mandatoryIntegritySchemaVersion;
      if (isSealedSchema &&
          _readJsonBool(json, 'sessionComplete', defaultValue: true)) {
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

    final algorithm =
        (integrity['algo']?.toString().trim().toLowerCase() ?? '');
    if (algorithm != integrity_utils.integrityAlgorithmSha256) {
      issues.add('unsupported-integrity-algorithm:$algorithm');
    }

    final rawEnvelopeVersion = integrity['envelopeVersion'];
    final envelopeVersion = integrity_utils.integrityEnvelopeVersionOf(
      integrity,
    );
    if (rawEnvelopeVersion != null &&
        (rawEnvelopeVersion is! num ||
            envelopeVersion < 1 ||
            envelopeVersion > integrity_utils.boundIntegrityEnvelopeVersion)) {
      issues.add('unsupported-integrity-version:$rawEnvelopeVersion');
    }

    final expectedPayloadHash =
        integrity['payloadHash']?.toString().trim().toLowerCase() ?? '';
    if (expectedPayloadHash.isEmpty) {
      issues.add('missing-payload-hash');
    } else {
      final actualPayloadHash = integrity_utils.computeRidePayloadHash(json);
      if (actualPayloadHash != expectedPayloadHash) {
        issues.add('payload-hash-mismatch');
      }
    }

    final expectedSegmentHashes = _readExpectedSegmentHashes(integrity);
    final missingPaths = resolved.missingSegmentPaths.toSet();
    final matchedHashKeys = <String>{};
    for (final segmentPath in resolved.segmentPaths) {
      final hashKey = _segmentHashKey(
        expectedSegmentHashes,
        declaredPath: resolved.declaredPathFor(segmentPath),
        resolvedPath: segmentPath,
      );
      if (hashKey == null) {
        if (!missingPaths.contains(segmentPath)) {
          issues.add('missing-segment-hash:$segmentPath');
        }
        continue;
      }
      matchedHashKeys.add(hashKey);

      if (!verifySegments || missingPaths.contains(segmentPath)) {
        continue;
      }

      final actualHash = await integrity_utils.hashFileSha256(segmentPath);
      if (actualHash == null) {
        if (await File(segmentPath).exists()) {
          issues.add('unreadable-segment-file:$segmentPath');
        }
        continue;
      }

      if (actualHash != expectedSegmentHashes[hashKey]) {
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

  /// Finds the `segmentHashes` key for a segment: its declared path, its
  /// resolved path, or its plain file name (for writers that store names
  /// relative to the recordings directory).
  static String? _segmentHashKey(
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

  /// Re-reads the telemetry JSON and returns a copy of this ride whose
  /// [integrity] also covers the SHA-256 of every existing segment file.
  ///
  /// Returns this ride unchanged when it has no telemetry file or the file
  /// cannot be read. Hashing can take a long time for long rides.
  Future<RideRecord> verifySegmentIntegrity() async {
    if (telemetryPath == null) {
      return this;
    }
    final telemetryFile = File(telemetryPath!);
    if (!await telemetryFile.exists()) {
      return this;
    }

    try {
      final json = await _readJsonMap(telemetryFile);
      if (json == null) {
        return this;
      }

      final resolved = await _resolveSegments(
        telemetryFile: telemetryFile,
        json: json,
      );
      if (resolved == null) {
        return this;
      }

      final integrity = _applyTrustToIntegrity(
        await _verifyIntegrity(
          json: json,
          resolved: resolved,
          verifySegments: true,
        ),
        resolved.quarantinedSegmentPaths,
      );

      return RideRecord(
        videoPath: videoPath,
        segmentPaths: segmentPaths,
        lockedSegmentPaths: lockedSegmentPaths,
        createdAt: createdAt,
        telemetryPath: telemetryPath,
        rideSessionId: rideSessionId,
        isSessionComplete: isSessionComplete,
        distanceKm: distanceKm,
        maxSpeedKmh: maxSpeedKmh,
        averageSpeedKmh: averageSpeedKmh,
        segmentTimeline: segmentTimeline,
        samples: samples,
        integrity: integrity,
        quarantinedSegmentPaths: resolved.quarantinedSegmentPaths,
        missingSegmentPaths: resolved.missingSegmentPaths,
        incidents: incidents,
        mockLocationDetected: mockLocationDetected,
      );
    } catch (_) {
      return this;
    }
  }

  static Map<String, String> _readExpectedSegmentHashes(
    Map<String, dynamic> integrity,
  ) {
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

  static String _telemetryPathForVideo(String videoPath) {
    final dotIndex = videoPath.lastIndexOf('.');
    if (dotIndex <= 0) {
      return '$videoPath.telemetry.json';
    }
    return '${videoPath.substring(0, dotIndex)}.telemetry.json';
  }
}

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
}

class _ResolvedSegments {
  const _ResolvedSegments({
    required this.segmentPaths,
    required this.missingSegmentPaths,
    required this.quarantinedSegmentPaths,
    required this.videoPath,
    required this.resolvedByDeclared,
    required this.declaredByResolved,
  });

  final List<String> segmentPaths;
  final List<String> missingSegmentPaths;
  final List<String> quarantinedSegmentPaths;
  final String videoPath;
  final Map<String, String> resolvedByDeclared;
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
}
