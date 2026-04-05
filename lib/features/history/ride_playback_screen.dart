import 'dart:io';
import 'dart:math' as math;
import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../telemetry/models/telemetry_data.dart';
import 'models/ride_record.dart';
import 'widgets/route_map_view.dart';

class RidePlaybackScreen extends StatefulWidget {
  const RidePlaybackScreen({super.key, required this.ride});

  final RideRecord ride;

  @override
  State<RidePlaybackScreen> createState() => _RidePlaybackScreenState();
}

class _RidePlaybackScreenState extends State<RidePlaybackScreen>
    with WidgetsBindingObserver {
  static const String _showRouteMapPrefKey = 'ride_playback_show_route_map';

  VideoPlayerController? _controller;
  bool _isLoading = true;
  bool _isDisposing = false;
  final List<String> _segmentPaths = <String>[];
  final List<Duration> _segmentDurations = <Duration>[];
  final List<Duration> _segmentOffsets = <Duration>[];
  final Map<String, Duration> _segmentStartOffsetsByPath = <String, Duration>{};
  Duration _totalDuration = Duration.zero;
  Duration _lastKnownGlobalPosition = Duration.zero;
  Duration? _scrubPreviewPosition;
  int _activeSegmentIndex = 0;
  bool _isSwitchingSegment = false;
  bool _isSeekingAcrossSegments = false;
  bool _isScrubbing = false;
  bool _resumeAfterScrub = false;
  bool _showRouteMap = false;
  bool _isFullscreenPlayback = false;
  List<int> _lockMarkerMs = const <int>[];
  List<int> _incidentMarkerMs = const <int>[];
  List<_MissingSegmentRange> _missingSegmentRanges =
      const <_MissingSegmentRange>[];
  Offset? _timelineTapStartLocal;
  bool _timelineTapMoved = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadPlaybackPreferences());
    _initializePlayback();
  }

  Future<void> _loadPlaybackPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final showRouteMap = prefs.getBool(_showRouteMapPrefKey) ?? false;
    if (!mounted || showRouteMap == _showRouteMap) {
      return;
    }
    setState(() {
      _showRouteMap = showRouteMap;
    });
  }

  Future<void> _persistShowRouteMap(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showRouteMapPrefKey, value);
  }

  void _toggleRouteMapVisibility() {
    setState(() {
      _showRouteMap = !_showRouteMap;
    });
    unawaited(_persistShowRouteMap(_showRouteMap));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _stopPlayback();
    }
  }

  Future<void> _initializePlayback() async {
    final declaredPaths = _orderedDeclaredSegmentPaths();

    _segmentPaths.clear();
    for (final path in declaredPaths) {
      final file = File(path);
      if (await file.exists()) {
        _segmentPaths.add(path);
      }
    }

    if (_segmentPaths.isEmpty) {
      setState(() {
        _isLoading = false;
      });
      return;
    }

    _segmentDurations.clear();
    final validPaths = <String>[];
    final availableDurationsByPath = <String, Duration>{};
    for (final path in _segmentPaths) {
      final duration = await _probeDuration(path);
      if (duration > Duration.zero) {
        validPaths.add(path);
        _segmentDurations.add(duration);
        availableDurationsByPath[path] = duration;
      }
    }
    _segmentPaths
      ..clear()
      ..addAll(validPaths);

    if (_segmentPaths.isEmpty) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
      });
      return;
    }

    final effectiveTimeline = _buildEffectiveTimelineEntries(
      declaredPaths: declaredPaths,
      availableDurationsByPath: availableDurationsByPath,
    );
    _missingSegmentRanges = _buildMissingSegmentRanges(
      timelineEntries: effectiveTimeline,
      availablePaths: availableDurationsByPath.keys.toSet(),
    );

    _segmentOffsets.clear();
    _segmentStartOffsetsByPath.clear();

    final timelineByPath = <String, RideSegmentTimelineEntry>{
      for (final entry in effectiveTimeline) entry.path: entry,
    };

    var runningFallbackOffset = Duration.zero;
    var maxSegmentEnd = Duration.zero;
    for (var index = 0; index < _segmentPaths.length; index++) {
      final path = _segmentPaths[index];
      final duration = _segmentDurations[index];
      final timelineEntry = timelineByPath[path];

      var offset = timelineEntry != null
          ? Duration(milliseconds: timelineEntry.startMs)
          : runningFallbackOffset;
      if (offset < Duration.zero) {
        offset = Duration.zero;
      }
      if (_segmentOffsets.isNotEmpty && offset < _segmentOffsets.last) {
        offset = _segmentOffsets.last;
      }

      _segmentOffsets.add(offset);
      _segmentStartOffsetsByPath[path] = offset;

      final segmentEnd = offset + duration;
      final timelineEnd = timelineEntry == null
          ? segmentEnd
          : Duration(milliseconds: timelineEntry.endMs);
      final effectiveEnd = timelineEnd > segmentEnd ? timelineEnd : segmentEnd;

      if (effectiveEnd > maxSegmentEnd) {
        maxSegmentEnd = effectiveEnd;
      }
      final nextFallback = effectiveEnd;
      if (nextFallback > runningFallbackOffset) {
        runningFallbackOffset = nextFallback;
      }
    }

    final telemetryDuration = widget.ride.samples.isNotEmpty
        ? Duration(milliseconds: widget.ride.samples.last.elapsedMs)
        : Duration.zero;
    var timelineMaxEndMs = 0;
    for (final entry in effectiveTimeline) {
      if (entry.endMs > timelineMaxEndMs) {
        timelineMaxEndMs = entry.endMs;
      }
    }
    final timelineDuration = Duration(milliseconds: timelineMaxEndMs);

    _totalDuration = telemetryDuration;
    if (maxSegmentEnd > _totalDuration) {
      _totalDuration = maxSegmentEnd;
    }
    if (timelineDuration > _totalDuration) {
      _totalDuration = timelineDuration;
    }
    _lastKnownGlobalPosition = Duration.zero;
    _lockMarkerMs =
        _buildLockMarkers(totalDurationMs: _totalDuration.inMilliseconds);
    _incidentMarkerMs = _buildIncidentMarkers(
      samples: widget.ride.samples,
      totalDurationMs: _totalDuration.inMilliseconds,
    );

    await _loadSegment(index: 0, autoPlay: false);
    if (!mounted) {
      return;
    }
    setState(() {
      _isLoading = false;
    });
  }

  List<String> _orderedDeclaredSegmentPaths() {
    final ordered = <String>[];
    final seen = <String>{};

    void addPath(String rawPath) {
      final path = rawPath.trim();
      if (path.isEmpty || !seen.add(path)) {
        return;
      }
      ordered.add(path);
    }

    for (final path in widget.ride.segmentPaths) {
      addPath(path);
    }
    addPath(widget.ride.videoPath);
    return ordered;
  }

  List<RideSegmentTimelineEntry> _buildEffectiveTimelineEntries({
    required List<String> declaredPaths,
    required Map<String, Duration> availableDurationsByPath,
  }) {
    final fallbackDurationMs = _estimateFallbackSegmentDurationMs(
      availableDurationsByPath,
      declaredCount: declaredPaths.length,
    );

    if (widget.ride.segmentTimeline.isEmpty) {
      var cursorMs = 0;
      final synthesized = <RideSegmentTimelineEntry>[];
      for (final path in declaredPaths) {
        final durationMs = availableDurationsByPath[path]?.inMilliseconds ??
            fallbackDurationMs;
        final normalizedDurationMs = math.max(durationMs, 1000);
        final endMs = cursorMs + normalizedDurationMs;
        synthesized.add(
          RideSegmentTimelineEntry(path: path, startMs: cursorMs, endMs: endMs),
        );
        cursorMs = endMs;
      }
      return synthesized;
    }

    final merged = <RideSegmentTimelineEntry>[];
    final seenPaths = <String>{};

    for (final entry in widget.ride.segmentTimeline) {
      final path = entry.path.trim();
      if (path.isEmpty || !seenPaths.add(path)) {
        continue;
      }

      final startMs = math.max(entry.startMs, 0);
      final endMs = math.max(entry.endMs, startMs + 1);
      merged.add(
        RideSegmentTimelineEntry(path: path, startMs: startMs, endMs: endMs),
      );
    }

    var appendCursorMs = 0;
    if (merged.isNotEmpty) {
      appendCursorMs =
          merged.map((entry) => entry.endMs).reduce((a, b) => a > b ? a : b);
    }

    for (final path in declaredPaths) {
      if (seenPaths.contains(path)) {
        continue;
      }
      final durationMs =
          availableDurationsByPath[path]?.inMilliseconds ?? fallbackDurationMs;
      final normalizedDurationMs = math.max(durationMs, 1000);
      final endMs = appendCursorMs + normalizedDurationMs;
      merged.add(
        RideSegmentTimelineEntry(
          path: path,
          startMs: appendCursorMs,
          endMs: endMs,
        ),
      );
      appendCursorMs = endMs;
    }

    merged.sort((a, b) => a.startMs.compareTo(b.startMs));
    final normalized = <RideSegmentTimelineEntry>[];
    var cursorMs = 0;
    for (final entry in merged) {
      final startMs = math.max(entry.startMs, cursorMs);
      final endMs = math.max(entry.endMs, startMs + 1);
      normalized.add(
        RideSegmentTimelineEntry(
            path: entry.path, startMs: startMs, endMs: endMs),
      );
      cursorMs = endMs;
    }

    return normalized;
  }

  int _estimateFallbackSegmentDurationMs(
    Map<String, Duration> availableDurationsByPath, {
    required int declaredCount,
  }) {
    final durationsMs = availableDurationsByPath.values
        .map((duration) => duration.inMilliseconds)
        .where((ms) => ms > 0)
        .toList()
      ..sort();

    if (durationsMs.isNotEmpty) {
      return durationsMs[durationsMs.length ~/ 2];
    }

    if (widget.ride.samples.isNotEmpty && declaredCount > 0) {
      final estimated =
          (widget.ride.samples.last.elapsedMs / declaredCount).round();
      return math.max(estimated, 1000);
    }

    return const Duration(minutes: 5).inMilliseconds;
  }

  List<_MissingSegmentRange> _buildMissingSegmentRanges({
    required List<RideSegmentTimelineEntry> timelineEntries,
    required Set<String> availablePaths,
  }) {
    if (timelineEntries.isEmpty) {
      return const <_MissingSegmentRange>[];
    }

    final ranges = <_MissingSegmentRange>[];
    for (final entry in timelineEntries) {
      final path = entry.path.trim();
      if (path.isEmpty) {
        continue;
      }

      if (availablePaths.contains(path)) {
        continue;
      }

      final startMs = entry.startMs;
      final endMs = entry.endMs >= startMs ? entry.endMs : startMs;
      if (endMs <= startMs) {
        continue;
      }

      ranges.add(_MissingSegmentRange(startMs: startMs, endMs: endMs));
    }

    if (ranges.isEmpty) {
      return const <_MissingSegmentRange>[];
    }

    ranges.sort((a, b) => a.startMs.compareTo(b.startMs));
    final merged = <_MissingSegmentRange>[];
    var current = ranges.first;

    for (final next in ranges.skip(1)) {
      if (next.startMs <= current.endMs) {
        current = _MissingSegmentRange(
          startMs: current.startMs,
          endMs: math.max(current.endMs, next.endMs),
        );
      } else {
        merged.add(current);
        current = next;
      }
    }
    merged.add(current);

    return List<_MissingSegmentRange>.unmodifiable(merged);
  }

  Future<Duration> _probeDuration(String path) async {
    final probe = VideoPlayerController.file(File(path));
    try {
      await probe.initialize();
      return probe.value.duration;
    } catch (_) {
      return Duration.zero;
    } finally {
      await probe.dispose();
    }
  }

  Future<bool> _loadSegment({
    required int index,
    required bool autoPlay,
    Duration initialPosition = Duration.zero,
  }) async {
    if (_isDisposing) {
      return false;
    }

    if (index < 0 || index >= _segmentPaths.length) {
      return false;
    }

    final previous = _controller;
    if (previous != null && previous.value.isInitialized) {
      _lastKnownGlobalPosition = _globalPosition();
    }

    final controller = VideoPlayerController.file(File(_segmentPaths[index]));
    try {
      await controller.initialize();
      if (_isDisposing) {
        await _stopAndDisposeController(controller);
        return false;
      }
      controller.setLooping(false);

      final clampedPosition =
          _clampDuration(initialPosition, controller.value.duration);
      if (clampedPosition > Duration.zero) {
        await controller.seekTo(clampedPosition);
      }

      controller.addListener(_onControllerTick);

      if (!mounted || _isDisposing) {
        await _stopAndDisposeController(controller);
        return false;
      }

      if (previous != null) {
        previous.removeListener(_onControllerTick);
      }

      setState(() {
        _controller = controller;
        _activeSegmentIndex = index;
        _lastKnownGlobalPosition = _clampDuration(
          _segmentOffsets[index] + clampedPosition,
          _totalDuration,
        );
      });

      if (autoPlay) {
        await controller.play();
      }

      if (previous != null) {
        // Dispose previous controller after the new one is mounted to avoid
        // transient "used after dispose" during widget handoff.
        unawaited(_stopAndDisposeController(previous));
      }

      return true;
    } catch (_) {
      await _stopAndDisposeController(controller);
      return false;
    }
  }

  void _onControllerTick() {
    if (_isDisposing) {
      return;
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    _lastKnownGlobalPosition = _globalPositionFromController(
      controller,
      _activeSegmentIndex,
    );

    if (controller.value.isCompleted &&
        _activeSegmentIndex < _segmentPaths.length - 1 &&
        !_isSwitchingSegment &&
        !_isSeekingAcrossSegments) {
      _lastKnownGlobalPosition = _clampDuration(
        _segmentOffsets[_activeSegmentIndex] +
            _segmentDurations[_activeSegmentIndex],
        _totalDuration,
      );
      _advanceToNextSegment();
    }
  }

  Future<void> _advanceToNextSegment() async {
    if (_isSwitchingSegment || _isDisposing) {
      return;
    }

    final nextIndex = _activeSegmentIndex + 1;
    if (nextIndex >= _segmentPaths.length) {
      await _stopPlayback();
      return;
    }

    _isSwitchingSegment = true;
    try {
      var candidate = nextIndex;
      while (candidate < _segmentPaths.length && !_isDisposing) {
        final loaded = await _loadSegment(index: candidate, autoPlay: true);
        if (loaded) {
          return;
        }
        candidate++;
      }
      await _stopPlayback();
    } finally {
      _isSwitchingSegment = false;
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
      VideoPlayerController controller) async {
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

  Future<void> _seekGlobal(Duration target,
      {required bool shouldResume}) async {
    if (_isDisposing ||
        _segmentPaths.isEmpty ||
        _totalDuration == Duration.zero) {
      return;
    }

    final safeTarget = _clampDuration(target, _totalDuration);
    _lastKnownGlobalPosition = safeTarget;
    final seekTarget = _locateSegmentForGlobalPosition(safeTarget);
    final current = _controller;
    if (current == null) {
      return;
    }

    if (seekTarget.segmentIndex == _activeSegmentIndex) {
      await current.seekTo(seekTarget.localPosition);
      if (shouldResume && !_isDisposing) {
        await current.play();
      }
      return;
    }

    _isSeekingAcrossSegments = true;
    try {
      if (_isDisposing) {
        return;
      }
      var candidate = seekTarget.segmentIndex;
      var initialPosition = seekTarget.localPosition;
      var loaded = false;

      while (candidate < _segmentPaths.length && !_isDisposing) {
        loaded = await _loadSegment(
          index: candidate,
          autoPlay: false,
          initialPosition: initialPosition,
        );
        if (loaded) {
          break;
        }
        candidate++;
        initialPosition = Duration.zero;
      }

      if (!loaded || _isDisposing) {
        return;
      }

      if (shouldResume && !_isDisposing) {
        await _controller?.play();
      }
    } finally {
      _isSeekingAcrossSegments = false;
    }
  }

  Future<void> _beginScrub(bool wasPlaying) async {
    if (_isDisposing || _isSwitchingSegment || _isSeekingAcrossSegments) {
      return;
    }

    _resumeAfterScrub = wasPlaying;
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

  void _toggleFullscreenPlayback() {
    if (!mounted) {
      return;
    }
    setState(() {
      _isFullscreenPlayback = !_isFullscreenPlayback;
    });
  }

  List<int> _buildLockMarkers({required int totalDurationMs}) {
    if (totalDurationMs <= 0 || _segmentPaths.isEmpty) {
      return const <int>[];
    }

    final lockedPathSet = widget.ride.lockedSegmentPaths.toSet();
    if (lockedPathSet.isEmpty) {
      return const <int>[];
    }

    final markers = <int>{};
    for (final segmentPath in _segmentPaths) {
      if (!lockedPathSet.contains(segmentPath)) {
        continue;
      }
      final markerOffset = _segmentStartOffsetsByPath[segmentPath];
      if (markerOffset == null) {
        continue;
      }

      final marker = markerOffset.inMilliseconds;
      markers.add(marker.clamp(0, totalDurationMs));
    }

    final ordered = markers.toList()..sort();
    return List<int>.unmodifiable(ordered);
  }

  List<int> _buildIncidentMarkers({
    required List<TelemetryData> samples,
    required int totalDurationMs,
  }) {
    if (samples.isEmpty || totalDurationMs <= 0) {
      return const <int>[];
    }

    const incidentThresholdG = 3.2;
    const debounceMs = 5000;
    var lastAcceptedMs = -debounceMs;
    final markers = <int>[];

    for (final sample in samples) {
      if (sample.accelerationG < incidentThresholdG) {
        continue;
      }

      if (sample.elapsedMs - lastAcceptedMs < debounceMs) {
        continue;
      }

      final markerMs = sample.elapsedMs.clamp(0, totalDurationMs);
      markers.add(markerMs);
      lastAcceptedMs = markerMs;
    }

    return List<int>.unmodifiable(markers);
  }

  List<_PlaybackTimelineMarker> _timelineMarkers() {
    final markers = <_PlaybackTimelineMarker>[];
    for (final marker in _incidentMarkerMs) {
      markers.add(
        _PlaybackTimelineMarker(
          elapsedMs: marker,
          type: _PlaybackTimelineMarkerType.incident,
        ),
      );
    }
    for (final marker in _lockMarkerMs) {
      markers.add(
        _PlaybackTimelineMarker(
          elapsedMs: marker,
          type: _PlaybackTimelineMarkerType.locked,
        ),
      );
    }
    markers.sort((a, b) => a.elapsedMs.compareTo(b.elapsedMs));
    return markers;
  }

  _PlaybackTimelineMarker? _nearestTimelineMarkerForTap({
    required double dx,
    required double width,
    required int totalDurationMs,
  }) {
    if (totalDurationMs <= 0 || width <= 0) {
      return null;
    }

    final markers = _timelineMarkers();
    if (markers.isEmpty) {
      return null;
    }

    const tapTolerancePx = 18.0;
    final usableWidth = width - (_TimelineMarkersPainter.horizontalInset * 2);
    if (usableWidth <= 0) {
      return null;
    }

    _PlaybackTimelineMarker? nearest;
    var nearestPx = double.infinity;
    for (final marker in markers) {
      final normalized = (marker.elapsedMs / totalDurationMs).clamp(0.0, 1.0);
      final markerX =
          _TimelineMarkersPainter.horizontalInset + (normalized * usableWidth);
      final distance = (markerX - dx).abs();
      if (distance < nearestPx) {
        nearestPx = distance;
        nearest = marker;
      }
    }

    if (nearest == null || nearestPx > tapTolerancePx) {
      return null;
    }
    return nearest;
  }

  Future<void> _jumpToTimelineMarker({
    required _PlaybackTimelineMarker marker,
    required bool wasPlaying,
  }) async {
    if (_isDisposing || _isSwitchingSegment || _isSeekingAcrossSegments) {
      return;
    }

    final target = Duration(milliseconds: marker.elapsedMs);
    await _seekGlobal(target, shouldResume: wasPlaying);
    if (!mounted) {
      return;
    }

    final markerLabel = marker.type == _PlaybackTimelineMarkerType.incident
        ? 'incident'
        : 'locked';
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Jumped to $markerLabel marker at ${_formatDuration(target)}',
        ),
        duration: const Duration(milliseconds: 1200),
      ),
    );
  }

  Duration _graphWindowMs(int totalMs) {
    return Duration(milliseconds: math.max(10000, math.min(totalMs, 60000)));
  }

  Duration _graphTargetForOffset({
    required double dx,
    required double width,
    required Duration currentPosition,
  }) {
    if (width <= 0 || _totalDuration == Duration.zero) {
      return currentPosition;
    }

    final centerX = width / 2;
    final windowMs =
        _graphWindowMs(_totalDuration.inMilliseconds).inMilliseconds;
    final deltaMs = ((dx - centerX) / width) * windowMs;
    return _clampDuration(
      currentPosition + Duration(milliseconds: deltaMs.round()),
      _totalDuration,
    );
  }

  _SegmentSeekTarget _locateSegmentForGlobalPosition(Duration position) {
    for (var index = 0; index < _segmentDurations.length; index++) {
      final start = _segmentOffsets[index];
      final end = start + _segmentDurations[index];
      if (position <= start) {
        return _SegmentSeekTarget(
          segmentIndex: index,
          localPosition: Duration.zero,
        );
      }
      if (position < end || index == _segmentDurations.length - 1) {
        final localPosition = position - start;
        return _SegmentSeekTarget(
          segmentIndex: index,
          localPosition:
              localPosition > Duration.zero ? localPosition : Duration.zero,
        );
      }
    }

    return const _SegmentSeekTarget(
      segmentIndex: 0,
      localPosition: Duration.zero,
    );
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

  String _formatDuration(Duration value) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = value.inHours;
    return '$hours:$minutes:$seconds';
  }

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
            _stat('GPS',
                '${sample.latitude.toStringAsFixed(5)}, ${sample.longitude.toStringAsFixed(5)}'),
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
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) {
                  if (_isDisposing ||
                      _isSwitchingSegment ||
                      _isSeekingAcrossSegments) {
                    return;
                  }
                  final target = _graphTargetForOffset(
                    dx: details.localPosition.dx,
                    width: constraints.maxWidth,
                    currentPosition: position,
                  );
                  _seekGlobal(target, shouldResume: isPlaying);
                },
                onHorizontalDragStart: (_) {
                  if (_isDisposing ||
                      _isSwitchingSegment ||
                      _isSeekingAcrossSegments) {
                    return;
                  }
                  _beginScrub(isPlaying);
                },
                onHorizontalDragUpdate: (details) {
                  final target = _graphTargetForOffset(
                    dx: details.localPosition.dx,
                    width: constraints.maxWidth,
                    currentPosition: position,
                  );
                  _updateScrubPreview(target);
                },
                onHorizontalDragEnd: (_) {
                  final target = _scrubPreviewPosition ?? position;
                  _commitScrub(target);
                },
                child: CustomPaint(
                  painter: _SpeedGraphPainter(
                    samples: widget.ride.samples,
                    currentPositionMs: position.inMilliseconds,
                    totalDurationMs: graphDurationMs,
                    incidentMarkerMs: _incidentMarkerMs,
                    lockMarkerMs: _lockMarkerMs,
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

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (_, __) {
        // Dispose handles teardown; avoid async playback work during route pop.
      },
      child: Scaffold(
        appBar: _isFullscreenPlayback
            ? null
            : AppBar(title: const Text('Ride Playback')),
        body: _isLoading || controller == null
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
                  final mapHeight =
                      (viewportHeight * 0.14).clamp(90.0, 130.0).toDouble();
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
                                      color:
                                          Colors.black.withValues(alpha: 0.45),
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
                              InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: _toggleRouteMapVisibility,
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
                              AnimatedCrossFade(
                                duration: const Duration(milliseconds: 180),
                                firstCurve: Curves.easeOut,
                                secondCurve: Curves.easeIn,
                                crossFadeState: _showRouteMap
                                    ? CrossFadeState.showFirst
                                    : CrossFadeState.showSecond,
                                firstChild: Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: RouteMapView(
                                    telemetryData: widget.ride.samples,
                                    height: mapHeight,
                                    currentSample: sample,
                                  ),
                                ),
                                secondChild: const SizedBox.shrink(),
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
                                child: Stack(
                                  children: [
                                    SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackShape:
                                            _MissingRangeSliderTrackShape(
                                          missingSegmentRanges:
                                              _missingSegmentRanges,
                                          totalDurationMs:
                                              duration.inMilliseconds,
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
                                                    : 1)
                                            .toDouble(),
                                        onChangeStart: duration
                                                    .inMilliseconds <=
                                                0
                                            ? null
                                            : (_) {
                                                if (_isDisposing ||
                                                    _isSwitchingSegment ||
                                                    _isSeekingAcrossSegments) {
                                                  return;
                                                }
                                                _beginScrub(value.isPlaying);
                                              },
                                        onChanged: duration.inMilliseconds <= 0
                                            ? null
                                            : (newValue) {
                                                _updateScrubPreview(
                                                  Duration(
                                                      milliseconds:
                                                          newValue.round()),
                                                );
                                              },
                                        onChangeEnd:
                                            duration.inMilliseconds <= 0
                                                ? null
                                                : (newValue) {
                                                    _commitScrub(
                                                      Duration(
                                                          milliseconds:
                                                              newValue.round()),
                                                    );
                                                  },
                                      ),
                                    ),
                                    Positioned.fill(
                                      child: LayoutBuilder(
                                        builder: (context, markerConstraints) {
                                          return Stack(
                                            children: [
                                              IgnorePointer(
                                                child: CustomPaint(
                                                  painter:
                                                      _TimelineMarkersPainter(
                                                    totalDurationMs:
                                                        duration.inMilliseconds,
                                                    incidentMarkerMs:
                                                        _incidentMarkerMs,
                                                    lockMarkerMs: _lockMarkerMs,
                                                  ),
                                                ),
                                              ),
                                              Listener(
                                                behavior:
                                                    HitTestBehavior.translucent,
                                                onPointerDown: (event) {
                                                  _timelineTapStartLocal =
                                                      event.localPosition;
                                                  _timelineTapMoved = false;
                                                },
                                                onPointerMove: (event) {
                                                  final start =
                                                      _timelineTapStartLocal;
                                                  if (start == null) {
                                                    return;
                                                  }
                                                  if ((event.localPosition -
                                                              start)
                                                          .distance >
                                                      10) {
                                                    _timelineTapMoved = true;
                                                  }
                                                },
                                                onPointerCancel: (_) {
                                                  _timelineTapStartLocal = null;
                                                  _timelineTapMoved = false;
                                                },
                                                onPointerUp: (event) {
                                                  final moved =
                                                      _timelineTapMoved;
                                                  _timelineTapStartLocal = null;
                                                  _timelineTapMoved = false;
                                                  if (moved) {
                                                    return;
                                                  }
                                                  final marker =
                                                      _nearestTimelineMarkerForTap(
                                                    dx: event.localPosition.dx,
                                                    width: markerConstraints
                                                        .maxWidth,
                                                    totalDurationMs:
                                                        duration.inMilliseconds,
                                                  );
                                                  if (marker == null) {
                                                    return;
                                                  }
                                                  unawaited(
                                                    _jumpToTimelineMarker(
                                                      marker: marker,
                                                      wasPlaying:
                                                          value.isPlaying,
                                                    ),
                                                  );
                                                },
                                              ),
                                            ],
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(_formatDuration(position)),
                                  Text(_formatDuration(duration)),
                                ],
                              ),
                              if (_incidentMarkerMs.isNotEmpty ||
                                  _lockMarkerMs.isNotEmpty ||
                                  _missingSegmentRanges.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      if (_missingSegmentRanges.isNotEmpty) ...[
                                        Container(
                                          width: 8,
                                          height: 8,
                                          decoration: const BoxDecoration(
                                            color: Colors.red,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        const Text(
                                          'Missing segment',
                                          style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                      if (_missingSegmentRanges.isNotEmpty &&
                                          (_incidentMarkerMs.isNotEmpty ||
                                              _lockMarkerMs.isNotEmpty))
                                        const SizedBox(width: 12),
                                      if (_incidentMarkerMs.isNotEmpty) ...[
                                        Container(
                                          width: 8,
                                          height: 8,
                                          decoration: const BoxDecoration(
                                            color: Colors.redAccent,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        const Text(
                                          'Incident',
                                          style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                      if (_incidentMarkerMs.isNotEmpty &&
                                          _lockMarkerMs.isNotEmpty)
                                        const SizedBox(width: 12),
                                      if (_lockMarkerMs.isNotEmpty) ...[
                                        Container(
                                          width: 8,
                                          height: 8,
                                          decoration: const BoxDecoration(
                                            color: Colors.orangeAccent,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        const Text(
                                          'Locked',
                                          style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  IconButton(
                                    onPressed: () async {
                                      final target = position -
                                          const Duration(seconds: 10);
                                      await _seekGlobal(
                                        target,
                                        shouldResume: value.isPlaying,
                                      );
                                    },
                                    icon: const Icon(Icons.replay_10),
                                  ),
                                  IconButton(
                                    onPressed: () {
                                      if (controller.value.isPlaying) {
                                        controller.pause();
                                      } else {
                                        controller.play();
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
                                    onPressed: () async {
                                      final target = position +
                                          const Duration(seconds: 10);
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
                                    color: Colors.white70, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  @override
  void dispose() {
    _isDisposing = true;
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_onControllerTick);
      controller.pause();
      _stopAndDisposeController(controller);
    }
    super.dispose();
  }
}

class _SpeedGraphPainter extends CustomPainter {
  const _SpeedGraphPainter({
    required this.samples,
    required this.currentPositionMs,
    required this.totalDurationMs,
    required this.incidentMarkerMs,
    required this.lockMarkerMs,
  });

  final List<TelemetryData> samples;
  final int currentPositionMs;
  final int totalDurationMs;
  final List<int> incidentMarkerMs;
  final List<int> lockMarkerMs;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2 || totalDurationMs <= 0) {
      return;
    }

    var maxSpeed = 1.0;
    for (final sample in samples) {
      if (sample.speed > maxSpeed) {
        maxSpeed = sample.speed;
      }
    }

    final path = Path();
    final points = <Offset>[];
    final centerX = size.width / 2;
    final windowMs = math.max(10000, math.min(totalDurationMs, 60000));
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

    drawEventMarkers(lockMarkerMs, Colors.orangeAccent);
    drawEventMarkers(incidentMarkerMs, Colors.redAccent);

    for (var i = 0; i < samples.length; i++) {
      final sample = samples[i];
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
        oldDelegate.samples.length != samples.length ||
        oldDelegate.lockMarkerMs.length != lockMarkerMs.length ||
        oldDelegate.incidentMarkerMs.length != incidentMarkerMs.length;
  }
}

class _TimelineMarkersPainter extends CustomPainter {
  static const double horizontalInset = 14.0;

  const _TimelineMarkersPainter({
    required this.totalDurationMs,
    required this.incidentMarkerMs,
    required this.lockMarkerMs,
  });

  final int totalDurationMs;
  final List<int> incidentMarkerMs;
  final List<int> lockMarkerMs;

  @override
  void paint(Canvas canvas, Size size) {
    if (totalDurationMs <= 0) {
      return;
    }

    final usableWidth = size.width - (horizontalInset * 2);
    if (usableWidth <= 0) {
      return;
    }

    void drawMarkers({
      required List<int> markers,
      required Color color,
      required double top,
      required double bottom,
      required double stroke,
    }) {
      if (markers.isEmpty) {
        return;
      }

      final paint = Paint()
        ..color = color.withValues(alpha: 0.9)
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round;

      for (final markerMs in markers) {
        final normalized = (markerMs / totalDurationMs).clamp(0.0, 1.0);
        final x = horizontalInset + (normalized * usableWidth);
        canvas.drawLine(Offset(x, top), Offset(x, bottom), paint);
      }
    }

    drawMarkers(
      markers: lockMarkerMs,
      color: Colors.orangeAccent,
      top: 7,
      bottom: size.height - 6,
      stroke: 2,
    );
    drawMarkers(
      markers: incidentMarkerMs,
      color: Colors.redAccent,
      top: 4,
      bottom: size.height - 9,
      stroke: 2,
    );
  }

  @override
  bool shouldRepaint(covariant _TimelineMarkersPainter oldDelegate) {
    if (oldDelegate.totalDurationMs != totalDurationMs ||
        oldDelegate.incidentMarkerMs.length != incidentMarkerMs.length ||
        oldDelegate.lockMarkerMs.length != lockMarkerMs.length) {
      return true;
    }

    return false;
  }
}

class _MissingRangeSliderTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  const _MissingRangeSliderTrackShape({
    required this.missingSegmentRanges,
    required this.totalDurationMs,
  });

  final List<_MissingSegmentRange> missingSegmentRanges;
  final int totalDurationMs;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    required TextDirection textDirection,
    bool isDiscrete = false,
    bool isEnabled = false,
    Offset? secondaryOffset,
  }) {
    final trackHeight = sliderTheme.trackHeight;
    if (trackHeight == null || trackHeight <= 0) {
      return;
    }

    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (trackRect.width <= 0 || trackRect.height <= 0) {
      return;
    }

    final activeColor = isEnabled
        ? (sliderTheme.activeTrackColor ?? Colors.blueAccent)
        : (sliderTheme.disabledActiveTrackColor ??
            sliderTheme.activeTrackColor ??
            Colors.blueGrey);
    final inactiveColor = isEnabled
        ? (sliderTheme.inactiveTrackColor ?? Colors.white24)
        : (sliderTheme.disabledInactiveTrackColor ??
            sliderTheme.inactiveTrackColor ??
            Colors.white24);

    final canvas = context.canvas;
    final trackRRect = RRect.fromRectAndRadius(
      trackRect,
      Radius.circular(trackRect.height / 2),
    );

    canvas.drawRRect(trackRRect, Paint()..color = inactiveColor);

    final clampedThumbX = thumbCenter.dx.clamp(trackRect.left, trackRect.right);
    final activeRect = textDirection == TextDirection.ltr
        ? Rect.fromLTRB(
            trackRect.left,
            trackRect.top,
            clampedThumbX,
            trackRect.bottom,
          )
        : Rect.fromLTRB(
            clampedThumbX,
            trackRect.top,
            trackRect.right,
            trackRect.bottom,
          );

    if (activeRect.width > 0) {
      canvas.save();
      canvas.clipRRect(trackRRect);
      canvas.drawRect(activeRect, Paint()..color = activeColor);
      canvas.restore();
    }

    if (totalDurationMs <= 0 || missingSegmentRanges.isEmpty) {
      return;
    }

    final missingPaint = Paint()..color = Colors.red.withValues(alpha: 0.86);
    canvas.save();
    canvas.clipRRect(trackRRect);
    for (final range in missingSegmentRanges) {
      if (range.endMs <= range.startMs) {
        continue;
      }

      final startNormalized = (range.startMs / totalDurationMs).clamp(0.0, 1.0);
      final endNormalized = (range.endMs / totalDurationMs).clamp(0.0, 1.0);
      final left = trackRect.left + (trackRect.width * startNormalized);
      final right = trackRect.left + (trackRect.width * endNormalized);
      if (right - left <= 0) {
        continue;
      }

      canvas.drawRect(
        Rect.fromLTRB(left, trackRect.top, right, trackRect.bottom),
        missingPaint,
      );
    }
    canvas.restore();
  }
}

class _MissingSegmentRange {
  const _MissingSegmentRange({
    required this.startMs,
    required this.endMs,
  });

  final int startMs;
  final int endMs;
}

enum _PlaybackTimelineMarkerType { incident, locked }

class _PlaybackTimelineMarker {
  const _PlaybackTimelineMarker({
    required this.elapsedMs,
    required this.type,
  });

  final int elapsedMs;
  final _PlaybackTimelineMarkerType type;
}

class _SegmentSeekTarget {
  const _SegmentSeekTarget({
    required this.segmentIndex,
    required this.localPosition,
  });

  final int segmentIndex;
  final Duration localPosition;
}
