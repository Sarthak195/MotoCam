import 'dart:io';
import 'dart:math' as math;
import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../telemetry/models/telemetry_data.dart';
import 'models/ride_record.dart';
import '../map/widgets/static_map_viewer.dart';

class RidePlaybackScreen extends StatefulWidget {
  const RidePlaybackScreen({super.key, required this.ride});

  final RideRecord ride;

  @override
  State<RidePlaybackScreen> createState() => _RidePlaybackScreenState();
}

class _RidePlaybackScreenState extends State<RidePlaybackScreen>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _isLoading = true;
  bool _isDisposing = false;
  final List<String> _segmentPaths = <String>[];
  final List<Duration> _segmentDurations = <Duration>[];
  final List<Duration> _segmentOffsets = <Duration>[];
  Duration _totalDuration = Duration.zero;
  Duration _lastKnownGlobalPosition = Duration.zero;
  Duration? _scrubPreviewPosition;
  int _activeSegmentIndex = 0;
  bool _isSwitchingSegment = false;
  bool _isSeekingAcrossSegments = false;
  bool _isScrubbing = false;
  bool _resumeAfterScrub = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializePlayback();
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
    final candidates = <String>[];
    candidates.addAll(widget.ride.segmentPaths);
    if (!candidates.contains(widget.ride.videoPath)) {
      candidates.add(widget.ride.videoPath);
    }

    _segmentPaths.clear();
    for (final path in candidates) {
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
    for (final path in _segmentPaths) {
      final duration = await _probeDuration(path);
      if (duration > Duration.zero) {
        validPaths.add(path);
        _segmentDurations.add(duration);
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

    _segmentOffsets.clear();
    var accumulated = Duration.zero;
    for (final segmentDuration in _segmentDurations) {
      _segmentOffsets.add(accumulated);
      accumulated += segmentDuration;
    }
    _totalDuration = accumulated;
    _lastKnownGlobalPosition = Duration.zero;

    await _loadSegment(index: 0, autoPlay: false);
    if (!mounted) {
      return;
    }
    setState(() {
      _isLoading = false;
    });
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
        _segmentOffsets[_activeSegmentIndex] + _segmentDurations[_activeSegmentIndex],
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

  Future<void> _stopAndDisposeController(VideoPlayerController controller) async {
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

  Future<void> _seekGlobal(Duration target, {required bool shouldResume}) async {
    if (_isDisposing || _segmentPaths.isEmpty || _totalDuration == Duration.zero) {
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
      await _loadSegment(
        index: seekTarget.segmentIndex,
        autoPlay: false,
        initialPosition: seekTarget.localPosition,
      );
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
    final windowMs = _graphWindowMs(_totalDuration.inMilliseconds).inMilliseconds;
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
      if (position < end || index == _segmentDurations.length - 1) {
        return _SegmentSeekTarget(
          segmentIndex: index,
          localPosition: position - start,
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
      bottom: 68,
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
            _stat('GPS', '${sample.latitude.toStringAsFixed(5)}, ${sample.longitude.toStringAsFixed(5)}'),
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

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            height: 68,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) {
                    if (_isDisposing || _isSwitchingSegment || _isSeekingAcrossSegments) {
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
                    if (_isDisposing || _isSwitchingSegment || _isSeekingAcrossSegments) {
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
                    ),
                  ),
                );
              },
            ),
          ),
        ],
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
        appBar: AppBar(title: const Text('Ride Playback')),
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

                return Column(
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          Center(
                            child: AspectRatio(
                              aspectRatio: controller.value.aspectRatio,
                              child: VideoPlayer(controller),
                            ),
                          ),
                          if (widget.ride.samples.isNotEmpty) _buildOverlay(sample),
                        ],
                      ),
                    ),
                    // Route map viewer
                    if (widget.ride.samples.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Route Map',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            StaticMapViewer(
                              telemetryData: widget.ride.samples,
                              width: double.infinity,
                              height: 130,
                            ),
                          ],
                        ),
                      ),
                    if (widget.ride.samples.isNotEmpty)
                      _buildSpeedGraph(
                        position,
                        duration,
                        isPlaying: value.isPlaying,
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Column(
                        children: [
                          Slider(
                            min: 0,
                            max: duration.inMilliseconds > 0
                                ? duration.inMilliseconds.toDouble()
                                : 1,
                            value: position.inMilliseconds
                                .clamp(0, duration.inMilliseconds > 0 ? duration.inMilliseconds : 1)
                                .toDouble(),
                            onChangeStart: duration.inMilliseconds <= 0
                                ? null
                                : (_) {
                                    if (_isDisposing || _isSwitchingSegment || _isSeekingAcrossSegments) {
                                      return;
                                    }
                                    _beginScrub(value.isPlaying);
                                  },
                            onChanged: duration.inMilliseconds <= 0
                                ? null
                                : (newValue) {
                                    _updateScrubPreview(
                                      Duration(milliseconds: newValue.round()),
                                    );
                                  },
                            onChangeEnd: duration.inMilliseconds <= 0
                                ? null
                                : (newValue) {
                                    _commitScrub(
                                      Duration(milliseconds: newValue.round()),
                                    );
                                  },
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(_formatDuration(position)),
                              Text(_formatDuration(duration)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                onPressed: () async {
                                  final target = position - const Duration(seconds: 10);
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
                                  controller.value.isPlaying ? Icons.pause_circle : Icons.play_circle,
                                  size: 36,
                                ),
                              ),
                              IconButton(
                                onPressed: () async {
                                  final target = position + const Duration(seconds: 10);
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
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
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
  });

  final List<TelemetryData> samples;
  final int currentPositionMs;
  final int totalDurationMs;

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = Colors.white.withValues(alpha: 0.04);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      bgPaint,
    );

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
    final centerX = size.width / 2;
    final windowMs = math.max(10000, math.min(totalDurationMs, 60000));
    var started = false;

    for (var i = 0; i < samples.length; i++) {
      final sample = samples[i];
      final relativeMs = sample.elapsedMs - currentPositionMs;
      final x = centerX + (relativeMs / windowMs) * size.width;
      if (x < -2 || x > size.width + 2) {
        continue;
      }
      final y = size.height - ((sample.speed / maxSpeed) * (size.height - 8)) - 4;
      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
    }

    final speedPaint = Paint()
      ..color = Colors.cyanAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawPath(path, speedPaint);

    final markerPaint = Paint()
      ..color = Colors.orangeAccent
      ..strokeWidth = 2;
    canvas.drawLine(Offset(centerX, 0), Offset(centerX, size.height), markerPaint);
  }

  @override
  bool shouldRepaint(covariant _SpeedGraphPainter oldDelegate) {
    return oldDelegate.currentPositionMs != currentPositionMs ||
        oldDelegate.totalDurationMs != totalDurationMs ||
        oldDelegate.samples.length != samples.length;
  }
}

class _SegmentSeekTarget {
  const _SegmentSeekTarget({
    required this.segmentIndex,
    required this.localPosition,
  });

  final int segmentIndex;
  final Duration localPosition;
}