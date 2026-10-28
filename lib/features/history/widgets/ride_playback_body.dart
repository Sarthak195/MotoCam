import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../telemetry/models/telemetry_data.dart';
import 'playback_controls.dart';
import 'playback_legend.dart';
import 'playback_position.dart';
import 'playback_seek_bar.dart';
import 'playback_speed_graph.dart';
import 'playback_telemetry_overlay.dart';
import 'playback_timeline.dart';
import 'playback_video_area.dart';
import 'route_map_panel.dart';

/// The body of the ride playback screen: the video area with the telemetry
/// overlay and speed graph, the route map card, the seekbar with its legend
/// and the transport controls.
///
/// It is built from explicit values, callbacks and the [position]
/// listenable, and never holds the video controller (the [video] widget
/// does). A playback tick changes only [position], so only the widgets that
/// show the position rebuild: the slider and time label, the telemetry
/// overlay, the speed graph's cursor, the route map's marker and the
/// play/pause button. The map, the speed graph's curve, the legend and this
/// widget do not.
class RidePlaybackBody extends StatefulWidget {
  /// Creates the playback body.
  const RidePlaybackBody({
    super.key,
    required this.video,
    required this.samples,
    required this.maxSpeed,
    required this.sampleAt,
    required this.position,
    required this.totalDuration,
    required this.marks,
    required this.isFullscreen,
    required this.showRouteMap,
    required this.segmentNumber,
    required this.segmentCount,
    required this.onToggleFullscreen,
    required this.onToggleRouteMap,
    required this.onSeek,
    required this.onSeekBy,
    required this.onTogglePlay,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onGraphScrubEnd,
    required this.onSeekbarScrubEnd,
    this.mapBuilder,
  });

  /// The video, usually a [PlaybackVideoSurface].
  final Widget video;

  /// Telemetry samples of the ride; empty hides the telemetry views.
  final List<TelemetryData> samples;

  /// Speed, in km/h, that reaches the top of the speed graph.
  final double maxSpeed;

  /// Returns the (interpolated) telemetry sample for a ride-timeline
  /// position.
  final TelemetryData Function(Duration position) sampleAt;

  /// The playback position and whether the video is playing.
  final ValueListenable<PlaybackPosition> position;

  /// Length of the ride timeline.
  final Duration totalDuration;

  /// The ranges and markers on the seekbar and in the legend.
  final PlaybackTimelineMarks marks;

  /// Whether the screen is in fullscreen playback (no controls).
  final bool isFullscreen;

  /// Whether the route map is expanded.
  final bool showRouteMap;

  /// One-based number of the segment being played.
  final int segmentNumber;

  /// Number of playable segments in the playlist.
  final int segmentCount;

  /// Toggles fullscreen playback.
  final VoidCallback onToggleFullscreen;

  /// Expands or collapses the route map.
  final VoidCallback onToggleRouteMap;

  /// Seeks to a position (a speed-graph tap).
  final void Function(Duration target) onSeek;

  /// Seeks by an offset from the current position.
  final void Function(Duration offset) onSeekBy;

  /// Plays or pauses.
  final VoidCallback onTogglePlay;

  /// A seekbar or speed-graph scrub started.
  final VoidCallback onScrubStart;

  /// A scrub moved to a position.
  final void Function(Duration target) onScrubUpdate;

  /// A speed-graph drag ended at a position.
  final void Function(Duration target) onGraphScrubEnd;

  /// The seekbar was released at a value, on a slider of the given width.
  final void Function(double valueMs, double sliderWidth) onSeekbarScrubEnd;

  /// Builds the route map; defaults to the real map. For tests.
  final RouteMapBuilder? mapBuilder;

  @override
  State<RidePlaybackBody> createState() => _RidePlaybackBodyState();
}

class _RidePlaybackBodyState extends State<RidePlaybackBody> {
  late PlaybackSampleListenable _sample;

  @override
  void initState() {
    super.initState();
    _sample = _createSample();
  }

  PlaybackSampleListenable _createSample() => PlaybackSampleListenable(
    position: widget.position,
    sampleAt: widget.sampleAt,
  );

  @override
  void didUpdateWidget(covariant RidePlaybackBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.position, widget.position)) {
      _sample.dispose();
      _sample = _createSample();
    } else {
      _sample.sampleAt = widget.sampleAt;
    }
  }

  @override
  void dispose() {
    _sample.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasSamples = widget.samples.isNotEmpty;
    final showChrome = !widget.isFullscreen;
    final mapHeight = (MediaQuery.sizeOf(context).height * 0.14)
        .clamp(90.0, 130.0)
        .toDouble();

    return Column(
      children: [
        Expanded(
          child: PlaybackVideoArea(
            video: widget.video,
            isFullscreen: widget.isFullscreen,
            onToggleFullscreen: widget.onToggleFullscreen,
            overlay: showChrome && hasSamples
                ? PlaybackTelemetryOverlay(sample: _sample)
                : null,
            speedGraph: showChrome && hasSamples
                ? PlaybackSpeedGraph(
                    samples: widget.samples,
                    maxSpeed: widget.maxSpeed,
                    totalDuration: widget.totalDuration,
                    position: widget.position,
                    incidentMarkerMs: widget.marks.incidentMarkerMs,
                    lockMarkerMs: widget.marks.lockMarkerMs,
                    onSeek: widget.onSeek,
                    onScrubStart: widget.onScrubStart,
                    onScrubUpdate: widget.onScrubUpdate,
                    onScrubEnd: widget.onGraphScrubEnd,
                  )
                : null,
          ),
        ),
        if (showChrome && hasSamples)
          RouteMapPanel(
            samples: widget.samples,
            currentSample: _sample,
            mapHeight: mapHeight,
            expanded: widget.showRouteMap,
            onToggle: widget.onToggleRouteMap,
            mapBuilder: widget.mapBuilder ?? defaultRouteMapBuilder,
          ),
        if (showChrome)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
            child: Column(
              children: [
                PlaybackSeekBar(
                  position: widget.position,
                  totalDuration: widget.totalDuration,
                  marks: widget.marks,
                  onScrubStart: widget.onScrubStart,
                  onScrubUpdate: widget.onScrubUpdate,
                  onScrubEnd: widget.onSeekbarScrubEnd,
                ),
                PlaybackLegend(marks: widget.marks),
                const SizedBox(height: 8),
                PlaybackControls(
                  position: widget.position,
                  segmentNumber: widget.segmentNumber,
                  segmentCount: widget.segmentCount,
                  onSeekBy: widget.onSeekBy,
                  onTogglePlay: widget.onTogglePlay,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
