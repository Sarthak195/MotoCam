// lib/features/telemetry/providers/telemetry_provider.dart

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../models/telemetry_data.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

class TelemetryProvider extends ChangeNotifier {
  TelemetryProvider({this.sampleInterval = const Duration(seconds: 1)});

  final Duration sampleInterval;
  TelemetryData _currentData = TelemetryData.empty();
  final List<TelemetryData> _telemetryHistory = [];
  final List<TelemetryData> _activeRideSamples = [];

  StreamSubscription<UserAccelerometerEvent>? _accelerometerSubscription;
  StreamSubscription<Position>? _positionSubscription;
  Timer? _sampleTimer;
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
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    );

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(_updateLocation);
  }

  void _updateLocation(Position position) {
    _currentData = _currentData.copyWith(
      latitude: position.latitude,
      longitude: position.longitude,
      speed: position.speed * 3.6, // m/s to km/h
      bearing: position.heading,
      timestamp: DateTime.now(),
      distanceKm: _rideDistanceKm,
    );

    if (_isRideActive && _lastRidePosition != null) {
      final meters = Geolocator.distanceBetween(
        _lastRidePosition!.latitude,
        _lastRidePosition!.longitude,
        position.latitude,
        position.longitude,
      );

      if (meters > 0) {
        _rideDistanceKm += (meters / 1000);
      }
    }

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
    _rideDistanceKm = 0.0;
    _maxSpeedKmh = 0.0;
    _averageSpeedKmh = 0.0;
    _lastIncidentDetectedAt = null;
    _lastIncidentGForce = 0.0;
    _incidentCount = 0;
    _smoothedLinearAccelerationG = 0.0;
    _consecutiveIncidentHits = 0;
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
  }) async {
    if (!_isRideActive ||
        _rideStartTime == null ||
        _activeRideSamples.isEmpty) {
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

    final resolvedSegmentPaths =
        (segmentPaths ?? const <String>[]).where((p) => p.isNotEmpty).toList();
    if (!resolvedSegmentPaths.contains(videoPath)) {
      resolvedSegmentPaths.add(videoPath);
    }
    final resolvedLockedPaths = (lockedSegmentPaths ?? const <String>[])
        .where((p) => p.isNotEmpty)
        .toList();

    final telemetryPayload = {
      'schemaVersion': 2,
      'sampleRateMs': sampleInterval.inMilliseconds,
      'videoPath': videoPath,
      'videoFileName': _extractFileName(videoPath),
      'segmentPaths': resolvedSegmentPaths,
      'lockedSegmentPaths': resolvedLockedPaths,
      'startedAt': rideStart.toIso8601String(),
      'endedAt': rideEnd.toIso8601String(),
      'distanceKm': _rideDistanceKm,
      'maxSpeedKmh': _maxSpeedKmh,
      'averageSpeedKmh': _averageSpeedKmh,
      'samples': _activeRideSamples.map((sample) => sample.toJson()).toList(),
    };

    final String telemetryPath = _telemetryPathForVideo(videoPath);
    final telemetryFile = File(telemetryPath);
    await telemetryFile.writeAsString(jsonEncode(telemetryPayload));

    _activeRideSamples.clear();
    _forceNotifyUi();
    return telemetryPath;
  }

  void cancelRideSession() {
    _isRideActive = false;
    _rideStartTime = null;
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _activeRideSamples.clear();
    _rideDistanceKm = 0.0;
    _maxSpeedKmh = 0.0;
    _averageSpeedKmh = 0.0;
    _forceNotifyUi();
  }

  String _extractFileName(String path) {
    final parts = path.split(Platform.pathSeparator);
    if (parts.isEmpty) {
      return path;
    }
    return parts.last;
  }

  String _telemetryPathForVideo(String videoPath) {
    final int dotIndex = videoPath.lastIndexOf('.');
    if (dotIndex <= 0) {
      return '$videoPath.telemetry.json';
    }
    return '${videoPath.substring(0, dotIndex)}.telemetry.json';
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
    _accelerometerSubscription?.cancel();
    _positionSubscription?.cancel();
    super.dispose();
  }
}
