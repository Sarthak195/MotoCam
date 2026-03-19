import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../telemetry/models/telemetry_data.dart';
import 'models/ride_record.dart';

class RidePlaybackScreen extends StatefulWidget {
  const RidePlaybackScreen({super.key, required this.ride});

  final RideRecord ride;

  @override
  State<RidePlaybackScreen> createState() => _RidePlaybackScreenState();
}

class _RidePlaybackScreenState extends State<RidePlaybackScreen> {
  VideoPlayerController? _controller;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    final controller = VideoPlayerController.file(File(widget.ride.videoPath));
    await controller.initialize();
    controller.setLooping(false);
    setState(() {
      _controller = controller;
      _isLoading = false;
    });
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
                final position = value.position;
                final duration = value.duration;
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
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Column(
                        children: [
                          VideoProgressIndicator(
                            controller,
                            allowScrubbing: true,
                            padding: const EdgeInsets.symmetric(vertical: 6),
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
                                  await controller.seekTo(target > Duration.zero ? target : Duration.zero);
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
                                  await controller.seekTo(target < duration ? target : duration);
                                },
                                icon: const Icon(Icons.forward_10),
                              ),
                            ],
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
    _controller?.dispose();
    super.dispose();
  }
}