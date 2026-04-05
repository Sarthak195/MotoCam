import 'dart:convert';
import 'dart:io';

import '../../telemetry/models/telemetry_data.dart';

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
  });

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

  String get fileName {
    final parts = videoPath.split(Platform.pathSeparator);
    return parts.isEmpty ? videoPath : parts.last;
  }

  bool get isLocked => lockedSegmentPaths.isNotEmpty;

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

  static Future<RideRecord> fromVideoFile(File videoFile) async {
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
    );

    if (!await telemetryFile.exists()) {
      return fallbackRide;
    }

    try {
      final raw = await telemetryFile.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final samples = _readSamples(json);

      final segmentPaths = await _existingPathsInOrder(
        _readSegmentPaths(json, fallbackPath: videoFile.path),
      );
      if (segmentPaths.isEmpty) {
        segmentPaths.add(videoFile.path);
      }
      final segmentTimeline = _readSegmentTimeline(
        json,
        segmentPaths: segmentPaths,
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
      );
    } catch (_) {
      return fallbackRide;
    }
  }

  static Future<RideRecord?> fromTelemetryFile(File telemetryFile) async {
    if (!await telemetryFile.exists()) {
      return null;
    }

    try {
      final raw = await telemetryFile.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final videoPath = json['videoPath']?.toString() ?? '';

      final declaredSegmentPaths = _readSegmentPaths(
        json,
        fallbackPath: videoPath,
      );
      final existingSegmentPaths = await _existingPathsInOrder(
        declaredSegmentPaths,
      );

      if (declaredSegmentPaths.isEmpty) {
        final recoveredPath = await _recoverVideoPathFromTelemetryFile(
          telemetryFile,
        );
        if (recoveredPath != null) {
          declaredSegmentPaths.add(recoveredPath);
          existingSegmentPaths.add(recoveredPath);
        }
      }

      var resolvedVideoPath = videoPath;
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
        declaredSegmentPaths.add(resolvedVideoPath);
      }

      final samples = _readSamples(json);
      final segmentTimeline = _readSegmentTimeline(
        json,
        segmentPaths: declaredSegmentPaths,
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
      );
    } catch (_) {
      return null;
    }
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
    final path = telemetryPath;
    if (path == null) {
      return;
    }

    final telemetryFile = File(path);
    if (!await telemetryFile.exists()) {
      return;
    }

    final raw = await telemetryFile.readAsString();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final targetSegments =
        segmentPaths.isNotEmpty ? segmentPaths : <String>[videoPath];
    json['lockedSegmentPaths'] = locked ? targetSegments : <String>[];
    await telemetryFile.writeAsString(jsonEncode(json));
  }

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