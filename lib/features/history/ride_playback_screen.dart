import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../../core/utils/format_utils.dart';
import '../map/map_source_config.dart';
import '../telemetry/models/telemetry_data.dart';
import 'models/ride_record.dart';
import 'widgets/playback_seekbar_track_shape.dart';
import 'widgets/playback_timeline.dart';
import 'widgets/route_map_view.dart';

/// Plays back a recorded ride: its video segments as one continuous timeline,
/// with a telemetry overlay, a speed graph, a seekbar that marks missing
/// footage, integrity-check failures, incidents and locked segments, and an
/// optional online route map.
///
/// Segment integrity is checked in the background after the screen opens;
/// segments that cannot be confirmed unmodified since recording are marked on
/// the seekbar.
class RidePlaybackScreen extends StatefulWidget {
  /// Creates a playback screen for [ride].
  const RidePlaybackScreen({super.key, required this.ride});

  /// The ride to play.
  final RideRecord ride;

  @override
  State<RidePlaybackScreen> createState() => _RidePlaybackScreenState();
}

enum _SegmentLoadOutcome { loaded, failed, cancelled }

class _PendingSeek {
  const _PendingSeek(this.target, this.shouldResume);

  final Duration target;
  final bool shouldResume;
}

class _SegmentIntegrityResult {
  const _SegmentIntegrityResult({
    required this.issues,
    required this.quarantinedCount,
  });

  final List<String> issues;
  final int quarantinedCount;
}

class _RidePlaybackScreenState extends State<RidePlaybackScreen>
    with WidgetsBindingObserver {
  static const String _showRouteMapPrefKey = 'ride_playback_show_route_map';
  static const String _onlineMapConsentPrefKey =
      'ride_playback_online_map_consent';

  /// Tap distance, in logical pixels, within which a seekbar tap snaps to a
  /// marker.
  static const double _markerTapTolerancePx = 18;

  /// Segment-integrity results of recently opened rides, keyed by the
  /// telemetry path and the size and modification time of every file, so
  /// re-opening an unchanged ride does not hash its segments again and
  /// concurrent opens share one job.
  static final LinkedHashMap<String, Future<_SegmentIntegrityResult>>
  _integrityJobs = LinkedHashMap<String, Future<_SegmentIntegrityResult>>();
  static const int _maxCachedIntegrityJobs = 16;

  VideoPlayerController? _controller;
  bool _isLoading = true;
  bool _isDisposing = false;
  bool _isAppInForeground = true;
  String? _playbackError;
  final List<String> _segmentPaths = <String>[];
  final List<Duration> _segmentDurations = <Duration>[];
  final List<Duration> _segmentOffsets = <Duration>[];
  final Set<int> _failedSegmentIndexes = <int>{};
  List<RideSegmentTimelineEntry> _timelineEntries =
      const <RideSegmentTimelineEntry>[];
  Duration _totalDuration = Duration.zero;
  Duration _lastKnownGlobalPosition = Duration.zero;
  Duration? _scrubPreviewPosition;
  int _activeSegmentIndex = 0;
  int _loadGeneration = 0;
  bool _isSwitchingSegment = false;
  bool _isSeekingAcrossSegments = false;
  _PendingSeek? _pendingSeek;
  VideoPlayerController? _erroredController;
  bool _isScrubbing = false;
  bool _resumeAfterScrub = false;
  Duration? _graphDragAnchor;
  double _graphDragStartDx = 0;
  bool _showRouteMap = false;
  bool _hasOnlineMapConsent = false;
  bool _isFullscreenPlayback = false;
  List<int> _lockMarkerMs = const <int>[];
  List<int> _incidentMarkerMs = const <int>[];
  List<PlaybackRange> _missingSegmentRanges = const <PlaybackRange>[];
  List<PlaybackRange> _failedCheckRanges = const <PlaybackRange>[];
  List<PlaybackRange> _noVideoRanges = const <PlaybackRange>[];
  Set<String> _integrityFailedPaths = const <String>{};
  double _maxSampleSpeed = 1;
  bool _hasShownInitializationWarning = false;
  bool _hasShownIntegrityWarning = false;
  String? _shownIntegrityNotice;

  bool get _isSegmentLoadInFlight =>
      _isSwitchingSegment || _isSeekingAcrossSegments;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _isAppInForeground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    for (final sample in widget.ride.samples) {
      _maxSampleSpeed = math.max(_maxSampleSpeed, sample.speed);
    }
    unawaited(_loadPlaybackPreferences());
    _showInitialIntegrityWarning();
    unawaited(_verifySegmentsAsync());
    unawaited(_initializePlayback());
  }

  /// Shows what the payload-level check done when loading the ride found,
  /// that a ride without an integrity record cannot be checked, and that
  /// its GPS came from a simulated location provider.
  void _showInitialIntegrityWarning() {
    final ride = widget.ride;
    final integrityNotice = describeIntegrityIssues(
      issues: ride.integrity.issues,
      quarantinedCount: ride.quarantinedSegmentPaths.length,
    );
    final notices = <String>[
      ?integrityNotice,
      if (integrityNotice == null &&
          ride.telemetryPath != null &&
          ride.integrity.status == RideIntegrityStatus.unknown)
        'This ride has no integrity record, so its files cannot be checked.',
      if (ride.mockLocationDetected)
        'GPS in this ride came from a simulated (mock) location provider.',
    ];
    // Segments without a recorded hash are known before any hashing, so the
    // seekbar can mark them right away; the background check refines this.
    _integrityFailedPaths = segmentPathsFailingIntegrity(ride.integrity.issues);
    if (notices.isEmpty) {
      return;
    }
    if (integrityNotice != null) {
      _hasShownIntegrityWarning = true;
      _shownIntegrityNotice = integrityNotice;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showMessage(notices.join(' '), duration: const Duration(seconds: 5));
    });
  }

  Future<void> _verifySegmentsAsync() async {
    final _SegmentIntegrityResult result;
    try {
      result = await _segmentIntegrityFor(widget.ride);
    } catch (_) {
      return;
    }
    if (!mounted || _isDisposing) {
      return;
    }

    final failedPaths = segmentPathsFailingIntegrity(result.issues);
    setState(() {
      _integrityFailedPaths = failedPaths;
      _failedCheckRanges = rangesForPaths(
        timeline: _timelineEntries,
        paths: _integrityFailedPaths,
      );
    });

    if (failedPaths.isEmpty && _hasShownIntegrityWarning) {
      return;
    }
    final notice = describeIntegrityIssues(
      issues: result.issues,
      quarantinedCount: result.quarantinedCount,
    );
    // Do not repeat the notice already shown from the load-time check.
    if (notice == null || notice == _shownIntegrityNotice) {
      return;
    }
    _hasShownIntegrityWarning = true;
    _shownIntegrityNotice = notice;
    _showMessage(notice, duration: const Duration(seconds: 6));
  }

  static Future<_SegmentIntegrityResult> _segmentIntegrityFor(
    RideRecord ride,
  ) async {
    final key = await _integrityCacheKey(ride);
    final cached = _integrityJobs.remove(key);
    if (cached != null) {
      _integrityJobs[key] = cached;
      return cached;
    }

    final job = _verifySegmentsOffUiIsolate(ride);
    _integrityJobs[key] = job;
    while (_integrityJobs.length > _maxCachedIntegrityJobs) {
      unawaited(_integrityJobs.remove(_integrityJobs.keys.first));
    }
    unawaited(
      job.catchError((Object _) {
        unawaited(_integrityJobs.remove(key));
        return const _SegmentIntegrityResult(
          issues: <String>[],
          quarantinedCount: 0,
        );
      }),
    );
    return job;
  }

  /// Hashes the ride's segments on a background isolate so playback and the
  /// UI stay responsive; falls back to the current isolate if that fails.
  ///
  /// Only the issue list and the quarantine count come back from the
  /// isolate, not the whole ride with its telemetry samples.
  static Future<_SegmentIntegrityResult> _verifySegmentsOffUiIsolate(
    RideRecord ride,
  ) async {
    Future<_SegmentIntegrityResult> verify() async {
      final verified = await ride.verifySegmentIntegrity();
      return _SegmentIntegrityResult(
        issues: List<String>.of(verified.integrity.issues),
        quarantinedCount: verified.quarantinedSegmentPaths.length,
      );
    }

    try {
      return await Isolate.run(verify);
    } catch (_) {
      return verify();
    }
  }

  static Future<String> _integrityCacheKey(RideRecord ride) async {
    final buffer = StringBuffer(ride.telemetryPath ?? ride.videoPath);
    final paths = <String>[
      if (ride.telemetryPath != null) ride.telemetryPath!,
      ...ride.segmentPaths,
    ];
    for (final path in paths) {
      final stat = await FileStat.stat(path);
      buffer
        ..write('|')
        ..write(path)
        ..write(':')
        ..write(stat.size)
        ..write(':')
        ..write(stat.modified.millisecondsSinceEpoch);
    }
    return buffer.toString();
  }

  void _showMessage(
    String message, {
    Duration? duration,
    bool replaceCurrent = false,
  }) {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    if (replaceCurrent) {
      messenger.hideCurrentSnackBar();
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration ?? const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _loadPlaybackPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final consent = prefs.getBool(_onlineMapConsentPrefKey) ?? false;
    final showRouteMap =
        consent && (prefs.getBool(_showRouteMapPrefKey) ?? false);
    if (!mounted) {
      return;
    }
    setState(() {
      _hasOnlineMapConsent = consent;
      _showRouteMap = showRouteMap;
    });
  }

  Future<void> _persistBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  /// Asks once before the online map is first shown, because loading tiles
  /// sends the ride's area to the tile server.
  Future<bool> _confirmOnlineMap() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Show online map?'),
        content: const Text(
          'The route map downloads map tiles from OpenStreetMap '
          '(${MapSourceConfig.tileHost}). This sends the area of this ride '
          'and your IP address to the OpenStreetMap Foundation, and the tiles '
          'are cached on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Show map'),
          ),
        ],
      ),
    );
    return accepted ?? false;
  }

  Future<void> _toggleRouteMapVisibility() async {
    final show = !_showRouteMap;
    if (show && !_hasOnlineMapConsent) {
      if (!await _confirmOnlineMap() || !mounted) {
        return;
      }
      _hasOnlineMapConsent = true;
      unawaited(_persistBool(_onlineMapConsentPrefKey, true));
    }
    setState(() {
      _showRouteMap = show;
    });
    unawaited(_persistBool(_showRouteMapPrefKey, show));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppInForeground = state == AppLifecycleState.resumed;
    if (!_isAppInForeground) {
      unawaited(_stopPlayback());
    }
  }

  Future<void> _initializePlayback() async {
    final declaredPaths = orderedDeclaredSegmentPaths(
      segmentPaths: widget.ride.segmentPaths,
      videoPath: widget.ride.videoPath,
    );
    final storedTimelinePaths = <String>{
      for (final entry in widget.ride.segmentTimeline)
        if (entry.endMs - entry.startMs >= minPlaybackSegmentMs)
          entry.path.trim(),
    };

    // Durations of segments listed in the stored timeline come from it; only
    // segments without a usable entry (rides recorded before the timeline
    // existed, or an entry saved without an end) are probed with a native
    // player. Readability is checked when a segment is loaded.
    final probedDurationsByPath = <String, Duration>{};
    final unavailablePaths = <String>{};
    var missingSegmentsCount = 0;
    var unreadableSegmentsCount = 0;
    var unreadableTrailingSegmentsCount = 0;

    for (var index = 0; index < declaredPaths.length; index++) {
      if (_isDisposing || !mounted) {
        return;
      }
      final path = declaredPaths[index];
      if (!await File(path).exists()) {
        missingSegmentsCount++;
        unavailablePaths.add(path);
        continue;
      }
      if (storedTimelinePaths.contains(path)) {
        continue;
      }

      final isTrailingSegment = index == declaredPaths.length - 1;
      final probe = await _probeSegmentDuration(
        path,
        retryOnFailure: isTrailingSegment,
      );
      if (_isDisposing || !mounted) {
        return;
      }
      if (probe.duration > Duration.zero) {
        probedDurationsByPath[path] = probe.duration;
        continue;
      }

      unreadableSegmentsCount++;
      unavailablePaths.add(path);
      if (isTrailingSegment) {
        unreadableTrailingSegmentsCount++;
      }
      debugPrint(
        'Ride playback: skipped unreadable segment ${index + 1} '
        '(${probe.error ?? 'unknown-error'})',
      );
    }
    if (_isDisposing || !mounted) {
      return;
    }

    final timeline = buildEffectiveTimeline(
      declaredPaths: declaredPaths,
      storedTimeline: widget.ride.segmentTimeline,
      probedDurationsByPath: probedDurationsByPath,
    );
    final declaredSet = declaredPaths.toSet();

    _segmentPaths.clear();
    _segmentDurations.clear();
    _segmentOffsets.clear();
    _failedSegmentIndexes.clear();
    final unplayablePaths = <String>{};
    for (final entry in timeline) {
      if (!declaredSet.contains(entry.path) ||
          unavailablePaths.contains(entry.path)) {
        unplayablePaths.add(entry.path);
        continue;
      }
      _segmentPaths.add(entry.path);
      _segmentOffsets.add(Duration(milliseconds: entry.startMs));
      _segmentDurations.add(
        Duration(milliseconds: entry.endMs - entry.startMs),
      );
    }

    final telemetryMs = widget.ride.samples.isNotEmpty
        ? widget.ride.samples.last.elapsedMs
        : 0;
    var totalMs = telemetryMs;
    for (final entry in timeline) {
      totalMs = math.max(totalMs, entry.endMs);
    }

    _timelineEntries = timeline;
    _totalDuration = Duration(milliseconds: totalMs);
    _missingSegmentRanges = rangesForPaths(
      timeline: timeline,
      paths: unplayablePaths,
    );
    _failedCheckRanges = rangesForPaths(
      timeline: timeline,
      paths: _integrityFailedPaths,
    );
    _noVideoRanges = uncoveredRanges(timeline: timeline, totalMs: totalMs);
    _lastKnownGlobalPosition = Duration.zero;
    _lockMarkerMs = lockMarkerOffsetsMs(
      playlistPaths: _segmentPaths,
      playlistOffsets: _segmentOffsets,
      lockedPaths: widget.ride.lockedSegmentPaths,
      totalMs: totalMs,
    );
    // Rides that saved live-detected incidents show exactly those; older
    // files fall back to the sample heuristic.
    final recordedIncidents = widget.ride.incidents;
    _incidentMarkerMs = recordedIncidents != null
        ? recordedIncidentOffsetsMs(
            elapsedMs: [
              for (final incident in recordedIncidents) incident.elapsedMs,
            ],
            totalMs: totalMs,
          )
        : incidentMarkerOffsetsMs(
            samples: widget.ride.samples,
            totalMs: totalMs,
          );

    var loaded = false;
    for (var index = 0; index < _segmentPaths.length; index++) {
      final outcome = await _loadSegment(index: index, autoPlay: false);
      if (outcome == _SegmentLoadOutcome.cancelled) {
        return;
      }
      if (outcome == _SegmentLoadOutcome.loaded) {
        loaded = true;
        break;
      }
      unreadableSegmentsCount++;
      _markSegmentFailed(index);
    }
    if (!mounted || _isDisposing) {
      return;
    }

    setState(() {
      _isLoading = false;
      if (!loaded) {
        _playbackError = _noPlayableVideoMessage(
          declaredCount: declaredPaths.length,
          missingCount: missingSegmentsCount,
          unreadableCount: unreadableSegmentsCount,
        );
      }
    });
    if (!loaded) {
      return;
    }
    _showInitializationWarning(
      missingSegmentsCount: missingSegmentsCount,
      unreadableSegmentsCount: unreadableSegmentsCount,
      unreadableTrailingSegmentsCount: unreadableTrailingSegmentsCount,
    );
  }

  String _noPlayableVideoMessage({
    required int declaredCount,
    required int missingCount,
    required int unreadableCount,
  }) {
    if (declaredCount == 0) {
      return 'This ride has no video segments.';
    }
    final details = <String>[
      if (missingCount > 0) '$missingCount missing',
      if (unreadableCount > 0) '$unreadableCount unreadable',
    ];
    final suffix = details.isEmpty ? '' : ' (${details.join(', ')})';
    return 'No playable video for this ride$suffix.';
  }

  Future<void> _retryPlayback() async {
    final controller = _controller;
    _loadGeneration++;
    _pendingSeek = null;
    _erroredController = null;
    setState(() {
      _controller = null;
      _isLoading = true;
      _playbackError = null;
      _hasShownInitializationWarning = false;
    });
    if (controller != null) {
      controller.removeListener(_onControllerTick);
      unawaited(_stopAndDisposeController(controller));
    }
    await _initializePlayback();
  }

  void _showInitializationWarning({
    required int missingSegmentsCount,
    required int unreadableSegmentsCount,
    required int unreadableTrailingSegmentsCount,
  }) {
    if (!mounted || _hasShownInitializationWarning) {
      return;
    }
    if (missingSegmentsCount <= 0 && unreadableSegmentsCount <= 0) {
      return;
    }

    _hasShownInitializationWarning = true;
    final details = <String>[];
    if (missingSegmentsCount > 0) {
      details.add('$missingSegmentsCount missing');
    }
    if (unreadableSegmentsCount > 0) {
      details.add('$unreadableSegmentsCount unreadable');
    }

    final trailingHint = unreadableTrailingSegmentsCount > 0
        ? ' The last segment was retried once.'
        : '';

    _showMessage(
      'Some ride segments are unavailable (${details.join(', ')}). '
      'They are marked red on the seekbar and skipped.$trailingHint',
    );
  }

  /// Marks the playlist segment at [index] as unplayable and shows its span as
  /// missing footage.
  void _markSegmentFailed(int index) {
    if (index < 0 || index >= _segmentPaths.length) {
      return;
    }
    if (!_failedSegmentIndexes.add(index)) {
      return;
    }
    final start = _segmentOffsets[index];
    final ranges = mergeRanges(<PlaybackRange>[
      ..._missingSegmentRanges,
      PlaybackRange(
        startMs: start.inMilliseconds,
        endMs: (start + _segmentDurations[index]).inMilliseconds,
      ),
    ]);
    if (mounted) {
      setState(() {
        _missingSegmentRanges = ranges;
      });
    } else {
      _missingSegmentRanges = ranges;
    }
  }

  Future<_SegmentProbeResult> _probeDurationOnce(String path) async {
    final probe = VideoPlayerController.file(File(path));
    try {
      await probe.initialize();
      final duration = probe.value.duration;
      if (duration > Duration.zero) {
        return _SegmentProbeResult(duration: duration);
      }
      return const _SegmentProbeResult(
        duration: Duration.zero,
        error: 'duration-is-zero',
      );
    } catch (e) {
      return _SegmentProbeResult(duration: Duration.zero, error: e.toString());
    } finally {
      await probe.dispose();
    }
  }

  Future<_SegmentProbeResult> _probeSegmentDuration(
    String path, {
    required bool retryOnFailure,
  }) async {
    final firstAttempt = await _probeDurationOnce(path);
    if (firstAttempt.duration > Duration.zero ||
        !retryOnFailure ||
        _isDisposing) {
      return firstAttempt;
    }

    await Future<void>.delayed(const Duration(milliseconds: 300));
    final secondAttempt = await _probeDurationOnce(path);
    if (secondAttempt.duration > Duration.zero) {
      return secondAttempt;
    }

    return _SegmentProbeResult(
      duration: Duration.zero,
      error: secondAttempt.error ?? firstAttempt.error,
    );
  }

  Future<VideoPlayerController?> _initializeSegmentController(
    String path, {
    required bool retryOnFailure,
  }) async {
    Future<VideoPlayerController?> tryInitializeOnce() async {
      final controller = VideoPlayerController.file(File(path));
      try {
        await controller.initialize();
        return controller;
      } catch (e) {
        debugPrint('Ride playback: failed loading segment ($e)');
        await _stopAndDisposeController(controller);
        return null;
      }
    }

    final firstAttempt = await tryInitializeOnce();
    if (firstAttempt != null || !retryOnFailure || _isDisposing) {
      return firstAttempt;
    }

    await Future<void>.delayed(const Duration(milliseconds: 300));
    return tryInitializeOnce();
  }

  /// Initializes the segment at [index] and makes it the active controller.
  ///
  /// Each call takes a new load generation; a load that a later call (or
  /// dispose) supersedes disposes its own controller and reports
  /// [_SegmentLoadOutcome.cancelled]. The controller that is replaced is read
  /// at swap time, so no initialized controller is ever left undisposed.
  Future<_SegmentLoadOutcome> _loadSegment({
    required int index,
    required bool autoPlay,
    Duration initialPosition = Duration.zero,
  }) async {
    if (_isDisposing || !mounted) {
      return _SegmentLoadOutcome.cancelled;
    }
    if (index < 0 || index >= _segmentPaths.length) {
      return _SegmentLoadOutcome.failed;
    }

    final generation = ++_loadGeneration;
    bool isSuperseded() =>
        _isDisposing || !mounted || generation != _loadGeneration;

    final current = _controller;
    if (current != null && current.value.isInitialized) {
      _lastKnownGlobalPosition = _globalPosition();
    }

    final retryOnFailure = index == _segmentPaths.length - 1;
    final controller = await _initializeSegmentController(
      _segmentPaths[index],
      retryOnFailure: retryOnFailure,
    );
    if (controller == null) {
      return isSuperseded()
          ? _SegmentLoadOutcome.cancelled
          : _SegmentLoadOutcome.failed;
    }

    Duration clampedPosition;
    try {
      if (isSuperseded()) {
        await _stopAndDisposeController(controller);
        return _SegmentLoadOutcome.cancelled;
      }
      await controller.setLooping(false);

      clampedPosition = _clampDuration(
        initialPosition,
        controller.value.duration,
      );
      if (clampedPosition > Duration.zero) {
        await controller.seekTo(clampedPosition);
      }
    } catch (_) {
      await _stopAndDisposeController(controller);
      return isSuperseded()
          ? _SegmentLoadOutcome.cancelled
          : _SegmentLoadOutcome.failed;
    }

    if (isSuperseded()) {
      await _stopAndDisposeController(controller);
      return _SegmentLoadOutcome.cancelled;
    }

    final replaced = _controller;
    replaced?.removeListener(_onControllerTick);
    controller.addListener(_onControllerTick);
    final actualDuration = controller.value.duration;
    setState(() {
      _controller = controller;
      _activeSegmentIndex = index;
      if (actualDuration > Duration.zero) {
        _segmentDurations[index] = actualDuration;
      }
      _lastKnownGlobalPosition = _clampDuration(
        _segmentOffsets[index] + clampedPosition,
        _totalDuration,
      );
    });

    if (replaced != null && !identical(replaced, controller)) {
      // Dispose the replaced controller after the new one is mounted to avoid
      // a transient "used after dispose" during widget handoff.
      unawaited(_stopAndDisposeController(replaced));
    }

    if (autoPlay && _isAppInForeground && !_isDisposing && !_isScrubbing) {
      try {
        await controller.play();
      } catch (_) {
        // A playback error is reported through the controller value.
      }
    }
    return _SegmentLoadOutcome.loaded;
  }

  void _onControllerTick() {
    if (_isDisposing) {
      return;
    }

    final controller = _controller;
    if (controller == null) {
      return;
    }
    if (controller.value.hasError) {
      _handleRuntimeError(controller);
      return;
    }
    if (!controller.value.isInitialized) {
      return;
    }

    _lastKnownGlobalPosition = _globalPositionFromController(
      controller,
      _activeSegmentIndex,
    );

    if (controller.value.isCompleted &&
        !_isSegmentLoadInFlight &&
        _nextPlayableIndex(_activeSegmentIndex + 1) != null) {
      _lastKnownGlobalPosition = _clampDuration(
        _segmentOffsets[_activeSegmentIndex] +
            _segmentDurations[_activeSegmentIndex],
        _totalDuration,
      );
      unawaited(_advanceToNextSegment());
    }
  }

  /// Handles a decode or source error reported after a segment loaded: marks
  /// the segment as unplayable and moves on to the next playable one.
  void _handleRuntimeError(VideoPlayerController controller) {
    if (identical(_erroredController, controller)) {
      return;
    }
    _erroredController = controller;
    final index = _activeSegmentIndex;
    debugPrint(
      'Ride playback: segment ${index + 1} failed during playback '
      '(${controller.value.errorDescription})',
    );
    _markSegmentFailed(index);

    final hasNext = _nextPlayableIndex(index + 1) != null;
    _showMessage(
      hasNext
          ? 'Segment ${index + 1} could not be played. Skipping to the next segment.'
          : 'Playback ended: segment ${index + 1} could not be played.',
    );
    if (hasNext && !_isSegmentLoadInFlight) {
      unawaited(_advanceToNextSegment());
    }
  }

  int? _nextPlayableIndex(int from) {
    for (var index = math.max(from, 0); index < _segmentPaths.length; index++) {
      if (!_failedSegmentIndexes.contains(index)) {
        return index;
      }
    }
    return null;
  }

  Future<void> _advanceToNextSegment() async {
    if (_isSegmentLoadInFlight || _isDisposing) {
      return;
    }

    _isSwitchingSegment = true;
    try {
      var candidate = _nextPlayableIndex(_activeSegmentIndex + 1);
      while (candidate != null && !_isDisposing) {
        final outcome = await _loadSegment(index: candidate, autoPlay: true);
        if (outcome != _SegmentLoadOutcome.failed) {
          return;
        }
        _markSegmentFailed(candidate);
        candidate = _nextPlayableIndex(candidate + 1);
      }
      if (_isDisposing) {
        return;
      }
      await _stopPlayback();
      _showMessage(
        'Playback ended: the remaining segments could not be opened.',
      );
    } finally {
      _isSwitchingSegment = false;
      _drainPendingSeek();
    }
  }

  Future<void> _stopPlayback() async {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    if (controller.value.isPlaying) {
      await controller.pause();
    }
  }

  Future<void> _stopAndDisposeController(
    VideoPlayerController controller,
  ) async {
    try {
      if (controller.value.isPlaying) {
        await controller.pause();
      }
    } catch (_) {
      // Best effort pause before dispose.
    }
    await controller.dispose();
  }

  Duration _globalPosition() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return _lastKnownGlobalPosition;
    }

    return _globalPositionFromController(controller, _activeSegmentIndex);
  }

  Duration _globalPositionFromController(
    VideoPlayerController controller,
    int segmentIndex,
  ) {
    final offset = segmentIndex < _segmentOffsets.length
        ? _segmentOffsets[segmentIndex]
        : Duration.zero;
    return _clampDuration(offset + controller.value.position, _totalDuration);
  }

  /// Seeks to [target] on the ride timeline.
  ///
  /// While a segment load is in flight the request is not started; the latest
  /// one is kept and runs when the load finishes, so only one segment load
  /// ever runs at a time.
  Future<void> _seekGlobal(
    Duration target, {
    required bool shouldResume,
  }) async {
    if (_isDisposing ||
        _segmentPaths.isEmpty ||
        _totalDuration == Duration.zero) {
      return;
    }
    if (_isSegmentLoadInFlight) {
      // During an auto-advance the finished segment reports "not playing",
      // but the advance itself resumes playback, so keep it going.
      _pendingSeek = _PendingSeek(target, shouldResume || _isSwitchingSegment);
      return;
    }

    final current = _controller;
    if (current == null) {
      return;
    }
    final safeTarget = _clampDuration(target, _totalDuration);
    final seekTarget = locateSegment(
      offsets: _segmentOffsets,
      durations: _segmentDurations,
      position: safeTarget,
    );

    // A segment that failed during playback is skipped like any other
    // unplayable segment instead of seeking its errored controller.
    if (seekTarget.segmentIndex == _activeSegmentIndex &&
        !_failedSegmentIndexes.contains(_activeSegmentIndex)) {
      _lastKnownGlobalPosition = safeTarget;
      try {
        await current.seekTo(seekTarget.localPosition);
        // An auto-advance may have replaced (and disposed) this controller
        // while the seek ran.
        if (shouldResume &&
            _isAppInForeground &&
            !_isDisposing &&
            !_isScrubbing &&
            identical(_controller, current)) {
          await current.play();
        }
      } catch (e) {
        debugPrint('Ride playback: seek failed ($e)');
      }
      return;
    }

    _isSeekingAcrossSegments = true;
    try {
      var candidate = seekTarget.segmentIndex;
      var initialPosition = seekTarget.localPosition;
      var outcome = _SegmentLoadOutcome.failed;

      while (candidate < _segmentPaths.length && !_isDisposing) {
        if (_failedSegmentIndexes.contains(candidate)) {
          candidate++;
          initialPosition = Duration.zero;
          continue;
        }
        outcome = await _loadSegment(
          index: candidate,
          autoPlay: false,
          initialPosition: initialPosition,
        );
        if (outcome != _SegmentLoadOutcome.failed) {
          break;
        }
        _markSegmentFailed(candidate);
        candidate++;
        initialPosition = Duration.zero;
      }

      if (_isDisposing || outcome == _SegmentLoadOutcome.cancelled) {
        return;
      }
      if (outcome == _SegmentLoadOutcome.failed) {
        if (mounted) {
          setState(() {});
        }
        _showMessage(
          'No playable video at ${_formatDuration(safeTarget)} or later.',
        );
        return;
      }

      if (shouldResume && _isAppInForeground && !_isScrubbing) {
        try {
          await _controller?.play();
        } catch (_) {
          // A playback error is reported through the controller value.
        }
      }
    } finally {
      _isSeekingAcrossSegments = false;
      _drainPendingSeek();
    }
  }

  void _drainPendingSeek() {
    final pending = _pendingSeek;
    if (pending == null || _isDisposing || _isSegmentLoadInFlight) {
      return;
    }
    _pendingSeek = null;
    unawaited(_seekGlobal(pending.target, shouldResume: pending.shouldResume));
  }

  Future<void> _beginScrub(bool wasPlaying) async {
    if (_isDisposing) {
      return;
    }

    // A scrub may start while a segment loads: the seek it commits is queued
    // by _seekGlobal. During an auto-advance the finished segment reports
    // "not playing", but playback is meant to continue.
    _resumeAfterScrub = wasPlaying || _isSwitchingSegment;
    _isScrubbing = true;
    _scrubPreviewPosition = _globalPosition();
    if (wasPlaying) {
      await _stopPlayback();
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _updateScrubPreview(Duration target) {
    if (_isDisposing) {
      return;
    }

    _scrubPreviewPosition = _clampDuration(target, _totalDuration);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _commitScrub(Duration target) async {
    if (_isDisposing) {
      return;
    }

    final shouldResume = _resumeAfterScrub;
    _isScrubbing = false;
    _resumeAfterScrub = false;
    _scrubPreviewPosition = null;
    if (mounted) {
      setState(() {});
    }
    await _seekGlobal(target, shouldResume: shouldResume);
  }

  /// Commits a seekbar release at [valueMs]. A release within
  /// [_markerTapTolerancePx] of a marker snaps to that marker, so a tap on a
  /// marker issues exactly one seek.
  Future<void> _commitSeekbarValue(double valueMs, double sliderWidth) async {
    final totalMs = _totalDuration.inMilliseconds;
    final toleranceMs = sliderWidth > 0
        ? _markerTapTolerancePx / sliderWidth * totalMs
        : 0.0;
    final marker = nearestMarker(
      markers: _timelineMarkers(),
      valueMs: valueMs.round(),
      toleranceMs: toleranceMs,
    );
    final target = Duration(milliseconds: marker?.elapsedMs ?? valueMs.round());
    await _commitScrub(target);
    if (marker == null || !mounted) {
      return;
    }
    final markerLabel = marker.type == PlaybackMarkerType.incident
        ? 'incident'
        : 'locked';
    _showMessage(
      'Jumped to $markerLabel marker at ${_formatDuration(target)}',
      duration: const Duration(milliseconds: 1200),
      replaceCurrent: true,
    );
  }

  void _toggleFullscreenPlayback() {
    if (!mounted) {
      return;
    }
    setState(() {
      _isFullscreenPlayback = !_isFullscreenPlayback;
    });
  }

  List<PlaybackMarker> _timelineMarkers() {
    return <PlaybackMarker>[
      for (final marker in _incidentMarkerMs)
        PlaybackMarker(elapsedMs: marker, type: PlaybackMarkerType.incident),
      for (final marker in _lockMarkerMs)
        PlaybackMarker(elapsedMs: marker, type: PlaybackMarkerType.locked),
    ]..sort((a, b) => a.elapsedMs.compareTo(b.elapsedMs));
  }

  Duration _clampDuration(Duration value, Duration max) {
    if (value < Duration.zero) {
      return Duration.zero;
    }
    if (value > max) {
      return max;
    }
    return value;
  }

  String _formatDuration(Duration value) => formatElapsed(value);

  Widget _buildOverlay(TelemetryData sample) {
    return Positioned(
      left: 12,
      right: 12,
      bottom: 84,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _stat('Speed', '${sample.speed.toStringAsFixed(1)} km/h'),
            _stat('Dist', '${sample.distanceKm.toStringAsFixed(2)} km'),
            _stat('G', sample.accelerationG.toStringAsFixed(2)),
            _stat(
              'GPS',
              '${sample.latitude.toStringAsFixed(5)}, ${sample.longitude.toStringAsFixed(5)}',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeedGraph(
    Duration position,
    Duration duration, {
    required bool isPlaying,
  }) {
    if (widget.ride.samples.isEmpty) {
      return const SizedBox.shrink();
    }

    final graphDurationMs = math.max(
      duration.inMilliseconds,
      widget.ride.samples.last.elapsedMs,
    );

    return Positioned(
      left: 12,
      right: 12,
      bottom: 12,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: SizedBox(
          width: double.infinity,
          height: 56,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Semantics(
                label: 'Speed graph',
                hint: 'Tap or drag horizontally to seek',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) {
                    if (_isDisposing) {
                      return;
                    }
                    final target = speedGraphTapTarget(
                      dx: details.localPosition.dx,
                      width: constraints.maxWidth,
                      currentPosition: position,
                      totalDuration: _totalDuration,
                    );
                    unawaited(_seekGlobal(target, shouldResume: isPlaying));
                  },
                  onHorizontalDragStart: (details) {
                    if (_isDisposing) {
                      return;
                    }
                    _graphDragAnchor = position;
                    _graphDragStartDx = details.localPosition.dx;
                    unawaited(_beginScrub(isPlaying));
                  },
                  onHorizontalDragUpdate: (details) {
                    final anchor = _graphDragAnchor;
                    if (anchor == null) {
                      return;
                    }
                    final target = speedGraphDragTarget(
                      startDx: _graphDragStartDx,
                      dx: details.localPosition.dx,
                      width: constraints.maxWidth,
                      anchorPosition: anchor,
                      totalDuration: _totalDuration,
                    );
                    _updateScrubPreview(target);
                  },
                  onHorizontalDragEnd: (_) {
                    if (_graphDragAnchor == null) {
                      return;
                    }
                    _graphDragAnchor = null;
                    final target = _scrubPreviewPosition ?? position;
                    unawaited(_commitScrub(target));
                  },
                  child: CustomPaint(
                    painter: _SpeedGraphPainter(
                      samples: widget.ride.samples,
                      maxSpeed: _maxSampleSpeed,
                      currentPositionMs: position.inMilliseconds,
                      totalDurationMs: graphDurationMs,
                      incidentMarkerMs: _incidentMarkerMs,
                      lockMarkerMs: _lockMarkerMs,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _legendEntry(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ],
    );
  }

  Widget _buildPlaybackError(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, size: 48, color: Colors.white54),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Back'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _retryPlayback,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final playbackError = _playbackError;

    return Scaffold(
      appBar: _isFullscreenPlayback
          ? null
          : AppBar(title: const Text('Ride Playback')),
      body: playbackError != null
          ? _buildPlaybackError(playbackError)
          : _isLoading || controller == null
          ? const Center(child: CircularProgressIndicator())
          : ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                final position = _isScrubbing
                    ? (_scrubPreviewPosition ?? _globalPosition())
                    : _globalPosition();
                final duration = _totalDuration;
                final sample = widget.ride.sampleForPosition(position);
                final viewportHeight = MediaQuery.sizeOf(context).height;
                final mapHeight = (viewportHeight * 0.14)
                    .clamp(90.0, 130.0)
                    .toDouble();
                final showPlaybackChrome = !_isFullscreenPlayback;

                return Column(
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          Center(
                            child: AspectRatio(
                              aspectRatio: controller.value.aspectRatio,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: _toggleFullscreenPlayback,
                                child: VideoPlayer(controller),
                              ),
                            ),
                          ),
                          if (showPlaybackChrome &&
                              widget.ride.samples.isNotEmpty)
                            _buildOverlay(sample),
                          if (showPlaybackChrome &&
                              widget.ride.samples.isNotEmpty)
                            _buildSpeedGraph(
                              position,
                              duration,
                              isPlaying: value.isPlaying,
                            ),
                          Positioned(
                            top: 10,
                            right: 10,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.45),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: IconButton(
                                onPressed: _toggleFullscreenPlayback,
                                icon: Icon(
                                  _isFullscreenPlayback
                                      ? Icons.fullscreen_exit
                                      : Icons.fullscreen,
                                  color: Colors.white,
                                ),
                                tooltip: _isFullscreenPlayback
                                    ? 'Exit fullscreen'
                                    : 'Fullscreen',
                              ),
                            ),
                          ),
                          if (_isFullscreenPlayback)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 14,
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.45),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Text(
                                    'Tap video to show controls',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (showPlaybackChrome && widget.ride.samples.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Semantics(
                              button: true,
                              expanded: _showRouteMap,
                              label: 'Route map',
                              onTap: _toggleRouteMapVisibility,
                              excludeSemantics: true,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: _toggleRouteMapVisibility,
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    minHeight: 48,
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.map_outlined,
                                        size: 16,
                                        color: Colors.white70,
                                      ),
                                      const SizedBox(width: 8),
                                      const Text(
                                        'Route Map',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const Spacer(),
                                      Icon(
                                        _showRouteMap
                                            ? Icons.expand_less
                                            : Icons.expand_more,
                                        color: Colors.white70,
                                        size: 18,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            // The map is only built while expanded: a
                            // built map fetches tiles from the network.
                            AnimatedSize(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOut,
                              alignment: Alignment.topCenter,
                              child: _showRouteMap
                                  ? Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: RouteMapView(
                                        telemetryData: widget.ride.samples,
                                        height: mapHeight,
                                        currentSample: sample,
                                      ),
                                    )
                                  : const SizedBox(width: double.infinity),
                            ),
                          ],
                        ),
                      ),
                    if (showPlaybackChrome)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                        child: Column(
                          children: [
                            SizedBox(
                              height: 34,
                              child: LayoutBuilder(
                                builder: (context, sliderConstraints) {
                                  return SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackShape: PlaybackSeekbarTrackShape(
                                        totalDurationMs:
                                            duration.inMilliseconds,
                                        missingRanges: _missingSegmentRanges,
                                        failedCheckRanges: _failedCheckRanges,
                                        noVideoRanges: _noVideoRanges,
                                        incidentMarkerMs: _incidentMarkerMs,
                                        lockMarkerMs: _lockMarkerMs,
                                      ),
                                    ),
                                    child: Slider(
                                      min: 0,
                                      max: duration.inMilliseconds > 0
                                          ? duration.inMilliseconds.toDouble()
                                          : 1,
                                      value: position.inMilliseconds
                                          .clamp(
                                            0,
                                            duration.inMilliseconds > 0
                                                ? duration.inMilliseconds
                                                : 1,
                                          )
                                          .toDouble(),
                                      onChangeStart:
                                          duration.inMilliseconds <= 0
                                          ? null
                                          : (_) {
                                              if (_isDisposing) {
                                                return;
                                              }
                                              unawaited(
                                                _beginScrub(value.isPlaying),
                                              );
                                            },
                                      onChanged: duration.inMilliseconds <= 0
                                          ? null
                                          : (newValue) {
                                              _updateScrubPreview(
                                                Duration(
                                                  milliseconds: newValue
                                                      .round(),
                                                ),
                                              );
                                            },
                                      onChangeEnd: duration.inMilliseconds <= 0
                                          ? null
                                          : (newValue) {
                                              unawaited(
                                                _commitSeekbarValue(
                                                  newValue,
                                                  sliderConstraints.maxWidth,
                                                ),
                                              );
                                            },
                                    ),
                                  );
                                },
                              ),
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(_formatDuration(position)),
                                Text(_formatDuration(duration)),
                              ],
                            ),
                            if (_incidentMarkerMs.isNotEmpty ||
                                _lockMarkerMs.isNotEmpty ||
                                _missingSegmentRanges.isNotEmpty ||
                                _failedCheckRanges.isNotEmpty ||
                                _noVideoRanges.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Wrap(
                                    alignment: WrapAlignment.end,
                                    spacing: 12,
                                    runSpacing: 4,
                                    children: [
                                      if (_noVideoRanges.isNotEmpty)
                                        _legendEntry(noVideoColor, 'No video'),
                                      if (_missingSegmentRanges.isNotEmpty)
                                        _legendEntry(
                                          missingFootageColor,
                                          'Missing segment',
                                        ),
                                      if (_failedCheckRanges.isNotEmpty)
                                        _legendEntry(
                                          failedCheckColor,
                                          'Failed integrity check',
                                        ),
                                      if (_incidentMarkerMs.isNotEmpty)
                                        _legendEntry(
                                          incidentMarkerColor,
                                          'Incident',
                                        ),
                                      if (_lockMarkerMs.isNotEmpty)
                                        _legendEntry(lockMarkerColor, 'Locked'),
                                    ],
                                  ),
                                ),
                              ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                IconButton(
                                  tooltip: 'Back 10 seconds',
                                  onPressed: () async {
                                    final target =
                                        position - const Duration(seconds: 10);
                                    await _seekGlobal(
                                      target,
                                      shouldResume: value.isPlaying,
                                    );
                                  },
                                  icon: const Icon(Icons.replay_10),
                                ),
                                IconButton(
                                  tooltip: controller.value.isPlaying
                                      ? 'Pause'
                                      : 'Play',
                                  onPressed: () {
                                    if (controller.value.isPlaying) {
                                      unawaited(controller.pause());
                                    } else {
                                      unawaited(controller.play());
                                    }
                                  },
                                  icon: Icon(
                                    controller.value.isPlaying
                                        ? Icons.pause_circle
                                        : Icons.play_circle,
                                    size: 36,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Forward 10 seconds',
                                  onPressed: () async {
                                    final target =
                                        position + const Duration(seconds: 10);
                                    await _seekGlobal(
                                      target,
                                      shouldResume: value.isPlaying,
                                    );
                                  },
                                  icon: const Icon(Icons.forward_10),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Segment ${_activeSegmentIndex + 1}/${_segmentPaths.length}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }

  @override
  void dispose() {
    _isDisposing = true;
    _loadGeneration++;
    _pendingSeek = null;
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_onControllerTick);
      unawaited(_stopAndDisposeController(controller));
    }
    super.dispose();
  }
}

class _SpeedGraphPainter extends CustomPainter {
  const _SpeedGraphPainter({
    required this.samples,
    required this.maxSpeed,
    required this.currentPositionMs,
    required this.totalDurationMs,
    required this.incidentMarkerMs,
    required this.lockMarkerMs,
  });

  final List<TelemetryData> samples;
  final double maxSpeed;
  final int currentPositionMs;
  final int totalDurationMs;
  final List<int> incidentMarkerMs;
  final List<int> lockMarkerMs;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2 || totalDurationMs <= 0) {
      return;
    }

    final path = Path();
    final points = <Offset>[];
    final centerX = size.width / 2;
    final windowMs = speedGraphWindowMs(totalDurationMs);
    final halfWindowMs = windowMs / 2;
    var started = false;

    void drawEventMarkers(List<int> markers, Color color) {
      if (markers.isEmpty) {
        return;
      }
      final paint = Paint()
        ..color = color.withValues(alpha: 0.85)
        ..strokeWidth = 1.2;
      for (final marker in markers) {
        final relativeMs = marker - currentPositionMs;
        if (relativeMs.abs() > halfWindowMs + 2500) {
          continue;
        }
        final x = centerX + (relativeMs / windowMs) * size.width;
        if (x < 0 || x > size.width) {
          continue;
        }
        canvas.drawLine(
          Offset(x, size.height - 10),
          Offset(x, size.height),
          paint,
        );
      }
    }

    drawEventMarkers(lockMarkerMs, lockMarkerColor);
    drawEventMarkers(incidentMarkerMs, incidentMarkerColor);

    // Only walk the samples inside the visible window (plus a small margin).
    final marginMs = (windowMs * 2 / math.max(size.width, 1)).ceil() + 1;
    final firstIndex = firstSampleIndexAtOrAfter(
      samples,
      currentPositionMs - halfWindowMs.ceil() - marginMs,
    );
    final lastVisibleMs = currentPositionMs + halfWindowMs.ceil() + marginMs;
    for (var i = firstIndex; i < samples.length; i++) {
      final sample = samples[i];
      if (sample.elapsedMs > lastVisibleMs) {
        break;
      }
      final relativeMs = sample.elapsedMs - currentPositionMs;
      final x = centerX + (relativeMs / windowMs) * size.width;
      if (x < -2 || x > size.width + 2) {
        continue;
      }
      final y =
          size.height - ((sample.speed / maxSpeed) * (size.height - 8)) - 4;
      final point = Offset(x, y);
      points.add(point);
      if (!started) {
        path.moveTo(point.dx, point.dy);
        started = true;
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }

    if (!started) {
      return;
    }

    final speedPaint = Paint()
      ..color = Colors.cyanAccent.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, speedPaint);

    final dotPaint = Paint()
      ..color = Colors.cyanAccent.withValues(alpha: 0.95)
      ..style = PaintingStyle.fill;
    for (final point in points) {
      canvas.drawCircle(point, 1.7, dotPaint);
    }

    // Highlight the sample closest to current timeline position.
    var closestPoint = points.first;
    var smallestDistance = (closestPoint.dx - centerX).abs();
    for (final point in points.skip(1)) {
      final distance = (point.dx - centerX).abs();
      if (distance < smallestDistance) {
        closestPoint = point;
        smallestDistance = distance;
      }
    }

    final focusPaint = Paint()
      ..color = Colors.orangeAccent
      ..style = PaintingStyle.fill;
    canvas.drawCircle(closestPoint, 2.8, focusPaint);
  }

  @override
  bool shouldRepaint(covariant _SpeedGraphPainter oldDelegate) {
    return oldDelegate.currentPositionMs != currentPositionMs ||
        oldDelegate.totalDurationMs != totalDurationMs ||
        oldDelegate.maxSpeed != maxSpeed ||
        !identical(oldDelegate.samples, samples) ||
        !identical(oldDelegate.lockMarkerMs, lockMarkerMs) ||
        !identical(oldDelegate.incidentMarkerMs, incidentMarkerMs);
  }
}

class _SegmentProbeResult {
  const _SegmentProbeResult({required this.duration, this.error});

  final Duration duration;
  final String? error;
}
