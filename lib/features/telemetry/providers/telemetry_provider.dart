// lib/features/telemetry/providers/telemetry_provider.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../../../core/ride_file/ride_telemetry_codec.dart' as ride_codec;
import '../../../core/services/ride_signing_service.dart';
import '../../../core/utils/integrity_utils.dart' as integrity_utils;
import '../../../core/utils/path_utils.dart' as path_utils;
import '../crash_debug_log.dart';
import '../crash_detector.dart';
import '../models/telemetry_data.dart';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

/// Collects and manages real-time ride telemetry (GPS, speed, acceleration)
/// and persists ride sessions as JSON alongside video segments.
///
/// Sensors run between [initialize] and [pauseTracking] (or [dispose]). While
/// no ride is active they are also paused automatically when the app goes to
/// the background and resumed when it returns.
///
/// A ride's JSON file is written as a checkpoint (`sessionComplete: false`)
/// whenever [checkpointRideSession] is called and periodically afterwards,
/// and completed by [stopRideSessionAndPersist]. Every write is sealed with
/// a bound integrity envelope over the segments hashed so far; the final
/// save is also signed with this phone's key when it can be (envelope
/// version 3, see `ride_signature.dart`).
class TelemetryProvider extends ChangeNotifier with WidgetsBindingObserver {
  /// Creates a provider that captures one ride sample every [sampleInterval].
  ///
  /// [rideSigner] signs the final save (default: this phone's Keystore key
  /// through [RideSigningService.instance]; `null` from it means the ride
  /// is saved unsigned), and [signedRideRegistry] records each ride saved
  /// signed (default: [SignedRideRegistry.instance]). [clock] is the wall
  /// clock of incident detection (default [DateTime.now]); tests pass a
  /// synthetic one that follows their sensor timestamps.
  ///
  /// [crashDebugLogEnabled] (default [kDebugMode], except under `flutter
  /// test`, so tests that do not ask for it stay hermetic) turns on the per-ride
  /// crash-detector event log (see [CrashDebugLog]); release builds never
  /// write it. [crashDebugDirectory] resolves the directory it is written
  /// under (default: the app's private files directory).
  TelemetryProvider({
    this.sampleInterval = const Duration(seconds: 1),
    ride_codec.RidePayloadSigner? rideSigner,
    SignedRideRegistry? signedRideRegistry,
    DateTime Function()? clock,
    bool? crashDebugLogEnabled,
    Future<Directory> Function()? crashDebugDirectory,
  }) : _crashDebugLogEnabled =
           crashDebugLogEnabled ??
           (kDebugMode && !Platform.environment.containsKey('FLUTTER_TEST')),
       _crashDebugDirectory =
           crashDebugDirectory ?? getApplicationSupportDirectory,
       _rideSigner = rideSigner ?? RideSigningService.instance.signPayloadHash,
       _signedRideRegistry = signedRideRegistry ?? SignedRideRegistry.instance,
       _clock = clock ?? DateTime.now;

  /// Interval between persisted ride samples.
  final Duration sampleInterval;

  final ride_codec.RidePayloadSigner _rideSigner;
  final SignedRideRegistry _signedRideRegistry;
  final DateTime Function() _clock;
  final bool _crashDebugLogEnabled;
  final Future<Directory> Function() _crashDebugDirectory;
  CrashDebugLog? _crashDebugLog;
  Future<void> _crashDebugLogClosed = Future<void>.value();

  /// Version of the ride JSON written by this provider. Every version-3 file,
  /// checkpoints included, carries a bound integrity envelope
  /// (`ride_codec.buildIntegrityEnvelope`), so readers treat a missing
  /// envelope on a completed ride (`sessionComplete` not `false`) as
  /// modified.
  static const int rideSchemaVersion = ride_codec.rideFileSchemaVersion;

  /// Fixes older than this are saved with `hasFix: false`.
  static const Duration maxFixAge = Duration(seconds: 5);

  /// Fixes with a reported horizontal accuracy worse than this (metres) never
  /// add ride distance.
  static const double maxDistanceAccuracyMeters = 25.0;

  /// Minimum displacement (metres) from the last distance anchor before a fix
  /// adds ride distance, unless GPS speed shows motion.
  static const double minDistanceStepMeters = 3.0;

  /// Implied speeds above this (km/h) between the distance anchor and a fix
  /// are treated as GPS jumps and never add ride distance.
  static const double maxPlausibleSpeedKmh = 350.0;

  static const Duration _accelerometerSamplingPeriod =
      SensorInterval.gameInterval;
  // The raw accelerometer only feeds the tip-over check (gravity direction),
  // which a low-pass with a 500 ms time constant follows; 15 Hz is plenty.
  static const Duration _orientationSamplingPeriod = SensorInterval.uiInterval;
  // Gravity low-pass time constant for the raw-accelerometer fallback; equal
  // to the classic alpha 0.8 at the 200 ms default sensor rate.
  static const Duration _gravityFilterTimeConstant = Duration(
    milliseconds: 800,
  );
  static const Duration _checkpointInterval = Duration(seconds: 30);
  static const Duration _minFallbackPollBackoff = Duration(seconds: 2);
  static const Duration _maxFallbackPollBackoff = Duration(seconds: 30);

  TelemetryData _currentData = TelemetryData.empty();
  final List<TelemetryData> _activeRideSamples = [];
  final List<Map<String, dynamic>> _rideIncidents = [];

  StreamSubscription<dynamic>? _accelerometerSubscription;
  StreamSubscription<AccelerometerEvent>? _orientationSubscription;
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<ServiceStatus>? _serviceStatusSubscription;
  Timer? _sampleTimer;
  Timer? _locationPollTimer;
  Timer? _checkpointTimer;
  DateTime? _rideStartTime;
  Position? _lastRidePosition;
  bool _isTrackingStarted = false;
  bool _isObservingLifecycle = false;
  bool _isPausedForBackground = false;
  AppLifecycleState? _lifecycleState;
  bool _isRideActive = false;
  double _rideDistanceKm = 0.0;
  double _maxSpeedKmh = 0.0;
  double _averageSpeedKmh = 0.0;
  double _fixSampleSpeedSum = 0.0;
  int _fixSampleCount = 0;
  double _incidentTriggerGForce = 3.5;
  final CrashDetector _crashDetector = CrashDetector(
    log: (message) => debugPrint('Telemetry: $message'),
  );
  DateTime? _lastIncidentDetectedAt;
  int? _lastIncidentJoltElapsedMs;
  double _lastIncidentGForce = 0.0;
  int _incidentCount = 0;
  DateTime? _lastUiNotifyAt;
  Timer? _trailingUiNotify;
  Duration _uiNotifyMinInterval = const Duration(milliseconds: 100);
  double _smoothedLinearAccelerationG = 0.0;
  bool _hasSmoothedAcceleration = false;
  // The latest accelerometer event time and the wall clock when it arrived:
  // GPS speed updates are stamped in the accelerometer's time base.
  DateTime? _lastSensorSampleAt;
  DateTime? _lastSensorSampleWallAt;
  bool _isUsingGravityFallback = false;
  bool _isIncidentDetectionAvailable = true;
  List<double>? _gravityEstimate;
  DateTime? _lastRawAccelerationAt;
  Position? _lastSpeedPosition;
  DateTime? _lastSpeedTimestamp;
  DateTime? _lastLocationUpdateAt;
  DateTime? _lastFixTimestamp;
  DateTime? _lastFixReceivedAt;
  double _filteredSpeedKmh = 0.0;
  int _stationaryFixStreak = 0;
  bool _isFallbackPolling = false;
  bool _isLocationServiceEnabled = true;
  Duration _fallbackPollBackoff = _minFallbackPollBackoff;
  DateTime? _nextFallbackPollAt;
  bool _mockLocationDetected = false;
  String? _rideSessionId;
  String? _rideTelemetryPath;
  ride_codec.RideFileInput? _checkpointInput;
  Future<void>? _pendingWrite;
  Future<void>? _pendingPrehash;
  final Map<String, _CachedSegmentHash> _segmentHashCache = {};
  int _activePersistCount = 0;
  bool _isRetryingPersist = false;
  String? _lastPersistError;
  // Failed saves, oldest first. A later ride's save never discards them.
  final List<Future<String?> Function()> _pendingPersists = [];
  int _checkpointSequence = 0;
  int _lastQueuedCheckpointSequence = 0;

  /// The latest live telemetry values (position, speed, acceleration).
  TelemetryData get currentData => _currentData;

  /// Samples captured so far in the active ride (empty when no ride runs).
  /// Only tests read it.
  @visibleForTesting
  List<TelemetryData> get activeRideSamples =>
      List.unmodifiable(_activeRideSamples);

  /// Incident records of the active ride, as they will be saved. Only tests
  /// read it.
  @visibleForTesting
  List<Map<String, dynamic>> get activeRideIncidentsForTesting =>
      List.unmodifiable(_rideIncidents);

  /// Whether a ride session is currently capturing samples.
  bool get isRideActive => _isRideActive;

  /// Distance travelled in the active ride, in km. Kept after a stop until
  /// the next [startRideSession]; reset by [cancelRideSession].
  double get rideDistanceKm => _rideDistanceKm;

  /// Highest speed among the active ride's samples that had a GPS fix, in
  /// km/h. Kept after a stop like [rideDistanceKm].
  double get maxSpeedKmh => _maxSpeedKmh;

  /// Mean speed of the active ride's samples that had a GPS fix, in km/h.
  /// Kept after a stop like [rideDistanceKm].
  double get averageSpeedKmh => _averageSpeedKmh;

  /// When the most recent incident was confirmed (wall clock), or `null` if
  /// none. Changes once per incident, at its confirmation, which comes up to
  /// [CrashDetector.confirmWindow] after the jolt.
  DateTime? get lastIncidentDetectedAt => _lastIncidentDetectedAt;

  /// `elapsedMs` of the most recent incident's jolt (ms since the ride
  /// start, as saved in the ride JSON), or `null` when it was not recorded
  /// during a ride. The incident lock uses it to keep the segments around
  /// the jolt, not just around the confirmation.
  int? get lastIncidentJoltElapsedMs => _lastIncidentJoltElapsedMs;

  /// Peak raw linear acceleration (g) of the most recent incident's jolt.
  /// Only tests read it.
  @visibleForTesting
  double get lastIncidentGForce => _lastIncidentGForce;

  /// Number of incidents detected since the last [startRideSession] (or
  /// since launch). Detection also runs between rides, but only incidents
  /// during a ride are saved. Only tests read it.
  @visibleForTesting
  int get incidentCount => _incidentCount;

  /// Whether the GPS/accelerometer subscriptions are currently running.
  bool get isTracking => _isTrackingStarted;

  /// Whether device location services were last reported as enabled.
  bool get isLocationServiceEnabled => _isLocationServiceEnabled;

  /// Whether an accelerometer source is available for incident detection.
  ///
  /// `false` when neither the linear-acceleration sensor nor the raw
  /// accelerometer could be opened; incidents are then never detected.
  bool get isIncidentDetectionAvailable => _isIncidentDetectionAvailable;

  /// Whether any fix in the active ride came from a mock location provider.
  /// Only tests read it.
  @visibleForTesting
  bool get mockLocationDetected => _mockLocationDetected;

  /// Whether a ride save ([stopRideSessionAndPersist] or
  /// [retryPendingPersist]) is still hashing or writing.
  bool get isPersistingRide => _activePersistCount > 0;

  /// The error of the last failed ride save, or `null` once no failed save
  /// is pending. Failed saves can be retried with [retryPendingPersist].
  String? get lastPersistError => _lastPersistError;

  /// The `rideSessionId` of the ride being recorded, from
  /// [startRideSession] until the ride is saved or cancelled; `null`
  /// otherwise.
  String? get rideSessionId => _rideSessionId;

  /// Whether one or more failed ride saves are waiting for
  /// [retryPendingPersist]. Only tests read it.
  @visibleForTesting
  bool get hasPendingPersist => _pendingPersists.isNotEmpty;

  /// Sets how often throttled telemetry updates notify listeners
  /// (clamped to 100–1000 ms) and notifies listeners once.
  void setSpeedUiRefreshInterval(Duration interval) {
    final clampedMs = interval.inMilliseconds.clamp(100, 1000);
    _uiNotifyMinInterval = Duration(milliseconds: clampedMs);
    _lastUiNotifyAt = null;
    _forceNotifyUi();
  }

  /// Sets the incident trigger: a jolt whose filtered linear acceleration
  /// reaches [triggerGForce] g (see [CrashDetector]) starts a candidate that
  /// becomes an incident only if it is confirmed, with at least [debounce]
  /// between an incident's confirmation and the next jolt.
  void setIncidentDetectionConfig({
    required double triggerGForce,
    required Duration debounce,
  }) {
    _incidentTriggerGForce = triggerGForce;
    _crashDetector.configure(triggerG: triggerGForce, debounce: debounce);
  }

  /// Requests location permission if needed and starts GPS and accelerometer
  /// tracking. Does nothing when tracking already runs, location services are
  /// off, or permission is denied. Also resumes tracking after
  /// [pauseTracking].
  Future<void> initialize() async {
    if (_isTrackingStarted) {
      return;
    }

    final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _isLocationServiceEnabled = false;
      return;
    }
    _isLocationServiceEnabled = true;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    if (_isTrackingStarted) {
      return;
    }
    _isPausedForBackground = false;
    _startTracking();
  }

  /// Stops GPS, accelerometer and fallback polling while no ride is active,
  /// e.g. while Ride History or playback is shown. Ignored during a ride.
  /// Call [initialize] to resume.
  void pauseTracking() {
    if (_isRideActive) {
      return;
    }
    _isPausedForBackground = false;
    _stopTracking();
  }

  void _startTracking() {
    _isTrackingStarted = true;
    if (!_isObservingLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _isObservingLifecycle = true;
    }
    _startAccelerometerTracking();
    _startLocationTracking();
  }

  void _stopTracking() {
    if (!_isTrackingStarted) {
      return;
    }
    _isTrackingStarted = false;
    _locationPollTimer?.cancel();
    _locationPollTimer = null;
    unawaited(_accelerometerSubscription?.cancel());
    _accelerometerSubscription = null;
    unawaited(_orientationSubscription?.cancel());
    _orientationSubscription = null;
    unawaited(_positionSubscription?.cancel());
    _positionSubscription = null;
    unawaited(_serviceStatusSubscription?.cancel());
    _serviceStatusSubscription = null;
    _crashDetector.reset(clearSignals: true);
    _lastSensorSampleAt = null;
    _lastSensorSampleWallAt = null;
  }

  /// Pauses tracking when the app leaves the foreground with no active ride,
  /// and resumes it on return if this observer paused it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (_isBackgroundState(state)) {
      _pauseIfIdleInBackground();
      return;
    }

    if (state == AppLifecycleState.resumed && _isPausedForBackground) {
      _isPausedForBackground = false;
      unawaited(_resumeAfterBackground());
    }
  }

  static bool _isBackgroundState(AppLifecycleState? state) =>
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.detached;

  void _pauseIfIdleInBackground() {
    if (_isRideActive ||
        !_isTrackingStarted ||
        !_isBackgroundState(_lifecycleState)) {
      return;
    }
    _isPausedForBackground = true;
    _stopTracking();
  }

  Future<void> _resumeAfterBackground() async {
    if (_isTrackingStarted) {
      return;
    }
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      _isLocationServiceEnabled = await Geolocator.isLocationServiceEnabled();
    } catch (error) {
      debugPrint('Telemetry: resume check failed: $error');
      return;
    }
    if (_isTrackingStarted || _isBackgroundState(_lifecycleState)) {
      return;
    }
    _startTracking();
    // The location-service flag may have changed while paused (the rider
    // switched Location off in Settings); show it without waiting for a fix.
    _forceNotifyUi();
  }

  LocationSettings _buildLocationSettings({Duration? timeLimit}) {
    if (Platform.isAndroid) {
      // forceLocationManager avoids the Google Play services Fused client,
      // whose settings check raises "turn on location" dialogs on every
      // request. On API 31+ the LocationManager path still picks the
      // platform's own fused provider (geolocator_android determineProvider),
      // so fixes may come from network as well as GPS.
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(milliseconds: 500),
        forceLocationManager: true,
        timeLimit: timeLimit,
      );
    }
    return LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      timeLimit: timeLimit,
    );
  }

  void _startLocationTracking() {
    _subscribePositionStream();

    unawaited(_serviceStatusSubscription?.cancel());
    try {
      _serviceStatusSubscription = Geolocator.getServiceStatusStream().listen(
        _onServiceStatusChanged,
        onError: (Object error) {
          debugPrint('Telemetry: service status stream error: $error');
        },
      );
    } catch (error) {
      // Not supported on every platform; polling still detects outages.
      debugPrint('Telemetry: service status stream unavailable: $error');
    }

    _resetFallbackBackoff();
    _locationPollTimer?.cancel();
    _locationPollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_pollLocationIfStale());
    });
  }

  void _subscribePositionStream() {
    unawaited(_positionSubscription?.cancel());
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: _buildLocationSettings(),
    ).listen(_updateLocation, onError: _onPositionStreamError);
  }

  void _onPositionStreamError(Object error) {
    debugPrint('Telemetry: position stream error: $error');
    if (error is LocationServiceDisabledException) {
      // The platform removed its updates; the service-status listener
      // re-subscribes when location is switched back on.
      unawaited(_positionSubscription?.cancel());
      _positionSubscription = null;
      _setLocationServiceEnabled(false);
    }
  }

  void _onServiceStatusChanged(ServiceStatus status) {
    final enabled = status == ServiceStatus.enabled;
    final wasEnabled = _isLocationServiceEnabled;
    _setLocationServiceEnabled(enabled);
    if (!_isTrackingStarted) {
      return;
    }

    if (!enabled) {
      unawaited(_positionSubscription?.cancel());
      _positionSubscription = null;
      return;
    }

    if (!wasEnabled || _positionSubscription == null) {
      _resetFallbackBackoff();
      _subscribePositionStream();
    }
  }

  void _setLocationServiceEnabled(bool enabled) {
    if (_isLocationServiceEnabled == enabled) {
      return;
    }
    _isLocationServiceEnabled = enabled;
    _forceNotifyUi();
  }

  void _resetFallbackBackoff() {
    _fallbackPollBackoff = _minFallbackPollBackoff;
    _nextFallbackPollAt = null;
  }

  Future<void> _pollLocationIfStale() async {
    if (_isFallbackPolling || !_isLocationServiceEnabled) {
      return;
    }

    final now = DateTime.now();
    final lastUpdate = _lastLocationUpdateAt;
    if (lastUpdate != null &&
        now.difference(lastUpdate) < const Duration(seconds: 2)) {
      return;
    }
    final nextPollAt = _nextFallbackPollAt;
    if (nextPollAt != null && now.isBefore(nextPollAt)) {
      return;
    }

    _isFallbackPolling = true;
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: _buildLocationSettings(
          timeLimit: const Duration(seconds: 2),
        ),
      );
      if (_isTrackingStarted) {
        _updateLocation(position);
      }
      _resetFallbackBackoff();
    } catch (error) {
      // Best-effort fallback polling only; back off while no fix arrives.
      if (error is LocationServiceDisabledException) {
        _setLocationServiceEnabled(false);
      }
      _nextFallbackPollAt = DateTime.now().add(_fallbackPollBackoff);
      final doubledMs = _fallbackPollBackoff.inMilliseconds * 2;
      _fallbackPollBackoff = Duration(
        milliseconds: math.min(
          doubledMs,
          _maxFallbackPollBackoff.inMilliseconds,
        ),
      );
    } finally {
      _isFallbackPolling = false;
    }
  }

  /// Returns whether a fix should add the displacement [meters] (measured
  /// from the distance anchor) to the ride distance.
  ///
  /// A fix counts only when it is newer than the anchor, its reported
  /// accuracy is known to be at most [maxDistanceAccuracyMeters] (a value
  /// `<= 0` means unknown and is accepted), the implied speed is plausible
  /// (at most [maxPlausibleSpeedKmh]) and it moved at least the noise floor
  /// (`max(minDistanceStepMeters, accuracy)`) or GPS speed is at least
  /// 2 km/h.
  @visibleForTesting
  static bool shouldAccumulateDistance({
    required double meters,
    required double accuracyMeters,
    required double gpsSpeedKmh,
    required DateTime fixTimestamp,
    required DateTime anchorTimestamp,
  }) {
    if (!meters.isFinite || meters <= 0) {
      return false;
    }
    if (!fixTimestamp.isAfter(anchorTimestamp)) {
      return false;
    }
    if (accuracyMeters.isFinite && accuracyMeters > maxDistanceAccuracyMeters) {
      return false;
    }

    final dtSeconds =
        fixTimestamp.difference(anchorTimestamp).inMilliseconds / 1000.0;
    if (dtSeconds > 0 && (meters / dtSeconds) * 3.6 > maxPlausibleSpeedKmh) {
      return false;
    }

    final accuracyFloor = accuracyMeters.isFinite && accuracyMeters > 0
        ? accuracyMeters
        : 0.0;
    final noiseFloor = math.max(minDistanceStepMeters, accuracyFloor);
    return meters >= noiseFloor || gpsSpeedKmh >= 2.0;
  }

  void _updateLocation(Position position) {
    if (!position.latitude.isFinite || !position.longitude.isFinite) {
      return;
    }

    if (_isRideActive &&
        _rideStartTime != null &&
        position.timestamp.isBefore(_rideStartTime!)) {
      return;
    }

    // Drop fixes that are not newer than the last accepted one, e.g. a
    // fallback poll answering with an older fix than the stream delivered.
    // A jump back of more than a minute is treated as a clock correction.
    final lastFixTimestamp = _lastFixTimestamp;
    final isNotNewer =
        lastFixTimestamp != null &&
        !position.timestamp.isAfter(lastFixTimestamp);
    if (isNotNewer &&
        lastFixTimestamp.difference(position.timestamp) <
            const Duration(minutes: 1)) {
      return;
    }
    final clockJumpedBack = isNotNewer;

    final now = DateTime.now();
    _lastLocationUpdateAt = now;
    _lastFixReceivedAt = now;
    _lastFixTimestamp = position.timestamp;
    if (_isRideActive && position.isMocked) {
      _mockLocationDetected = true;
    }

    var gpsSpeedKmh = position.speed * 3.6; // m/s to km/h
    if (gpsSpeedKmh.isNaN || gpsSpeedKmh.isInfinite || gpsSpeedKmh < 0) {
      gpsSpeedKmh = 0;
    }

    double displacementSpeedKmh = 0.0;
    var movedMeters = 0.0;
    if (_lastSpeedPosition != null && _lastSpeedTimestamp != null) {
      final dtSeconds =
          now
              .difference(_lastSpeedTimestamp!)
              .inMilliseconds
              .clamp(250, 10000) /
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
    final movementNoiseMeters = (position.accuracy * 0.25)
        .clamp(0.8, 2.5)
        .toDouble();
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
    if (!candidateSpeedKmh.isFinite) {
      candidateSpeedKmh = 0;
    }

    // Use faster decay than rise to reflect braking quickly while keeping
    // launch smooth.
    final alpha = candidateSpeedKmh < _filteredSpeedKmh ? 0.60 : 0.32;
    _filteredSpeedKmh = _filteredSpeedKmh == 0
        ? candidateSpeedKmh
        : (_filteredSpeedKmh * (1.0 - alpha)) + (candidateSpeedKmh * alpha);

    if (_filteredSpeedKmh < 0.6 || _stationaryFixStreak >= 6) {
      _filteredSpeedKmh = 0;
    }
    final detectorSpeedKmh = _crashDetectorSpeedKmh(
      position,
      _filteredSpeedKmh,
    );
    final detectorSpeedAt = _sensorTimeNow();
    _crashDebugLog?.noteFix(
      detectorSpeedAt,
      GpsSpeedFix(
        rawSpeedKmh: position.speed * 3.6,
        speedAccuracyMps: position.speedAccuracy,
        hasSpeed: position.hasSpeed,
        hasSpeedAccuracy: position.hasSpeedAccuracy,
        fedKmh: detectorSpeedKmh,
        fedRaw: _isCrashSpeedTrusted(position),
      ),
    );
    final confirmed = _crashDetector.addSpeed(
      detectorSpeedKmh,
      detectorSpeedAt,
    );

    _lastSpeedPosition = position;
    _lastSpeedTimestamp = now;

    // _lastRidePosition is the distance anchor: it only advances when a fix
    // is accepted, so jitter around a stationary point never accumulates.
    if (_isRideActive) {
      final anchor = _lastRidePosition;
      if (anchor == null || clockJumpedBack) {
        // Start (or, after a clock correction, restart) the anchor only from
        // a fix accurate enough to measure from; a wild first fix would
        // otherwise be added to the distance once the rider moves away.
        final accuracy = position.accuracy;
        _lastRidePosition =
            !accuracy.isFinite || accuracy <= maxDistanceAccuracyMeters
            ? position
            : null;
      } else {
        final meters = Geolocator.distanceBetween(
          anchor.latitude,
          anchor.longitude,
          position.latitude,
          position.longitude,
        );
        if (shouldAccumulateDistance(
          meters: meters,
          accuracyMeters: position.accuracy,
          gpsSpeedKmh: gpsSpeedKmh,
          fixTimestamp: position.timestamp,
          anchorTimestamp: anchor.timestamp,
        )) {
          _rideDistanceKm += meters / 1000;
          _lastRidePosition = position;
        }
      }
    }

    final heading = position.heading;
    _currentData = _currentData.copyWith(
      latitude: position.latitude,
      longitude: position.longitude,
      speed: _filteredSpeedKmh,
      // A negative or non-finite heading means no course; keep the last one.
      bearing: heading.isFinite && heading >= 0 ? heading % 360 : null,
      timestamp: now,
      distanceKm: _rideDistanceKm,
      hasFix: true,
    );

    if (confirmed != null) {
      _detectCrash(confirmed);
    }
    _notifyUiIfNeeded();
  }

  // The speed the crash detector gets for one fix: the receiver's own speed,
  // not the filtered speed the HUD shows and the ride saves. The filter
  // falls by 60 percent per fix, so after an instant stop it needs two fixes
  // to fall below CrashDetector.nearStopSpeedKmh from 20 to 49 km/h and
  // three from 50 to 124 km/h, which would use up the detector's allowance
  // for the receiver's lag. The pre-jolt speed comes from the same source:
  // the stop deadline is the time this signal takes to fall, and the
  // filter's slow rise (32 percent per fix) under-reads while accelerating.
  // A fix whose speed cannot be trusted gets the filtered value instead, so
  // its worst case is the filter's delay, never a false stop: a speed that
  // is not finite, negative (unavailable) or implausibly high, and
  // 0 with no speed accuracy (Android maps a fix without speed to 0).
  static double _crashDetectorSpeedKmh(
    Position position,
    double filteredSpeedKmh,
  ) {
    return _isCrashSpeedTrusted(position)
        ? position.speed * 3.6
        : filteredSpeedKmh;
  }

  static bool _isCrashSpeedTrusted(Position position) {
    final speedMps = position.speed;
    return speedMps.isFinite &&
        speedMps >= 0 &&
        speedMps * 3.6 <= maxPlausibleSpeedKmh &&
        (speedMps > 0 || position.speedAccuracy > 0);
  }

  // Now, in the accelerometer's time base: the latest event time plus the
  // wall-clock time since it arrived.
  DateTime _sensorTimeNow() {
    final now = _clock();
    final sampleAt = _lastSensorSampleAt;
    final sampleWallAt = _lastSensorSampleWallAt;
    if (sampleAt == null || sampleWallAt == null) {
      return now;
    }
    return sampleAt.add(now.difference(sampleWallAt));
  }

  void _startAccelerometerTracking() {
    unawaited(_accelerometerSubscription?.cancel());
    _isUsingGravityFallback = false;
    _isIncidentDetectionAvailable = true;
    _accelerometerSubscription =
        userAccelerometerEventStream(
          samplingPeriod: _accelerometerSamplingPeriod,
        ).listen((UserAccelerometerEvent event) {
          // userAccelerometer provides linear acceleration (gravity removed).
          _onLinearAcceleration(event.x, event.y, event.z, at: event.timestamp);
        }, onError: _onLinearAccelerationStreamError);
    _startOrientationTracking();
  }

  // The tip-over check needs the direction of gravity, which the
  // linear-acceleration stream removes, so the raw accelerometer runs too.
  // Without it only the abrupt-stop rule can confirm a jolt.
  void _startOrientationTracking() {
    unawaited(_orientationSubscription?.cancel());
    _orientationSubscription =
        accelerometerEventStream(
          samplingPeriod: _orientationSamplingPeriod,
        ).listen(
          (AccelerometerEvent event) {
            _onOrientationSample(
              event.x,
              event.y,
              event.z,
              at: event.timestamp,
            );
          },
          onError: (Object error) {
            debugPrint('Telemetry: orientation stream unavailable: $error');
            unawaited(_orientationSubscription?.cancel());
            _orientationSubscription = null;
          },
        );
  }

  void _onOrientationSample(double x, double y, double z, {DateTime? at}) {
    final confirmed = _crashDetector.addGravitySample(
      x,
      y,
      z,
      at ?? DateTime.now(),
    );
    if (confirmed != null) {
      _detectCrash(confirmed);
    }
  }

  void _onLinearAccelerationStreamError(Object error) {
    debugPrint('Telemetry: linear acceleration stream error: $error');
    // Android reports a missing sensor as NO_SENSOR; UNAVAILABLE is treated
    // the same.
    if (!_isUsingGravityFallback &&
        error is PlatformException &&
        (error.code == 'NO_SENSOR' || error.code == 'UNAVAILABLE')) {
      _startGravityFilteredAccelerometer();
    }
  }

  /// Fallback for devices without a linear-acceleration sensor: removes
  /// gravity from the raw accelerometer with a low-pass estimate.
  void _startGravityFilteredAccelerometer() {
    unawaited(_accelerometerSubscription?.cancel());
    // The raw stream below feeds the orientation as well.
    unawaited(_orientationSubscription?.cancel());
    _orientationSubscription = null;
    _isUsingGravityFallback = true;
    _gravityEstimate = null;
    _lastRawAccelerationAt = null;
    _accelerometerSubscription =
        accelerometerEventStream(
          samplingPeriod: _accelerometerSamplingPeriod,
        ).listen(
          (AccelerometerEvent event) {
            _onRawAcceleration(event.x, event.y, event.z, at: event.timestamp);
          },
          onError: (Object error) {
            debugPrint('Telemetry: accelerometer unavailable: $error');
            unawaited(_accelerometerSubscription?.cancel());
            _accelerometerSubscription = null;
            _isIncidentDetectionAvailable = false;
            _forceNotifyUi();
          },
        );
    _forceNotifyUi();
  }

  void _onRawAcceleration(double x, double y, double z, {DateTime? at}) {
    if (!x.isFinite || !y.isFinite || !z.isFinite) {
      return;
    }
    final sampleTime = at ?? DateTime.now();
    final previousAt = _lastRawAccelerationAt;
    _lastRawAccelerationAt = sampleTime;
    _onOrientationSample(x, y, z, at: sampleTime);
    final gravity = _gravityEstimate;
    if (gravity == null) {
      _gravityEstimate = <double>[x, y, z];
      return;
    }
    // Low-pass with a fixed time constant rather than a fixed alpha: alpha
    // 0.8 suits the 200 ms default rate, but at the 20 ms game rate it would
    // let the gravity estimate absorb most of an impact within ~100 ms.
    var dtMs = previousAt == null
        ? _accelerometerSamplingPeriod.inMilliseconds
        : sampleTime.difference(previousAt).inMilliseconds;
    if (dtMs <= 0) {
      dtMs = _accelerometerSamplingPeriod.inMilliseconds;
    }
    dtMs = dtMs.clamp(5, 250);
    final tauMs = _gravityFilterTimeConstant.inMilliseconds;
    final gravityAlpha = tauMs / (tauMs + dtMs);
    gravity[0] = gravityAlpha * gravity[0] + (1 - gravityAlpha) * x;
    gravity[1] = gravityAlpha * gravity[1] + (1 - gravityAlpha) * y;
    gravity[2] = gravityAlpha * gravity[2] + (1 - gravityAlpha) * z;
    _onLinearAcceleration(
      x - gravity[0],
      y - gravity[1],
      z - gravity[2],
      at: at,
    );
  }

  /// Handles one linear-acceleration sample (m/s², gravity removed).
  ///
  /// The smoothed value feeds the saved samples and the stationary
  /// heuristic. The raw vector goes to the [CrashDetector], which looks for
  /// a filtered jolt and then waits for its confirmation.
  void _onLinearAcceleration(double x, double y, double z, {DateTime? at}) {
    if (!x.isFinite || !y.isFinite || !z.isFinite) {
      return;
    }
    final sampleTime = at ?? DateTime.now();
    _lastSensorSampleAt = sampleTime;
    _lastSensorSampleWallAt = _clock();
    final double rawLinearAccelerationG =
        math.sqrt(x * x + y * y + z * z) / 9.81;
    const smoothingAlpha = 0.30;
    _smoothedLinearAccelerationG = _hasSmoothedAcceleration
        ? (_smoothedLinearAccelerationG * (1.0 - smoothingAlpha)) +
              (rawLinearAccelerationG * smoothingAlpha)
        : rawLinearAccelerationG;
    _hasSmoothedAcceleration = true;

    _currentData = _currentData.copyWith(
      accelerationG: _smoothedLinearAccelerationG,
      timestamp: DateTime.now(),
    );

    final confirmed = _crashDetector.addLinearAcceleration(x, y, z, sampleTime);
    if (confirmed != null) {
      _detectCrash(confirmed);
    }
    // No notify here: no live widget shows the acceleration, and a notify
    // per sample (about 100 a second, throttled to 10) cost a Flutter frame
    // on the main thread each time. GPS fixes and the 1 s sample timer
    // notify listeners.
  }

  /// Starts a new ride: resets ride statistics and incidents and begins
  /// capturing one sample every [sampleInterval].
  ///
  /// [startedAt] is the ride's zero point for every sample's `elapsedMs`
  /// (default: now). Pass `CameraProvider.recordingStartedAt` so telemetry
  /// and the video segment timeline share one zero point. A value in the
  /// future is clamped to now.
  void startRideSession({DateTime? startedAt}) {
    final now = DateTime.now();
    _isRideActive = true;
    _rideStartTime = startedAt == null || startedAt.isAfter(now)
        ? now
        : startedAt;
    _rideSessionId = _buildRideSessionId(_rideStartTime!);
    _rideTelemetryPath = null;
    _checkpointInput = null;
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    if (!isPersistingRide) {
      _segmentHashCache.clear();
    }
    _rideDistanceKm = 0.0;
    _maxSpeedKmh = 0.0;
    _averageSpeedKmh = 0.0;
    _fixSampleSpeedSum = 0.0;
    _fixSampleCount = 0;
    _lastIncidentDetectedAt = null;
    _lastIncidentJoltElapsedMs = null;
    _lastIncidentGForce = 0.0;
    _incidentCount = 0;
    _rideIncidents.clear();
    _mockLocationDetected = false;
    _endCrashDebugLog();
    _crashDetector.reset();
    _startCrashDebugLog(_rideSessionId!, _rideStartTime!);
    _lastSpeedPosition = null;
    _lastSpeedTimestamp = null;
    _lastLocationUpdateAt = null;
    _filteredSpeedKmh = 0.0;
    _stationaryFixStreak = 0;
    _lastRidePosition = null;
    _activeRideSamples.clear();
    _currentData = _currentData.copyWith(
      speed: 0.0,
      accelerationG: 0.0,
      elapsedMs: 0,
      distanceKm: 0.0,
      timestamp: DateTime.now(),
    );

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

    final now = DateTime.now();
    final lastFixAt = _lastFixReceivedAt;
    final fixAgeMs = lastFixAt == null
        ? null
        : now.difference(lastFixAt).inMilliseconds;
    final hasFix = fixAgeMs != null && fixAgeMs <= maxFixAge.inMilliseconds;
    final TelemetryData sample = TelemetryData(
      latitude: _currentData.latitude,
      longitude: _currentData.longitude,
      speed: _currentData.speed,
      bearing: _currentData.bearing,
      accelerationG: _currentData.accelerationG,
      elapsedMs: now.difference(_rideStartTime!).inMilliseconds,
      distanceKm: _rideDistanceKm,
      timestamp: now,
      hasFix: hasFix,
      fixAgeMs: fixAgeMs,
    );

    _activeRideSamples.add(sample);

    // Samples without a fresh fix repeat stale values; keep them out of the
    // speed statistics.
    if (hasFix) {
      if (sample.speed > _maxSpeedKmh) {
        _maxSpeedKmh = sample.speed;
      }
      _fixSampleSpeedSum += sample.speed;
      _fixSampleCount++;
      _averageSpeedKmh = _fixSampleSpeedSum / _fixSampleCount;
    }

    _forceNotifyUi();
  }

  /// Records the active ride's current segment state and writes a sealed
  /// checkpoint of the ride JSON (`sessionComplete: false`) next to the
  /// segments, so the ride survives a crash or kill before STOP.
  ///
  /// Call it whenever a segment completes or the lock state changes. After
  /// the first call the checkpoint is also rewritten every 30 s with the
  /// latest samples. New segments are hashed in a background isolate so that
  /// [stopRideSessionAndPersist] only has to hash the final one; a
  /// checkpoint lists only segments whose hash is already known.
  ///
  /// Returns the checkpoint path, or `null` when nothing was written (no
  /// active ride, no existing segment, or a write error, which is logged).
  Future<String?> checkpointRideSession({
    required List<String> segmentPaths,
    List<String>? lockedSegmentPaths,
    List<Map<String, dynamic>>? segmentTimeline,
    Map<String, dynamic>? recordingSettings,
  }) async {
    if (!_isRideActive || _rideStartTime == null) {
      return null;
    }

    _checkpointInput = ride_codec.RideFileInput(
      videoPath: segmentPaths.isEmpty ? '' : segmentPaths.last,
      segmentPaths: List<String>.from(segmentPaths),
      lockedSegmentPaths: List<String>.from(lockedSegmentPaths ?? const []),
      segmentTimeline: [
        for (final entry in segmentTimeline ?? const <Map<String, dynamic>>[])
          Map<String, dynamic>.from(entry),
      ],
      recordingSettings: Map<String, dynamic>.from(
        recordingSettings ?? const <String, dynamic>{},
      ),
    );
    _checkpointTimer ??= Timer.periodic(_checkpointInterval, (_) {
      unawaited(_writeCheckpoint());
    });
    _prehashSegments(segmentPaths);
    return _writeCheckpoint();
  }

  Future<String?> _writeCheckpoint() async {
    final input = _checkpointInput;
    final sessionId = _rideSessionId;
    if (!_isRideActive || input == null || sessionId == null) {
      return null;
    }
    final sequence = ++_checkpointSequence;

    try {
      final prehash = _pendingPrehash;
      if (prehash != null) {
        await prehash;
      }
      final resolved = await ride_codec.resolveRideFileContent(input);
      final segmentHashes = await _cachedSegmentHashes(resolved.segmentPaths);
      // A checkpoint lists only segments it can seal; newer ones follow in
      // the next checkpoint or the final save.
      final files = resolved.restrictedTo(segmentHashes.keys.toSet());
      // The ride may have stopped (or a new one started) while resolving.
      if (_rideSessionId != sessionId || !_isRideActive) {
        return null;
      }
      if (files.segmentPaths.isEmpty) {
        return null;
      }

      final ride = _snapshotRide(endedAt: DateTime.now());
      final telemetryPath = _rideTelemetryPath ??= ride_codec
          .rideTelemetryPathFor(
            rideSessionId: sessionId,
            videoPath: files.videoPath,
            segmentPaths: files.segmentPaths,
          );
      final sealed = await ride_codec.sealRidePayload(
        _encodePayload(ride: ride, files: files, sessionComplete: false),
        segmentHashes: segmentHashes,
        segmentCount: files.segmentPaths.length,
        generatedAt: DateTime.now().toUtc(),
      );
      // Never let a checkpoint land after (and overwrite) the final save.
      if (_rideSessionId != sessionId || !_isRideActive) {
        return null;
      }
      // Overlapping checkpoints can finish out of order (hashing and sealing
      // run in isolates); never let an older input replace a newer one.
      if (sequence < _lastQueuedCheckpointSequence) {
        return telemetryPath;
      }
      _lastQueuedCheckpointSequence = sequence;
      await _enqueueWrite(telemetryPath, sealed);
      return telemetryPath;
    } catch (error) {
      debugPrint('Telemetry: checkpoint failed: $error');
      return null;
    }
  }

  /// Ends the active ride and writes its JSON file next to the segments
  /// (`sessionComplete: true`), sealed with a bound integrity envelope that
  /// covers the payload and every segment's SHA-256. Hashing runs in a
  /// background isolate and reuses hashes computed for checkpoints; the
  /// already-hashed part is written first so the ride stays listed if the
  /// process dies while the remaining segments are hashed.
  ///
  /// Ride state is captured and cleared before the first `await`, so a ride
  /// started while this call is still running is not affected.
  ///
  /// Returns the JSON path, or `null` when no ride was active or the save
  /// failed. On failure [lastPersistError] is set and the ride is kept in
  /// memory for [retryPendingPersist].
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
      _checkpointTimer?.cancel();
      _checkpointTimer = null;
      _forceNotifyUi();
      return null;
    }

    // Snapshot and clear synchronously, before any await.
    final ride = _snapshotRide(endedAt: DateTime.now());
    final telemetryPathHint = _rideTelemetryPath;
    final input = ride_codec.RideFileInput(
      videoPath: videoPath,
      segmentPaths: List<String>.from(segmentPaths ?? const []),
      lockedSegmentPaths: List<String>.from(lockedSegmentPaths ?? const []),
      segmentTimeline: [
        for (final entry in segmentTimeline ?? const <Map<String, dynamic>>[])
          Map<String, dynamic>.from(entry),
      ],
      recordingSettings: Map<String, dynamic>.from(
        recordingSettings ?? const <String, dynamic>{},
      ),
    );
    _endRideState();

    Future<String?> persist() => _persistRide(
      ride: ride,
      input: input,
      telemetryPathHint: telemetryPathHint,
    );
    return _runPersist(persist);
  }

  /// Retries every failed [stopRideSessionAndPersist] save, oldest first.
  /// Returns the JSON path of the last one when all of them succeeded, or
  /// `null` when nothing was pending, a retry is already running, or any
  /// save failed again (it then stays pending).
  Future<String?> retryPendingPersist() async {
    if (_pendingPersists.isEmpty || _isRetryingPersist) {
      return null;
    }
    _isRetryingPersist = true;
    final retries = List<Future<String?> Function()>.from(_pendingPersists);
    _pendingPersists.clear();
    String? lastPath;
    var allSucceeded = true;
    try {
      for (final retry in retries) {
        final path = await _runPersist(retry);
        if (path == null) {
          allSucceeded = false;
        } else {
          lastPath = path;
        }
      }
    } finally {
      _isRetryingPersist = false;
    }
    return allSucceeded ? lastPath : null;
  }

  Future<String?> _runPersist(Future<String?> Function() persist) async {
    _activePersistCount++;
    _forceNotifyUi();
    try {
      final path = await persist();
      if (_pendingPersists.isEmpty) {
        _lastPersistError = null;
      }
      return path;
    } catch (error) {
      debugPrint('Telemetry: ride save failed: $error');
      _lastPersistError = error.toString();
      _pendingPersists.add(persist);
      return null;
    } finally {
      _activePersistCount--;
      _forceNotifyUi();
    }
  }

  Future<String> _persistRide({
    required ride_codec.RideFileSnapshot ride,
    required ride_codec.RideFileInput input,
    required String? telemetryPathHint,
  }) async {
    final prehash = _pendingPrehash;
    if (prehash != null) {
      await prehash;
    }
    final files = await ride_codec.resolveRideFileContent(input);
    final String telemetryPath =
        telemetryPathHint ??
        ride_codec.rideTelemetryPathFor(
          rideSessionId: ride.sessionId,
          videoPath: files.videoPath,
          segmentPaths: files.segmentPaths,
        );

    // Write the already-hashed part first so the ride stays listed if the
    // process dies while the remaining segments are hashed.
    final cachedHashes = await _cachedSegmentHashes(files.segmentPaths);
    final checkpointFiles = files.restrictedTo(cachedHashes.keys.toSet());
    if (checkpointFiles.segmentPaths.isNotEmpty) {
      await _enqueueWrite(
        telemetryPath,
        await ride_codec.sealRidePayload(
          _encodePayload(
            ride: ride,
            files: checkpointFiles,
            sessionComplete: false,
          ),
          segmentHashes: cachedHashes,
          segmentCount: checkpointFiles.segmentPaths.length,
          generatedAt: DateTime.now().toUtc(),
        ),
      );
    }

    // Only this final save is signed (checkpoints stay version 2, so no
    // Keystore call runs while recording). Signing never fails the save: a
    // ride that cannot be signed is written as version 2.
    final segmentHashes = await _hashSegments(files.segmentPaths);
    final sealed = await ride_codec.sealAndSignRidePayload(
      _encodePayload(ride: ride, files: files, sessionComplete: true),
      segmentHashes: segmentHashes,
      segmentCount: files.segmentPaths.length,
      generatedAt: DateTime.now().toUtc(),
      signer: _rideSigner,
    );
    await _enqueueWrite(telemetryPath, sealed.json);
    final signature = sealed.signature;
    if (signature != null) {
      await _signedRideRegistry.add(
        signature.publicKey,
        ride.sessionId,
        segmentFileNames: files.segmentPaths.map(path_utils.fileNameFromPath),
      );
    }
    for (final path in files.segmentPaths) {
      _segmentHashCache.remove(path);
    }
    return telemetryPath;
  }

  /// Ends the active ride without saving it and resets the ride statistics.
  /// A checkpoint already written by [checkpointRideSession] stays on disk.
  void cancelRideSession() {
    _endRideState();
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

  void _endRideState() {
    _isRideActive = false;
    _rideStartTime = null;
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    _checkpointInput = null;
    _activeRideSamples.clear();
    _rideIncidents.clear();
    _rideSessionId = null;
    _rideTelemetryPath = null;
    // A jolt still waiting for confirmation belongs to the ride that ended:
    // confirmed after it, it would set lastIncidentDetectedAt with no ride
    // to record it in, and a later recording could lock on it. The sensors
    // keep running, so the signals stay.
    _crashDetector.reset();
    _endCrashDebugLog();
    _lastIncidentDetectedAt = null;
    _lastIncidentJoltElapsedMs = null;
    _pauseIfIdleInBackground();
  }

  ride_codec.RideFileSnapshot _snapshotRide({required DateTime endedAt}) {
    final startedAt = _rideStartTime!;
    return ride_codec.RideFileSnapshot(
      sessionId: _rideSessionId ?? _buildRideSessionId(startedAt),
      startedAt: startedAt,
      endedAt: endedAt,
      samples: _activeRideSamples.map((sample) => sample.toJson()).toList(),
      incidents: [
        for (final incident in _rideIncidents)
          Map<String, dynamic>.from(incident),
      ],
      distanceKm: _rideDistanceKm,
      maxSpeedKmh: _maxSpeedKmh,
      averageSpeedKmh: _averageSpeedKmh,
      mockLocationDetected: _mockLocationDetected,
    );
  }

  Map<String, dynamic> _encodePayload({
    required ride_codec.RideFileSnapshot ride,
    required ride_codec.RideFileContent files,
    required bool sessionComplete,
  }) => ride_codec.encodeRidePayload(
    ride: ride,
    files: files,
    sessionComplete: sessionComplete,
    sampleRateMs: sampleInterval.inMilliseconds,
  );

  String _buildRideSessionId(DateTime startTime) {
    final timestamp = startTime.toUtc().millisecondsSinceEpoch;
    final secureRandom = math.Random.secure();
    final r1 = secureRandom.nextInt(1 << 30);
    final r2 = secureRandom.nextInt(1 << 30);
    final randomHex =
        '${r1.toRadixString(16).padLeft(8, '0')}${r2.toRadixString(16).padLeft(8, '0')}';
    return '${timestamp}_$randomHex';
  }

  /// Serialises every ride-file write of this provider so that checkpoints
  /// and the final save never overlap on the same temporary file.
  Future<void> _enqueueWrite(
    String telemetryPath,
    Map<String, dynamic> payload,
  ) {
    final previous = _pendingWrite;
    final write = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // The earlier writer already reported its own failure.
        }
      }
      await _writeTelemetryAtomically(
        telemetryPath: telemetryPath,
        payload: payload,
      );
    }();
    _pendingWrite = write;
    return write;
  }

  Future<void> _writeTelemetryAtomically({
    required String telemetryPath,
    required Map<String, dynamic> payload,
  }) async {
    final telemetryFile = File(telemetryPath);
    await integrity_utils.writeTelemetryAtomically(
      telemetryFile: telemetryFile,
      content: ride_codec.encodeRideFileJson(payload),
    );
  }

  /// Starts hashing segments that are not cached yet in a background isolate.
  void _prehashSegments(List<String> segmentPaths) {
    final previous = _pendingPrehash;
    final paths = List<String>.from(segmentPaths);
    _pendingPrehash = () async {
      if (previous != null) {
        await previous;
      }
      try {
        await _hashSegments(paths);
      } catch (error) {
        debugPrint('Telemetry: background segment hashing failed: $error');
      }
    }();
  }

  /// Returns the SHA-256 of each existing segment, reusing hashes computed
  /// earlier for files whose size and modification time are unchanged.
  /// Segments that cannot be read are left out (and fail a later deep check).
  Future<Map<String, String>> _hashSegments(List<String> segmentPaths) async {
    final stats = <String, FileStat>{};
    final pending = <String>[];
    for (final path in segmentPaths) {
      final stat = await FileStat.stat(path);
      if (stat.type == FileSystemEntityType.notFound) {
        _segmentHashCache.remove(path);
        continue;
      }
      stats[path] = stat;
      final cached = _segmentHashCache[path];
      if (cached == null || !cached.matches(stat)) {
        pending.add(path);
      }
    }

    if (pending.isNotEmpty) {
      final computed = await _hashFilesInBackground(pending);
      for (final entry in computed.entries) {
        final stat = stats[entry.key];
        if (stat != null) {
          _segmentHashCache[entry.key] = _CachedSegmentHash(
            hash: entry.value,
            size: stat.size,
            modified: stat.modified,
          );
        }
      }
    }

    final hashes = <String, String>{};
    for (final path in segmentPaths) {
      final cached = _segmentHashCache[path];
      final stat = stats[path];
      if (cached != null && stat != null && cached.matches(stat)) {
        hashes[path] = cached.hash;
      }
    }
    return hashes;
  }

  // Static so the isolate closure captures only [paths], never `this`.
  static Future<Map<String, String>> _hashFilesInBackground(
    List<String> paths,
  ) => Isolate.run(() => _hashFiles(paths));

  static Future<Map<String, String>> _hashFiles(List<String> paths) async {
    final hashes = <String, String>{};
    for (final path in paths) {
      try {
        final hash = await integrity_utils.hashFileSha256(path);
        if (hash != null) {
          hashes[path] = hash;
        }
      } catch (_) {
        // Unreadable segment: leave it unhashed.
      }
    }
    return hashes;
  }

  /// Returns hashes already computed for the existing [segmentPaths] whose
  /// files are unchanged since hashing, without hashing anything new.
  Future<Map<String, String>> _cachedSegmentHashes(
    List<String> segmentPaths,
  ) async {
    final hashes = <String, String>{};
    for (final path in segmentPaths) {
      final cached = _segmentHashCache[path];
      if (cached == null) {
        continue;
      }
      final stat = await FileStat.stat(path);
      if (stat.type != FileSystemEntityType.notFound && cached.matches(stat)) {
        hashes[path] = cached.hash;
      }
    }
    return hashes;
  }

  // Debug builds only: one event log per ride (CrashDebugLog). It listens to
  // the detector until the ride ends and never blocks the sensor path.
  void _startCrashDebugLog(String sessionId, DateTime startedAt) {
    if (!_crashDebugLogEnabled) {
      return;
    }
    final log = CrashDebugLog(
      rideSessionId: sessionId,
      rideStartedAt: startedAt,
      resolveDirectory: _crashDebugDirectory,
      triggerG: _crashDetector.triggerG,
      clock: _clock,
    )..begin();
    _crashDebugLog = log;
    _crashDetector.observer = log;
  }

  // Call after the detector's reset, so a dropped candidate is logged.
  void _endCrashDebugLog() {
    final log = _crashDebugLog;
    if (log == null) {
      return;
    }
    _crashDetector.observer = null;
    _crashDebugLog = null;
    _crashDebugLogClosed = log.finish();
  }

  /// Completes when the last ride's crash debug log is closed. Only tests
  /// read it.
  @visibleForTesting
  Future<void> get crashDebugLogClosedForTesting => _crashDebugLogClosed;

  // Records a confirmed incident at its jolt's time (the detector already
  // applied the debounce) and notifies listeners, which lock the segments.
  void _detectCrash(ConfirmedCrash crash) {
    final now = _clock();
    // The detector's times are accelerometer event times. Only their
    // difference is used, so a sensor clock that is offset from the wall
    // clock cannot move the jolt.
    final joltWallAt = now.subtract(crash.confirmedAt.difference(crash.joltAt));
    debugPrint(
      'Telemetry: incident confirmed by ${crash.confirmation.name} '
      '${crash.confirmedAt.difference(crash.joltAt).inMilliseconds} ms '
      'after the jolt (peak ${crash.peakG.toStringAsFixed(1)} g)',
    );

    _lastIncidentDetectedAt = now;
    _lastIncidentGForce = crash.peakG;
    _lastIncidentJoltElapsedMs = null;
    _incidentCount++;
    final rideStart = _rideStartTime;
    if (_isRideActive && rideStart != null) {
      final elapsedMs = math.max(
        0,
        joltWallAt.difference(rideStart).inMilliseconds,
      );
      _lastIncidentJoltElapsedMs = elapsedMs;
      _rideIncidents.add({
        'elapsedMs': elapsedMs,
        'timestamp': joltWallAt.toUtc().toIso8601String(),
        'gForce': crash.peakG,
        'triggerGForce': _incidentTriggerGForce,
        'reason': 'auto-crash',
      });
    }
    _forceNotifyUi();
  }

  /// Clears ride samples and statistics and resets [currentData]; the
  /// incident count is kept. Only used by tests.
  @visibleForTesting
  void clearHistory() {
    _activeRideSamples.clear();
    _rideDistanceKm = 0.0;
    _maxSpeedKmh = 0.0;
    _averageSpeedKmh = 0.0;
    _fixSampleSpeedSum = 0.0;
    _fixSampleCount = 0;
    _lastSpeedPosition = null;
    _lastSpeedTimestamp = null;
    _lastLocationUpdateAt = null;
    _lastFixTimestamp = null;
    _lastFixReceivedAt = null;
    _filteredSpeedKmh = 0.0;
    _stationaryFixStreak = 0;
    _currentData = TelemetryData.empty();
    _forceNotifyUi();
  }

  // Throttled notify with a trailing edge: an update inside the interval is
  // delivered when the interval ends instead of being dropped.
  void _notifyUiIfNeeded() {
    final last = _lastUiNotifyAt;
    if (last != null) {
      var wait = _uiNotifyMinInterval - DateTime.now().difference(last);
      if (wait > Duration.zero) {
        if (wait > _uiNotifyMinInterval) {
          wait = _uiNotifyMinInterval; // the clock went back
        }
        _trailingUiNotify ??= Timer(wait, _forceNotifyUi);
        return;
      }
    }
    _forceNotifyUi();
  }

  void _forceNotifyUi() {
    _trailingUiNotify?.cancel();
    _trailingUiNotify = null;
    _lastUiNotifyAt = DateTime.now();
    notifyListeners();
  }

  /// Cancels the sample and checkpoint timers, stops GPS and accelerometer
  /// tracking and removes the lifecycle observer. An active ride is not
  /// saved, and a ride save in progress is neither awaited nor cancelled.
  @override
  void dispose() {
    _sampleTimer?.cancel();
    _checkpointTimer?.cancel();
    _trailingUiNotify?.cancel();
    _stopTracking();
    _endCrashDebugLog();
    if (_isObservingLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
      _isObservingLifecycle = false;
    }
    super.dispose();
  }

  /// Feeds [position] through the production location handler.
  @visibleForTesting
  void updateLocationForTesting(Position position) {
    _updateLocation(position);
  }

  /// Feeds one linear-acceleration sample (m/s²) through the production
  /// accelerometer handler. [timestamp] defaults to now.
  @visibleForTesting
  void updateAccelerometerForTesting(
    double x,
    double y,
    double z, {
    DateTime? timestamp,
  }) {
    _onLinearAcceleration(x, y, z, at: timestamp);
  }

  /// Feeds one raw accelerometer sample (m/s², gravity included) to the
  /// orientation used by the tip-over check, as the separate raw stream
  /// does next to the linear-acceleration sensor. [timestamp] defaults to
  /// now.
  @visibleForTesting
  void updateOrientationForTesting(
    double x,
    double y,
    double z, {
    DateTime? timestamp,
  }) {
    _onOrientationSample(x, y, z, at: timestamp);
  }

  /// Feeds one raw accelerometer sample (m/s², gravity included) through
  /// the gravity-filtered fallback used on devices without a
  /// linear-acceleration sensor. [timestamp] defaults to now.
  @visibleForTesting
  void updateRawAccelerometerForTesting(
    double x,
    double y,
    double z, {
    DateTime? timestamp,
  }) {
    _onRawAcceleration(x, y, z, at: timestamp);
  }
}

class _CachedSegmentHash {
  _CachedSegmentHash({
    required this.hash,
    required this.size,
    required this.modified,
  });

  final String hash;
  final int size;
  final DateTime modified;

  bool matches(FileStat stat) => stat.size == size && stat.modified == modified;
}
