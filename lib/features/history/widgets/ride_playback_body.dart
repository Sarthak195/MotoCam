import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/build_flags.dart';
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

/// Builds one of the body's panels (the header, the integrity strip, the
/// ride actions, the trip report) for the portrait or the landscape layout.
typedef PlaybackPanelBuilder =
    Widget Function(BuildContext context, bool landscape);

/// The body of the ride playback screen, in the Instrument look.
///
/// Portrait (A-Playback): the header, the integrity strip, the video box,
/// then a scrolling pane with the transport row, the timeline and its
/// legend, the speed graph card and the route map row, and the ride
/// actions pinned at the bottom. Landscape (A-Land-Playback, chosen when
/// the body is wider than tall): the video, timeline and legend on the
/// left, and a scrolling right pane with the header, the integrity strip,
/// the transport row, the speed graph, the route map row and the actions.
/// In fullscreen only the video is shown, edge to edge, with the system
/// bars hidden (see [setPlaybackImmersive]; they come back on exit and
/// when the body is disposed).
///
/// It is built from explicit values, callbacks and the [position]
/// listenable, and never holds the video controller (the [video] widget
/// does). A playback tick changes only [position], so only the widgets that
/// show the position rebuild: the slider, the time label, the telemetry
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
    this.header,
    this.integrity,
    this.actions,
    this.tripReport,
    this.mapBuilder,
  });

  /// Video height under which the telemetry overlay is left out, so it
  /// never covers most of a small picture.
  static const double minOverlayVideoHeight = 220;

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

  /// The ranges and markers on the timeline and in the legend.
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

  /// A timeline or speed-graph scrub started.
  final VoidCallback onScrubStart;

  /// A scrub moved to a position.
  final void Function(Duration target) onScrubUpdate;

  /// A speed-graph drag ended at a position.
  final void Function(Duration target) onGraphScrubEnd;

  /// The timeline was released at a value, on a slider of the given width.
  final void Function(double valueMs, double sliderWidth) onSeekbarScrubEnd;

  /// The header (back, date and summary); left out when null.
  final PlaybackPanelBuilder? header;

  /// The integrity strip; left out when null.
  final PlaybackPanelBuilder? integrity;

  /// The ride actions; left out when null.
  final PlaybackPanelBuilder? actions;

  /// The trip report card, shown only when [kTripReport] is on.
  final PlaybackPanelBuilder? tripReport;

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
    if (widget.isFullscreen) {
      unawaited(setPlaybackImmersive(true));
    }
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
    if (oldWidget.isFullscreen != widget.isFullscreen) {
      unawaited(setPlaybackImmersive(widget.isFullscreen));
    }
  }

  @override
  void dispose() {
    if (widget.isFullscreen) {
      unawaited(setPlaybackImmersive(false));
    }
    _sample.dispose();
    super.dispose();
  }

  bool get _hasSamples => widget.samples.isNotEmpty;

  Widget _videoArea({required bool fullscreen}) {
    final clipLabel = widget.segmentCount > 1
        ? 'Clip ${widget.segmentNumber} of ${widget.segmentCount}'
        : null;
    return LayoutBuilder(
      builder: (context, constraints) => PlaybackVideoArea(
        video: widget.video,
        isFullscreen: fullscreen,
        onToggleFullscreen: widget.onToggleFullscreen,
        clipLabel: clipLabel,
        overlay:
            !fullscreen &&
                _hasSamples &&
                constraints.maxHeight >= RidePlaybackBody.minOverlayVideoHeight
            ? PlaybackTelemetryOverlay(sample: _sample)
            : null,
      ),
    );
  }

  Widget _controls({required bool landscape}) => PlaybackControls(
    position: widget.position,
    totalDuration: widget.totalDuration,
    onSeekBy: widget.onSeekBy,
    onTogglePlay: widget.onTogglePlay,
    playSize: landscape ? 52 : 56,
  );

  Widget _seekBar({required bool landscape}) => PlaybackSeekBar(
    position: widget.position,
    totalDuration: widget.totalDuration,
    marks: widget.marks,
    onScrubStart: widget.onScrubStart,
    onScrubUpdate: widget.onScrubUpdate,
    onScrubEnd: widget.onSeekbarScrubEnd,
    height: landscape
        ? PlaybackSeekBar.compactHeight
        : PlaybackSeekBar.sliderHeight,
  );

  Widget _speedGraph({required bool landscape}) => PlaybackSpeedGraph(
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
    height: landscape ? speedGraphCompactHeight : speedGraphHeight,
  );

  Widget _routeMap(BuildContext context) => RouteMapPanel(
    samples: widget.samples,
    currentSample: _sample,
    mapHeight: (MediaQuery.sizeOf(context).height * 0.14)
        .clamp(90.0, 130.0)
        .toDouble(),
    expanded: widget.showRouteMap,
    onToggle: widget.onToggleRouteMap,
    mapBuilder: widget.mapBuilder ?? defaultRouteMapBuilder,
  );

  Widget? _panel(PlaybackPanelBuilder? builder, bool landscape) =>
      builder == null ? null : Builder(builder: (c) => builder(c, landscape));

  Widget _portrait(BuildContext context, BoxConstraints constraints) {
    final videoHeight = (constraints.maxHeight * 0.42)
        .clamp(150.0, 420.0)
        .toDouble();
    final header = _panel(widget.header, false);
    final integrity = _panel(widget.integrity, false);
    final actions = _panel(widget.actions, false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?header,
        if (integrity != null) ...[const SizedBox(height: 6), integrity],
        const SizedBox(height: 10),
        SizedBox(height: videoHeight, child: _videoArea(fullscreen: false)),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 10, bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _controls(landscape: false),
                const SizedBox(height: 4),
                _seekBar(landscape: false),
                PlaybackLegend(marks: widget.marks),
                if (_hasSamples) ...[
                  const SizedBox(height: 12),
                  _speedGraph(landscape: false),
                  const SizedBox(height: 8),
                  _routeMap(context),
                ],
                if (kTripReport) ?_panel(widget.tripReport, false),
              ],
            ),
          ),
        ),
        if (actions != null) ...[const SizedBox(height: 8), actions],
      ],
    );
  }

  Widget _landscape(BuildContext context, BoxConstraints constraints) {
    final leftWidth = constraints.maxWidth * 0.63;
    final header = _panel(widget.header, true);
    final integrity = _panel(widget.integrity, true);
    final actions = _panel(widget.actions, true);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: leftWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _videoArea(fullscreen: false)),
              const SizedBox(height: 6),
              _seekBar(landscape: true),
              PlaybackLegend(marks: widget.marks),
            ],
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ?header,
                if (integrity != null) ...[
                  const SizedBox(height: 8),
                  integrity,
                ],
                const SizedBox(height: 10),
                _controls(landscape: true),
                if (_hasSamples) ...[
                  const SizedBox(height: 10),
                  _speedGraph(landscape: true),
                  const SizedBox(height: 6),
                  _routeMap(context),
                ],
                if (kTripReport) ?_panel(widget.tripReport, true),
                if (actions != null) ...[const SizedBox(height: 12), actions],
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isFullscreen) {
      return _videoArea(fullscreen: true);
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) =>
              constraints.maxWidth > constraints.maxHeight
              ? _landscape(context, constraints)
              : _portrait(context, constraints),
        ),
      ),
    );
  }
}
