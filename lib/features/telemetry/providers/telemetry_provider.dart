// lib/features/telemetry/providers/telemetry_provider.dart

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../../../core/utils/path_utils.dart' as path_utils;
import '../../../core/utils/integrity_utils.dart' as integrity_utils;
import '../models/telemetry_data.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// Collects and manages real-time ride telemetry (GPS, speed, acceleration)
/// and persists completed ride sessions as JSON alongside video segments.
///
/// This provider owns the accelerometer and location stream subscriptions and
/// should be disposed when no longer needed.
class TelemetryProvider extends ChangeNotifier {
  TelemetryProvider({this.sampleInterval = const Duration(seconds: 1)});

  final Duration sampleInterval;
  TelemetryData _currentData = TelemetryData.empty();
  final List<TelemetryData> _telemetryHistory = [];
  final List<TelemetryData> _activeRideSamples = [];

  StreamSubscription<UserAccelerometerEvent>? _accelerometerSubscription;
  StreamSubscription<Position>? _positionSubscription;
  Timer? _sampleTimer;
  Timer? _locationPollTimer;
  DateTime? _rideStartTime;
  Position? _lastRidePosition;
  bool _isTrackingStarted = false;
  bool _isRideActive = false;
  double _rideDistanceKm = 0.0;
  double _maxSpeedKmh = 0.0;
  double _averageSpeedKmh = 0.0;
  double _incidentTriggerGForce = 3.5;
  Duration _incidentDebounce = const Duration(seconds: 6);
  DateTime? _lastIncidentDetectedAt;
  double _lastIncidentGForce = 0.0;
  int _incidentCount = 0;
  DateTime? _lastUiNotifyAt;
  Duration _uiNotifyMinInterval = const Duration(milliseconds: 100);
  double _smoothedLinearAccelerationG = 0.0;
  int _consecutiveIncidentHits = 0;
  Position? _lastSpeedPosition;
  DateTime? _lastSpeedTimestamp;
  DateTime? _lastLocationUpdateAt;
  double _filteredSpeedKmh = 0.0;
  int _stationaryFixStreak = 0;
  bool _isFallbackPolling = false;
  String? _rideSessionId;

  TelemetryData get currentData => _currentData;
  List<TelemetryData> get telemetryHistory =>
      List.unmodifiable(_telemetryHistory);
  List<TelemetryData> get activeRideSamples =>
      List.unmodifiable(_activeRideSamples);
  bool get isRideActive => _isRideActive;
  double get rideDistanceKm => _rideDistanceKm;
  double get maxSpeedKmh => _maxSpeedKmh;
  double get averageSpeedKmh => _averageSpeedKmh;
  double get incidentTriggerGForce => _incidentTriggerGForce;
  Duration get incidentDebounce => _incidentDebounce;
  DateTime? get lastIncidentDetectedAt => _lastIncidentDetectedAt;
  double get lastIncidentGForce => _lastIncidentGForce;
  int get incidentCount => _incidentCount;
  Duration get uiNotifyMinInterval => _uiNotifyMinInterval;

  void setSpeedUiRefreshInterval(Duration interval) {
    final clampedMs = interval.inMilliseconds.clamp(100, 1000);
    _uiNotifyMinInterval = Duration(milliseconds: clampedMs);
    _lastUiNotifyAt = null;
    _forceNotifyUi();
  }

  void setIncidentDetectionConfig({
    required double triggerGForce,
    required Duration debounce,
  }) {
    _incidentTriggerGForce = triggerGForce;
    _incidentDebounce = debounce;
  }

  Future<void> initialize() async {
    if (_isTrackingStarted) {
      return;
    }

    final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    _isTrackingStarted = true;
    _startAccelerometerTracking();
    _startLocationTracking();
  }

  void _startLocationTracking() {
    final LocationSettings locationSettings;
    if (Platform.isAndroid) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: Duration(milliseconds: 500),
        forceLocationManager: true,
      );
    } else if (Platform.isIOS) {
      locationSettings = AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
      );
    } else {
      locationSettings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      );
    }

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(_updateLocation);

    _locationPollTimer?.cancel();
    _locationPollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _pollLocationIfStale();
    });
  }

  Future<void> _pollLocationIfStale() async {
    if (_isFallbackPolling) {
      return;
    }

    final now = DateTime.now();
    final lastUpdate = _lastLocationUpdateAt;
    if (lastUpdate != null && now.difference(lastUpdate) < const Duration(seconds: 2)) {
      return;
    }

    _isFallbackPolling = true;
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 2),
        ),
      );
      _updateLocation(position);
    } catch (_) {
      // Best-effort fallback polling only.
    } finally {
      _isFallbackPolling = false;
    }
  }

  void _updateLocation(Position position) {
    final now = DateTime.now();
    _lastLocationUpdateAt = now;

    var gpsSpeedKmh = position.speed * 3.6; // m/s to km/h
    if (gpsSpeedKmh.isNaN || gpsSpeedKmh.isInfinite || gpsSpeedKmh < 0) {
      gpsSpeedKmh = 0;
    }

    double displacementSpeedKmh = 0.0;
    var movedMeters = 0.0;
    if (_lastSpeedPosition != null && _lastSpeedTimestamp != null) {
      final dtSeconds =
          now.difference(_lastSpeedTimestamp!).inMilliseconds.clamp(250, 10000) /
              1000.0;
      movedMeters = Geolocator.distanceBetween(
        _lastSpeedPosition!.latitude,
        _lastSpeedPosition!.longitude,
        position.latitude,
        position.longitude,
      );
      displacementSpeedKmh = (movedMeters / dtSeconds) * 3.6;
    }

    // Keep movement noise tolerance tighter so walking is not suppressed.
    final movementNoiseMeters =
      (position.accuracy * 0.25).clamp(0.8, 2.5).toDouble();
    final isDeviceMovingByAccel = _smoothedLinearAccelerationG >= 0.035;
    final likelyStationary =
      !isDeviceMovingByAccel &&
      movedMeters < movementNoiseMeters &&
      gpsSpeedKmh < 1.4 &&
      displacementSpeedKmh < 1.8;
    if (likelyStationary) {
      _stationaryFixStreak++;
    } else {
      _stationaryFixStreak = 0;
    }

    final speedAccuracyMps = position.speedAccuracy;
    final hasReliableGpsSpeed = speedAccuracyMps > 0 && speedAccuracyMps <= 1.5;

    var candidateSpeedKmh = hasReliableGpsSpeed
        ? gpsSpeedKmh
        : (gpsSpeedKmh * 0.55) + (displacementSpeedKmh * 0.45);

    if (_stationaryFixStreak >= 5 &&
        gpsSpeedKmh < 1.0 &&
        displacementSpeedKmh < 1.5 &&
        !isDeviceMovingByAccel) {
      candidateSpeedKmh = 0;
    }

    // Use faster decay than rise to reflect braking quickly while keeping launch smooth.
    final alpha = candidateSpeedKmh < _filteredSpeedKmh ? 0.60 : 0.32;
    _filteredSpeedKmh = _filteredSpeedKmh == 0
        ? candidateSpeedKmh
        : (_filteredSpeedKmh * (1.0 - alpha)) + (candidateSpeedKmh * alpha);

    if (_filteredSpeedKmh < 0.6 || _stationaryFixStreak >= 6) {
      _filteredSpeedKmh = 0;
    }

    _lastSpeedPosition = position;
    _lastSpeedTimestamp = now;

    var updatedDistanceKm = _rideDistanceKm;
    if (_isRideActive && _lastRidePosition != null) {
      final meters = Geolocator.distanceBetween(
        _lastRidePosition!.latitude,
        _lastRidePosition!.longitude,
        position.latitude,
        position.longitude,
      );

      if (meters > 0) {
        updatedDistanceKm += (meters / 1000);
      }
    }

    _rideDistanceKm = updatedDistanceKm;
    _currentData = _currentData.copyWith(
      latitude: position.latitude,
      longitude: position.longitude,
      speed: _filteredSpeedKmh,
      bearing: position.heading,
      timestamp: now,
      distanceKm: updatedDistanceKm,
    );

    _lastRidePosition = position;
    _notifyUiIfNeeded();
  }

  void _startAccelerometerTracking() {
    _accelerometerSubscription =
        userAccelerometerEventStream().listen((UserAccelerometerEvent event) {
      // userAccelerometer provides linear acceleration (gravity removed).
      final double rawLinearAccelerationG =
          math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z) /
              9.81;
      const smoothingAlpha = 0.30;
      _smoothedLinearAccelerationG = _smoothedLinearAccelerationG == 0.0
          ? rawLinearAccelerationG
          : (_smoothedLinearAccelerationG * (1.0 - smoothingAlpha)) +
              (rawLinearAccelerationG * smoothingAlpha);

      _currentData = _currentData.copyWith(
        accelerationG: _smoothedLinearAccelerationG,
        timestamp: DateTime.now(),
      );

      // Require short persistence above threshold to reduce random spikes.
      if (_smoothedLinearAccelerationG >= _incidentTriggerGForce) {
        _consecutiveIncidentHits++;
        if (_consecutiveIncidentHits >= 2) {
          _detectCrash(_smoothedLinearAccelerationG);
          _consecutiveIncidentHits = 0;
        }
      } else {
        _consecutiveIncidentHits = 0;
      }

      _notifyUiIfNeeded();
    });
  }

  void startRideSession() {
    _isRideActive = true;
    _rideStartTime = DateTime.now();
    _rideSessionId = _buildRideSessionId(_rideStartTime!);
    _rideDistanceKm = 0.0;
    _maxSpeedKmh = 0.0;
    _averageSpeedKmh = 0.0;
    _lastIncidentDetectedAt = null;
    _lastIncidentGForce = 0.0;
    _incidentCount = 0;
    _smoothedLinearAccelerationG = 0.0;
    _consecutiveIncidentHits = 0;
    _lastSpeedPosition = null;
    _lastSpeedTimestamp = null;
    _lastLocationUpdateAt = null;
    _filteredSpeedKmh = 0.0;
    _stationaryFixStreak = 0;
    _lastRidePosition = null;
    _activeRideSamples.clear();

    _sampleTimer?.cancel();
    _captureSample();
    _sampleTimer = Timer.periodic(sampleInterval, (_) {
      _captureSample();
    });

    _forceNotifyUi();
  }

  void _captureSample() {
    if (!_isRideActive || _rideStartTime == null) {
      return;
    }

    final TelemetryData sample = _currentData.copyWith(
      elapsedMs: DateTime.now().difference(_rideStartTime!).inMilliseconds,
      distanceKm: _rideDistanceKm,
      timestamp: DateTime.now(),
    );

    _activeRideSamples.add(sample);
    _telemetryHistory.add(sample);

    if (sample.speed > _maxSpeedKmh) {
      _maxSpeedKmh = sample.speed;
    }

    if (_activeRideSamples.isNotEmpty) {
      final total = _activeRideSamples.fold<double>(
          0.0, (sum, point) => sum + point.speed);
      _averageSpeedKmh = total / _activeRideSamples.length;
    }

    _forceNotifyUi();
  }

  Future<String?> stopRideSessionAndPersist(
    String videoPath, {
    List<String>? segmentPaths,
    List<String>? lockedSegmentPaths,
    List<Map<String, dynamic>>? segmentTimeline,
    Map<String, dynamic>? recordingSettings,
  }) async {
    if (!_isRideActive || _rideStartTime == null) {
      _isRideActive = false;
      _sampleTimer?.cancel();
      _forceNotifyUi();
      return null;
    }

    _isRideActive = false;
    _sampleTimer?.cancel();

    final DateTime rideStart = _rideStartTime!;
    final DateTime rideEnd = DateTime.now();
    _rideStartTime = null;

    final canonicalVideoPath = videoPath.trim();
    final canonicalStorageDirectory = canonicalVideoPath.isEmpty
        ? ''
        : File(canonicalVideoPath).parent.path;
    final normalizedSegmentPaths = _normalizeSegmentPaths(
      segmentPaths: segmentPaths,
      fallbackVideoPath: canonicalVideoPath,
    );
    var resolvedSegmentPaths = _filterPathsInDirectory(
      paths: normalizedSegmentPaths,
      directoryPath: canonicalStorageDirectory,
    );
    resolvedSegmentPaths = await _filterExistingPathsInOrder(
      paths: resolvedSegmentPaths,
    );
    if (resolvedSegmentPaths.isEmpty && canonicalVideoPath.isNotEmpty) {
      if (await File(canonicalVideoPath).exists()) {
        resolvedSegmentPaths.add(canonicalVideoPath);
      }
    }
    final resolvedLockedPaths = _normalizeLockedPaths(
      lockedSegmentPaths: lockedSegmentPaths,
      knownSegmentPaths: resolvedSegmentPaths,
    );
    final resolvedSegmentTimeline = _normalizeSegmentTimeline(
      segmentTimeline: segmentTimeline,
      knownSegmentPaths: resolvedSegmentPaths,
    );
    final effectiveRideSessionId = _rideSessionId ?? _buildRideSessionId(rideStart);
    final normalizedRecordingSettings =
        _normalizeRecordingSettings(recordingSettings);

    final telemetryPayloadCore = {
      'schemaVersion': 2,
      'rideSessionId': effectiveRideSessionId,
      'sessionComplete': true,
      'storagePolicy': 'hybrid-private-primary',
      'publicExportRelativePath': 'Movies/MotoCam/Recordings',
      'storageDirectory': canonicalStorageDirectory,
      'sampleRateMs': sampleInterval.inMilliseconds,
      'videoPath': canonicalVideoPath,
      'videoFileName': _extractFileName(canonicalVideoPath),
      'segmentPaths': resolvedSegmentPaths,
      'lockedSegmentPaths': resolvedLockedPaths,
      'segmentTimeline': resolvedSegmentTimeline,
      'recordingSettings': normalizedRecordingSettings,
      'startedAt': rideStart.toIso8601String(),
      'endedAt': rideEnd.toIso8601String(),
      'distanceKm': _rideDistanceKm,
      'maxSpeedKmh': _maxSpeedKmh,
      'averageSpeedKmh': _averageSpeedKmh,
      'samples': _activeRideSamples.map((sample) => sample.toJson()).toList(),
    };

    final integrity = await _buildIntegrityMetadata(
      payload: telemetryPayloadCore,
      segmentPaths: resolvedSegmentPaths,
    );
    final telemetryPayload = {
      ...telemetryPayloadCore,
      'integrity': integrity,
    };

    final String telemetryPath = _buildPrimaryTelemetryPath(
      rideSessionId: effectiveRideSessionId,
      canonicalVideoPath: canonicalVideoPath,
      segmentPaths: resolvedSegmentPaths,
    );
    await _writeTelemetryAtomically(
      telemetryPath: telemetryPath,
      payload: telemetryPayload,
    );

    _activeRideSamples.clear();
    _rideSessionId = null;
    _forceNotifyUi();
    return telemetryPath;
  }

  void cancelRideSession() {
    _isRideActive = false;
    _rideStartTime = null;
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _activeRideSamples.clear();
    _rideSessionId = null;
    _rideDistanceKm = 0.0;
    _maxSpeedKmh = 0.0;
    _averageSpeedKmh = 0.0;
    _lastSpeedPosition = null;
    _lastSpeedTimestamp = null;
    _lastLocationUpdateAt = null;
    _filteredSpeedKmh = 0.0;
    _stationaryFixStreak = 0;
    _forceNotifyUi();
  }

  String _extractFileName(String path) {
    final parts = path.split(Platform.pathSeparator);
    if (parts.isEmpty) {
      return path;
    }
    return parts.last;
  }

  String _buildRideSessionId(DateTime startTime) {
    final timestamp = startTime.toUtc().millisecondsSinceEpoch;
    final random = DateTime.now().microsecondsSinceEpoch % 1000000;
    return '${timestamp}_$random';
  }

  List<String> _normalizeSegmentPaths({
    required List<String>? segmentPaths,
    required String fallbackVideoPath,
  }) {
    final ordered = <String>[];
    final seen = <String>{};

    for (final rawPath in segmentPaths ?? const <String>[]) {
      final path = rawPath.trim();
      if (path.isEmpty || !seen.add(path)) {
        continue;
      }
      ordered.add(path);
    }

    if (fallbackVideoPath.isNotEmpty && seen.add(fallbackVideoPath)) {
      ordered.add(fallbackVideoPath);
    }

    return ordered;
  }

  List<String> _normalizeLockedPaths({
    required List<String>? lockedSegmentPaths,
    required List<String> knownSegmentPaths,
  }) {
    final knownSet = knownSegmentPaths.toSet();
    final ordered = <String>[];
    final seen = <String>{};

    for (final rawPath in lockedSegmentPaths ?? const <String>[]) {
      final path = rawPath.trim();
      if (path.isEmpty || !knownSet.contains(path) || !seen.add(path)) {
        continue;
      }
      ordered.add(path);
    }

    return ordered;
  }

  List<Map<String, dynamic>> _normalizeSegmentTimeline({
    required List<Map<String, dynamic>>? segmentTimeline,
    required List<String> knownSegmentPaths,
  }) {
    final knownSet = knownSegmentPaths.toSet();
    final normalized = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final entry in segmentTimeline ?? const <Map<String, dynamic>>[]) {
      final path = (entry['path']?.toString() ?? '').trim();
      if (path.isEmpty || !knownSet.contains(path) || !seen.add(path)) {
        continue;
      }

      final startMs = (entry['startMs'] as num?)?.toInt() ?? 0;
      final endMs = (entry['endMs'] as num?)?.toInt() ?? startMs;
      final normalizedStartMs = startMs < 0 ? 0 : startMs;
      final normalizedEndMs = endMs >= normalizedStartMs
          ? endMs
          : normalizedStartMs;

      normalized.add({
        'path': path,
        'startMs': normalizedStartMs,
        'endMs': normalizedEndMs,
      });
    }

    normalized.sort((a, b) {
      final aStart = (a['startMs'] as int?) ?? 0;
      final bStart = (b['startMs'] as int?) ?? 0;
      return aStart.compareTo(bStart);
    });

    return normalized;
  }

  List<String> _filterPathsInDirectory({
    required List<String> paths,
    required String directoryPath,
  }) {
    if (directoryPath.trim().isEmpty) {
      return List<String>.from(paths);
    }

    final filtered = <String>[];
    for (final path in paths) {
      if (_isPathInsideDirectory(path, directoryPath)) {
        filtered.add(path);
      }
    }
    return filtered;
  }

  Future<List<String>> _filterExistingPathsInOrder({
    required List<String> paths,
  }) async {
    final existing = <String>[];
    for (final path in paths) {
      if (await File(path).exists()) {
        existing.add(path);
      } else {
        debugPrint('Telemetry: dropping missing segment path $path');
      }
    }
    return existing;
  }

  Future<void> _writeTelemetryAtomically({
    required String telemetryPath,
    required Map<String, dynamic> payload,
  }) async {
    final telemetryFile = File(telemetryPath);
    final encodedPayload = jsonEncode(payload);
    await integrity_utils.writeTelemetryAtomically(
      telemetryFile: telemetryFile,
      content: encodedPayload,
    );
  }

  // Path utilities delegate to shared module.
  bool _isPathInsideDirectory(String filePath, String directoryPath) =>
      path_utils.isPathInsideDirectory(filePath, directoryPath);

  Map<String, dynamic> _normalizeRecordingSettings(
    Map<String, dynamic>? settings,
  ) {
    final source = settings ?? const <String, dynamic>{};
    final normalized = <String, dynamic>{};

    for (final entry in source.entries) {
      final key = entry.key.trim();
      if (key.isEmpty) {
        continue;
      }

      final value = entry.value;
      if (value == null ||
          value is num ||
          value is bool ||
          value is String) {
        normalized[key] = value;
        continue;
      }

      normalized[key] = value.toString();
    }

    return normalized;
  }

  Future<Map<String, dynamic>> _buildIntegrityMetadata({
    required Map<String, dynamic> payload,
    required List<String> segmentPaths,
  }) async {
    final segmentHashes = <String, String>{};
    for (final segmentPath in segmentPaths) {
      final hash = await _hashFileSha256(segmentPath);
      if (hash == null) {
        continue;
      }
      segmentHashes[segmentPath] = hash;
    }

    return {
      'algo': 'sha256',
      'payloadHash': _hashJsonCanonical(payload),
      'segmentCount': segmentPaths.length,
      'hashedSegmentCount': segmentHashes.length,
      'segmentHashes': segmentHashes,
      'generatedAt': DateTime.now().toIso8601String(),
    };
  }

  String _hashJsonCanonical(Map<String, dynamic> payload) =>
      integrity_utils.hashJsonCanonical(payload);

  Future<String?> _hashFileSha256(String path) =>
      integrity_utils.hashFileSha256(path);

  String _buildPrimaryTelemetryPath({
    required String rideSessionId,
    required String canonicalVideoPath,
    required List<String> segmentPaths,
  }) {
    String? directoryPath;
    if (segmentPaths.isNotEmpty) {
      directoryPath = File(segmentPaths.first).parent.path;
    } else if (canonicalVideoPath.isNotEmpty) {
      directoryPath = File(canonicalVideoPath).parent.path;
    }

    final safeSessionId =
        rideSessionId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final fileName = 'ride_$safeSessionId.telemetry.json';

    if (directoryPath == null || directoryPath.isEmpty) {
      return fileName;
    }
    return '$directoryPath${Platform.pathSeparator}$fileName';
  }

  void _detectCrash(double gForce) {
    final now = DateTime.now();
    if (_lastIncidentDetectedAt != null &&
        now.difference(_lastIncidentDetectedAt!) < _incidentDebounce) {
      return;
    }

    _lastIncidentDetectedAt = now;
    _lastIncidentGForce = gForce;
    _incidentCount++;
    _forceNotifyUi();
  }

  void clearHistory() {
    _telemetryHistory.clear();
    _activeRideSamples.clear();
    _rideDistanceKm = 0.0;
    _maxSpeedKmh = 0.0;
    _averageSpeedKmh = 0.0;
    _lastSpeedPosition = null;
    _lastSpeedTimestamp = null;
    _lastLocationUpdateAt = null;
    _filteredSpeedKmh = 0.0;
    _stationaryFixStreak = 0;
    _forceNotifyUi();
  }

  void _notifyUiIfNeeded() {
    final now = DateTime.now();
    if (_lastUiNotifyAt != null &&
        now.difference(_lastUiNotifyAt!) < _uiNotifyMinInterval) {
      return;
    }

    _lastUiNotifyAt = now;
    notifyListeners();
  }

  void _forceNotifyUi() {
    _lastUiNotifyAt = DateTime.now();
    notifyListeners();
  }

  @override
  void dispose() {
    _sampleTimer?.cancel();
    _locationPollTimer?.cancel();
    _accelerometerSubscription?.cancel();
    _positionSubscription?.cancel();
    super.dispose();
  }
}
