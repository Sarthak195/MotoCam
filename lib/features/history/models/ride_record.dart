import 'dart:convert';
import 'dart:io';

import '../../telemetry/models/telemetry_data.dart';

class RideRecord {
  RideRecord({
    required this.videoPath,
    required this.createdAt,
    required this.telemetryPath,
    required this.distanceKm,
    required this.maxSpeedKmh,
    required this.averageSpeedKmh,
    required this.samples,
  });

  final String videoPath;
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

    final index = low.clamp(0, samples.length - 1);
    return samples[index];
  }

  static Future<RideRecord> fromVideoFile(File videoFile) async {
    final telemetryPath = _telemetryPathForVideo(videoFile.path);
    final telemetryFile = File(telemetryPath);

    if (!await telemetryFile.exists()) {
      return RideRecord(
        videoPath: videoFile.path,
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
      createdAt: DateTime.tryParse(json['startedAt']?.toString() ?? '') ??
          (await videoFile.stat()).modified,
      telemetryPath: telemetryFile.path,
      distanceKm: (json['distanceKm'] as num?)?.toDouble() ?? 0,
      maxSpeedKmh: (json['maxSpeedKmh'] as num?)?.toDouble() ?? 0,
      averageSpeedKmh: (json['averageSpeedKmh'] as num?)?.toDouble() ?? 0,
      samples: samples,
    );
  }

  static String _telemetryPathForVideo(String videoPath) {
    final dotIndex = videoPath.lastIndexOf('.');
    if (dotIndex <= 0) {
      return '$videoPath.telemetry.json';
    }
    return '${videoPath.substring(0, dotIndex)}.telemetry.json';
  }
}