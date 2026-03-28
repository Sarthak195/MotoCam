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
    required this.distanceKm,
    required this.maxSpeedKmh,
    required this.averageSpeedKmh,
    required this.samples,
  });

  final String videoPath;
  final List<String> segmentPaths;
  final List<String> lockedSegmentPaths;
  final DateTime createdAt;
  final String? telemetryPath;
  final double distanceKm;
  final double maxSpeedKmh;
  final double averageSpeedKmh;
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

    if (!await telemetryFile.exists()) {
      return RideRecord(
        videoPath: videoFile.path,
        segmentPaths: [videoFile.path],
        lockedSegmentPaths: const [],
        createdAt: (await videoFile.stat()).modified,
        telemetryPath: null,
        distanceKm: 0,
        maxSpeedKmh: 0,
        averageSpeedKmh: 0,
        samples: const [],
      );
    }

    final raw = await telemetryFile.readAsString();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final samplesJson = (json['samples'] as List<dynamic>? ?? const []);
    final samples = samplesJson
      .whereType<Map>()
      .map((raw) => raw.map((key, value) => MapEntry(key.toString(), value)))
      .map(TelemetryData.fromJson)
      .toList();

    return RideRecord(
      videoPath: videoFile.path,
      segmentPaths: _readSegmentPaths(json, fallbackPath: videoFile.path),
      lockedSegmentPaths:
        _readLockedSegmentPaths(json, fallbackPaths: [videoFile.path]),
      createdAt: DateTime.tryParse(json['startedAt']?.toString() ?? '') ??
          (await videoFile.stat()).modified,
      telemetryPath: telemetryFile.path,
      distanceKm: _readJsonDouble(json, 'distanceKm'),
      maxSpeedKmh: _readJsonDouble(json, 'maxSpeedKmh'),
      averageSpeedKmh: _readJsonDouble(json, 'averageSpeedKmh'),
      samples: samples,
    );
  }

  static Future<RideRecord?> fromTelemetryFile(File telemetryFile) async {
    if (!await telemetryFile.exists()) {
      return null;
    }

    final raw = await telemetryFile.readAsString();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final videoPath = json['videoPath']?.toString();
    if (videoPath == null || videoPath.isEmpty) {
      return null;
    }

    final samplesJson = (json['samples'] as List<dynamic>? ?? const []);
    final samples = samplesJson
        .whereType<Map>()
        .map((raw) => raw.map((key, value) => MapEntry(key.toString(), value)))
        .map(TelemetryData.fromJson)
        .toList();

    final segmentPaths = _readSegmentPaths(json, fallbackPath: videoPath);

    return RideRecord(
      videoPath: videoPath,
      segmentPaths: segmentPaths,
      lockedSegmentPaths:
        _readLockedSegmentPaths(json, fallbackPaths: segmentPaths),
      createdAt: DateTime.tryParse(json['startedAt']?.toString() ?? '') ??
          (await telemetryFile.stat()).modified,
      telemetryPath: telemetryFile.path,
      distanceKm: _readJsonDouble(json, 'distanceKm'),
      maxSpeedKmh: _readJsonDouble(json, 'maxSpeedKmh'),
      averageSpeedKmh: _readJsonDouble(json, 'averageSpeedKmh'),
      samples: samples,
    );
  }

  static double _readJsonDouble(Map<String, dynamic> json, String key) =>
      (json[key] as num?)?.toDouble() ?? 0;

  static List<String> _readSegmentPaths(
    Map<String, dynamic> json, {
    required String fallbackPath,
  }) {
    final raw = (json['segmentPaths'] as List<dynamic>? ?? const []);
    final paths = raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    if (paths.isEmpty) {
      paths.add(fallbackPath);
    }
    return paths;
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