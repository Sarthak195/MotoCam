import 'dart:io';

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

class _RidePlaybackScreenState extends State<RidePlaybackScreen> {
  VideoPlayerController? _controller;
  bool _isLoading = true;
  final List<String> _segmentPaths = <String>[];
  final List<Duration> _segmentDurations = <Duration>[];
  final List<Duration> _segmentOffsets = <Duration>[];
  Duration _totalDuration = Duration.zero;
  int _activeSegmentIndex = 0;
  bool _isSwitchingSegment = false;
  bool _isSeekingAcrossSegments = false;

  @override
  void initState() {
    super.initState();
    _initializePlayback();
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
    for (final path in _segmentPaths) {
      _segmentDurations.add(await _probeDuration(path));
    }

    _segmentOffsets.clear();
    var accumulated = Duration.zero;
    for (final segmentDuration in _segmentDurations) {
      _segmentOffsets.add(accumulated);
      accumulated += segmentDuration;
    }
    _totalDuration = accumulated;

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
    } finally {
      await probe.dispose();
    }
  }

  Future<void> _loadSegment({
    required int index,
    required bool autoPlay,
    Duration initialPosition = Duration.zero,
  }) async {
    if (index < 0 || index >= _segmentPaths.length) {
      return;
    }

    final previous = _controller;
    if (previous != null) {
      previous.removeListener(_onControllerTick);
      await previous.dispose();
    }

    final controller = VideoPlayerController.file(File(_segmentPaths[index]));
    await controller.initialize();
    controller.setLooping(false);

    final clampedPosition = _clampDuration(initialPosition, controller.value.duration);
    if (clampedPosition > Duration.zero) {
      await controller.seekTo(clampedPosition);
    }

    controller.addListener(_onControllerTick);

    if (!mounted) {
      await controller.dispose();
      return;
    }

    setState(() {
      _controller = controller;
      _activeSegmentIndex = index;
    });

    if (autoPlay) {
      await controller.play();
    }
  }

  void _onControllerTick() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    if (controller.value.isCompleted &&
        _activeSegmentIndex < _segmentPaths.length - 1 &&
        !_isSwitchingSegment &&
        !_isSeekingAcrossSegments) {
      _advanceToNextSegment();
    }
  }

  Future<void> _advanceToNextSegment() async {
    if (_isSwitchingSegment) {
      return;
    }

    final nextIndex = _activeSegmentIndex + 1;
    if (nextIndex >= _segmentPaths.length) {
      return;
    }

    _isSwitchingSegment = true;
    try {
      await _loadSegment(index: nextIndex, autoPlay: true);
    } finally {
      _isSwitchingSegment = false;
    }
  }

  Duration _globalPosition() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return Duration.zero;
    }

    final offset = _activeSegmentIndex < _segmentOffsets.length
        ? _segmentOffsets[_activeSegmentIndex]
        : Duration.zero;
    return offset + controller.value.position;
  }

  Future<void> _seekGlobal(Duration target, {required bool shouldResume}) async {
    if (_segmentPaths.isEmpty || _totalDuration == Duration.zero) {
      return;
    }

    final safeTarget = _clampDuration(target, _totalDuration);
    final seekTarget = _locateSegmentForGlobalPosition(safeTarget);
    final current = _controller;
    if (current == null) {
      return;
    }

    if (seekTarget.segmentIndex == _activeSegmentIndex) {
      await current.seekTo(seekTarget.localPosition);
      if (shouldResume) {
        await current.play();
      }
      return;
    }

    _isSeekingAcrossSegments = true;
    try {
      await _loadSegment(
        index: seekTarget.segmentIndex,
        autoPlay: false,
        initialPosition: seekTarget.localPosition,
      );
      if (shouldResume) {
        await _controller?.play();
      }
    } finally {
      _isSeekingAcrossSegments = false;
    }
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

    return Scaffold(
      appBar: AppBar(title: const Text('Ride Playback')),
      body: _isLoading || controller == null
          ? const Center(child: CircularProgressIndicator())
          : ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                final position = _globalPosition();
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
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                              height: 200,
                            ),
                          ],
                        ),
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
                            onChanged: duration.inMilliseconds <= 0
                                ? null
                                : (newValue) {
                                    _seekGlobal(
                                      Duration(milliseconds: newValue.round()),
                                      shouldResume: value.isPlaying,
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
    );
  }

  @override
  void dispose() {
    _controller?.removeListener(_onControllerTick);
    _controller?.dispose();
    super.dispose();
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