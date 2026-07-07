import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/utils/integrity_utils.dart' as integrity_utils;
import '../../../core/utils/path_utils.dart' as path_utils;
import '../../telemetry/models/telemetry_data.dart';

enum RideIntegrityStatus { unknown, verified, modified }

class RideIntegrityReport {
  const RideIntegrityReport._({
    required this.status,
    required this.hasMetadata,
    required this.issues,
  });

  const RideIntegrityReport.unknown()
      : status = RideIntegrityStatus.unknown,
        hasMetadata = false,
        issues = const <String>[];

  const RideIntegrityReport.verified()
      : status = RideIntegrityStatus.verified,
        hasMetadata = true,
        issues = const <String>[];

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

  final RideIntegrityStatus status;
  final bool hasMetadata;
  final List<String> issues;

  bool get isVerified => status == RideIntegrityStatus.verified;
}

/// Represents a persisted ride session loaded from a telemetry JSON file.
///
/// A ride record holds references to video segments, GPS/telemetry samples,
/// integrity verification results, and summary statistics (distance, speed).
/// It is the primary data model consumed by the ride history and playback
/// screens.
class RideRecord {
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
  });

  static const String _androidPublicExportDirectory =
      '/storage/emulated/0/Movies/MotoCam/Recordings';
  static const String _integrityAlgoSha256 = 'sha256';

  final String videoPath;
  final List<String> segmentPaths;
  final List<String> lockedSegmentPaths;
  final DateTime createdAt;
  final String? telemetryPath;
  final String? rideSessionId;
  final bool isSessionComplete;
  final double distanceKm;
  final double maxSpeedKmh;
  final double averageSpeedKmh;
  final List<RideSegmentTimelineEntry> segmentTimeline;
  final List<TelemetryData> samples;
  final RideIntegrityReport integrity;
  final List<String> quarantinedSegmentPaths;

  String get fileName {
    final parts = videoPath.split(Platform.pathSeparator);
    return parts.isEmpty ? videoPath : parts.last;
  }

  bool get isLocked => lockedSegmentPaths.isNotEmpty;
  bool get hasQuarantinedSegments => quarantinedSegmentPaths.isNotEmpty;

  String get integrityLabel {
    switch (integrity.status) {
      case RideIntegrityStatus.verified:
        return 'Verified';
      case RideIntegrityStatus.modified:
        return 'Modified';
      case RideIntegrityStatus.unknown:
        return 'Unknown';
    }
  }

  Duration get duration {
    if (samples.isEmpty) {
      return Duration.zero;
    }
    return Duration(milliseconds: samples.last.elapsedMs);
  }

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
    return TelemetryData(
      latitude: _lerp(lower.latitude, upper.latitude, t),
      longitude: _lerp(lower.longitude, upper.longitude, t),
      speed: _lerp(lower.speed, upper.speed, t),
      bearing: _lerp(lower.bearing, upper.bearing, t),
      accelerationG: _lerp(lower.accelerationG, upper.accelerationG, t),
      elapsedMs: targetMs,
      distanceKm: _lerp(lower.distanceKm, upper.distanceKm, t),
      timestamp: lower.timestamp.add(Duration(milliseconds: targetMs - lower.elapsedMs)),
    );
  }

  static double _lerp(double a, double b, double t) => a + ((b - a) * t);

  static Future<RideRecord> fromVideoFile(File videoFile, {bool verifySegments = false}) async {
    final telemetryPath = _telemetryPathForVideo(videoFile.path);
    final telemetryFile = File(telemetryPath);
    final fallbackRide = RideRecord(
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

    if (!await telemetryFile.exists()) {
      return fallbackRide;
    }

    try {
      final raw = await telemetryFile.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final samples = _readSamples(json);
      final trustedRoots = _trustedRootsForTelemetry(
        telemetryFile: telemetryFile,
        json: json,
        fallbackVideoPath: videoFile.path,
      );

      final pathTrust = _trustSegmentPaths(
        segmentPaths: _readSegmentPaths(json, fallbackPath: videoFile.path),
        trustedRoots: trustedRoots,
        sourceLabel: telemetryFile.path,
      );

      final segmentPaths = await _existingPathsInOrder(pathTrust.allowed);
      if (segmentPaths.isEmpty) {
        if (_isPathInsideAnyTrustedRoot(videoFile.path, trustedRoots)) {
          segmentPaths.add(videoFile.path);
        }
      }
      final segmentTimeline = _readSegmentTimeline(
        json,
        segmentPaths: segmentPaths,
      );

      final integrity = _applyTrustToIntegrity(
        await _verifyIntegrity(json: json, segmentPaths: segmentPaths, verifySegments: verifySegments),
        pathTrust.quarantined,
      );

      return RideRecord(
        videoPath: videoFile.path,
        segmentPaths: segmentPaths,
        lockedSegmentPaths:
            _readLockedSegmentPaths(json, fallbackPaths: segmentPaths),
        createdAt: DateTime.tryParse(json['startedAt']?.toString() ?? '') ??
            (await videoFile.stat()).modified,
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
        quarantinedSegmentPaths: pathTrust.quarantined,
      );
    } catch (_) {
      return fallbackRide;
    }
  }

  static Future<RideRecord?> fromTelemetryFile(File telemetryFile, {bool verifySegments = false}) async {
    if (!await telemetryFile.exists()) {
      return null;
    }

    try {
      final raw = await telemetryFile.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final videoPath = json['videoPath']?.toString() ?? '';
      final trustedRoots = _trustedRootsForTelemetry(
        telemetryFile: telemetryFile,
        json: json,
        fallbackVideoPath: videoPath,
      );

      final pathTrust = _trustSegmentPaths(
        segmentPaths: _readSegmentPaths(
          json,
          fallbackPath: videoPath,
        ),
        trustedRoots: trustedRoots,
        sourceLabel: telemetryFile.path,
      );
      final declaredSegmentPaths = List<String>.from(pathTrust.allowed);
      final quarantinedSegmentPaths = List<String>.from(pathTrust.quarantined);
      final existingSegmentPaths = await _existingPathsInOrder(
        declaredSegmentPaths,
      );

      if (declaredSegmentPaths.isEmpty) {
        final recoveredPath = await _recoverVideoPathFromTelemetryFile(
          telemetryFile,
        );
        if (recoveredPath != null) {
          if (_isPathInsideAnyTrustedRoot(recoveredPath, trustedRoots)) {
            declaredSegmentPaths.add(recoveredPath);
            existingSegmentPaths.add(recoveredPath);
          } else {
            quarantinedSegmentPaths.add(recoveredPath);
          }
        }
      }

      var resolvedVideoPath = videoPath.trim();
      if (resolvedVideoPath.isNotEmpty &&
          !_isPathInsideAnyTrustedRoot(resolvedVideoPath, trustedRoots)) {
        quarantinedSegmentPaths.add(resolvedVideoPath);
        resolvedVideoPath = '';
      }

      if (resolvedVideoPath.isEmpty) {
        if (existingSegmentPaths.isNotEmpty) {
          resolvedVideoPath = existingSegmentPaths.last;
        } else if (declaredSegmentPaths.isNotEmpty) {
          resolvedVideoPath = declaredSegmentPaths.last;
        }
      }

      if (resolvedVideoPath.isEmpty) {
        return null;
      }
      if (!declaredSegmentPaths.contains(resolvedVideoPath)) {
        if (_isPathInsideAnyTrustedRoot(resolvedVideoPath, trustedRoots)) {
          declaredSegmentPaths.add(resolvedVideoPath);
        } else {
          quarantinedSegmentPaths.add(resolvedVideoPath);
        }
      }

      final samples = _readSamples(json);
      final segmentTimeline = _readSegmentTimeline(
        json,
        segmentPaths: declaredSegmentPaths,
      );
      final integrity = _applyTrustToIntegrity(
        await _verifyIntegrity(json: json, segmentPaths: declaredSegmentPaths, verifySegments: verifySegments),
        quarantinedSegmentPaths,
      );

      return RideRecord(
        videoPath: resolvedVideoPath,
        segmentPaths: declaredSegmentPaths,
        lockedSegmentPaths:
            _readLockedSegmentPaths(json, fallbackPaths: declaredSegmentPaths),
        createdAt: DateTime.tryParse(json['startedAt']?.toString() ?? '') ??
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
        quarantinedSegmentPaths: List<String>.unmodifiable(
          quarantinedSegmentPaths,
        ),
      );
    } catch (_) {
      return null;
    }
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

    for (final extension in <String>['.mp4', '.mov', '.mkv', '.avi']) {
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
    final raw = (json['segmentPaths'] as List<dynamic>? ?? const []);
    final paths = <String>[];
    final seen = <String>{};
    for (final value in raw) {
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

  static List<String> _trustedRootsForTelemetry({
    required File telemetryFile,
    required Map<String, dynamic> json,
    String? fallbackVideoPath,
  }) {
    final roots = <String>[];
    roots.add(telemetryFile.parent.path);

    final storageDirectory = _readOptionalString(json, 'storageDirectory');
    if (storageDirectory != null) {
      roots.add(storageDirectory);
    }

    final fallback = (fallbackVideoPath ?? '').trim();
    if (fallback.isNotEmpty) {
      roots.add(File(fallback).parent.path);
    }

    if (Platform.isAndroid) {
      roots.add(_androidPublicExportDirectory);
    }

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

  static _PathTrustResult _trustSegmentPaths({
    required List<String> segmentPaths,
    required List<String> trustedRoots,
    required String sourceLabel,
  }) {
    final allowed = <String>[];
    final quarantined = <String>[];
    final seen = <String>{};

    for (final rawPath in segmentPaths) {
      final path = rawPath.trim();
      if (path.isEmpty || !seen.add(path)) {
        continue;
      }

      if (_isPathInsideAnyTrustedRoot(path, trustedRoots)) {
        allowed.add(path);
      } else {
        quarantined.add(path);
        debugPrint(
          'RideRecord: quarantined out-of-scope segment path from $sourceLabel -> $path',
        );
      }
    }

    return _PathTrustResult(
      allowed: List<String>.unmodifiable(allowed),
      quarantined: List<String>.unmodifiable(quarantined),
    );
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
    final samplesJson = (json['samples'] as List<dynamic>? ?? const <dynamic>[]);
    final samples = <TelemetryData>[];

    for (final raw in samplesJson.whereType<Map>()) {
      try {
        final normalized =
            raw.map((key, value) => MapEntry(key.toString(), value));
        samples.add(TelemetryData.fromJson(normalized));
      } catch (_) {
        // Keep loading the ride even if a single sample is malformed.
      }
    }

    return samples;
  }

  static List<RideSegmentTimelineEntry> _readSegmentTimeline(
    Map<String, dynamic> json, {
    required List<String> segmentPaths,
  }) {
    final pathSet = segmentPaths.toSet();
    final rawTimeline =
        (json['segmentTimeline'] as List<dynamic>? ?? const <dynamic>[]);
    final entries = <RideSegmentTimelineEntry>[];
    final seenPaths = <String>{};

    for (final rawEntry in rawTimeline.whereType<Map>()) {
      final entry = rawEntry.map((key, value) => MapEntry(key.toString(), value));
      final path = entry['path']?.toString() ?? '';
      if (path.isEmpty || !pathSet.contains(path) || seenPaths.contains(path)) {
        continue;
      }

      final startMs = (entry['startMs'] as num?)?.toInt() ?? 0;
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
    required List<String> fallbackPaths,
  }) {
    final raw =
        (json['lockedSegmentPaths'] as List<dynamic>? ?? const <dynamic>[]);
    final paths = raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    if (paths.isEmpty) {
      return const [];
    }

    final fallbackSet = fallbackPaths.toSet();
    return paths.where((path) => fallbackSet.contains(path)).toList();
  }

  Future<void> setLockState(bool locked) async {
    if (integrity.status == RideIntegrityStatus.modified ||
        hasQuarantinedSegments) {
      return;
    }

    final path = telemetryPath;
    if (path == null) {
      return;
    }

    final telemetryFile = File(path);
    if (!await telemetryFile.exists()) {
      return;
    }

    try {
      final raw = await telemetryFile.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return;
      }

      final json = decoded.map(
        (key, value) => MapEntry(key.toString(), value),
      );

      final targetSegments =
          segmentPaths.isNotEmpty ? segmentPaths : <String>[videoPath];
      json['lockedSegmentPaths'] = locked ? targetSegments : <String>[];

      final integrity = await _buildIntegrityMetadataForPayload(json);
      json['integrity'] = integrity;

      await _writeTelemetryAtomically(
        telemetryFile: telemetryFile,
        content: jsonEncode(json),
      );
    } catch (_) {
      // Ignore lock-state updates for malformed telemetry files.
    }
  }

  static Future<RideIntegrityReport> _verifyIntegrity({
    required Map<String, dynamic> json,
    required List<String> segmentPaths,
    bool verifySegments = false,
  }) async {
    final rawIntegrity = json['integrity'];
    if (rawIntegrity is! Map) {
      return const RideIntegrityReport.unknown();
    }

    final integrity = rawIntegrity.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    final issues = <String>[];

    final algorithm = (integrity['algo']?.toString().trim().toLowerCase() ?? '');
    if (algorithm != _integrityAlgoSha256) {
      issues.add('unsupported-integrity-algorithm:$algorithm');
    }

    final expectedPayloadHash =
        integrity['payloadHash']?.toString().trim().toLowerCase() ?? '';
    if (expectedPayloadHash.isEmpty) {
      issues.add('missing-payload-hash');
    } else {
      final payloadWithoutIntegrity = Map<String, dynamic>.from(json)
        ..remove('integrity');
      final actualPayloadHash = _hashJsonCanonical(payloadWithoutIntegrity);
      if (actualPayloadHash != expectedPayloadHash) {
        issues.add('payload-hash-mismatch');
      }
    }

    final expectedSegmentHashes = _readExpectedSegmentHashes(integrity);
    if (verifySegments) {
      for (final segmentPath in segmentPaths) {
        final expectedHash = expectedSegmentHashes[segmentPath];
        if (expectedHash == null || expectedHash.isEmpty) {
          issues.add('missing-segment-hash:$segmentPath');
          continue;
        }

        final actualHash = await _hashFileSha256(segmentPath);
        if (actualHash == null) {
          issues.add('missing-segment-file:$segmentPath');
          continue;
        }

        if (actualHash != expectedHash) {
          issues.add('segment-hash-mismatch:$segmentPath');
        }
      }
    }

    for (final hashedPath in expectedSegmentHashes.keys) {
      if (!segmentPaths.contains(hashedPath)) {
        issues.add('orphan-integrity-hash:$hashedPath');
      }
    }

    if (issues.isEmpty) {
      return const RideIntegrityReport.verified();
    }
    return RideIntegrityReport.modified(issues);
  }

  Future<RideRecord> verifySegmentIntegrity() async {
    if (telemetryPath == null) {
      return this;
    }
    final telemetryFile = File(telemetryPath!);
    if (!await telemetryFile.exists()) {
      return this;
    }

    try {
      final raw = await telemetryFile.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      
      final trustedRoots = _trustedRootsForTelemetry(
        telemetryFile: telemetryFile,
        json: json,
        fallbackVideoPath: videoPath,
      );

      final pathTrust = _trustSegmentPaths(
        segmentPaths: _readSegmentPaths(
          json,
          fallbackPath: videoPath,
        ),
        trustedRoots: trustedRoots,
        sourceLabel: telemetryFile.path,
      );

      final declaredSegmentPaths = List<String>.from(pathTrust.allowed);
      final quarantinedSegmentPaths = List<String>.from(pathTrust.quarantined);

      final integrity = _applyTrustToIntegrity(
        await _verifyIntegrity(
          json: json,
          segmentPaths: declaredSegmentPaths,
          verifySegments: true,
        ),
        quarantinedSegmentPaths,
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
        quarantinedSegmentPaths: quarantinedSegmentPaths,
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

  static Future<Map<String, dynamic>> _buildIntegrityMetadataForPayload(
    Map<String, dynamic> payload,
  ) async {
    final payloadWithoutIntegrity = Map<String, dynamic>.from(payload)
      ..remove('integrity');

    final fallbackVideoPath =
        payloadWithoutIntegrity['videoPath']?.toString().trim() ?? '';
    final segmentPaths = await _existingPathsInOrder(
      _readSegmentPaths(
        payloadWithoutIntegrity,
        fallbackPath: fallbackVideoPath,
      ),
    );

    final segmentHashes = <String, String>{};
    for (final segmentPath in segmentPaths) {
      final hash = await _hashFileSha256(segmentPath);
      if (hash == null) {
        continue;
      }
      segmentHashes[segmentPath] = hash;
    }

    return {
      'algo': _integrityAlgoSha256,
      'payloadHash': _hashJsonCanonical(payloadWithoutIntegrity),
      'segmentCount': segmentPaths.length,
      'hashedSegmentCount': segmentHashes.length,
      'segmentHashes': segmentHashes,
      'generatedAt': DateTime.now().toIso8601String(),
    };
  }

  static String _hashJsonCanonical(Map<String, dynamic> payload) =>
      integrity_utils.hashJsonCanonical(payload);

  static Future<String?> _hashFileSha256(String path) =>
      integrity_utils.hashFileSha256(path);

  static Future<void> _writeTelemetryAtomically({
    required File telemetryFile,
    required String content,
  }) =>
      integrity_utils.writeTelemetryAtomically(
        telemetryFile: telemetryFile,
        content: content,
      );

  static String _telemetryPathForVideo(String videoPath) {
    final dotIndex = videoPath.lastIndexOf('.');
    if (dotIndex <= 0) {
      return '$videoPath.telemetry.json';
    }
    return '${videoPath.substring(0, dotIndex)}.telemetry.json';
  }
}

class RideSegmentTimelineEntry {
  const RideSegmentTimelineEntry({
    required this.path,
    required this.startMs,
    required this.endMs,
  });

  final String path;
  final int startMs;
  final int endMs;
}

class _PathTrustResult {
  const _PathTrustResult({
    required this.allowed,
    required this.quarantined,
  });

  final List<String> allowed;
  final List<String> quarantined;
}