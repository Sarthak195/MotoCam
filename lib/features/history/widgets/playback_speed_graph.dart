import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../telemetry/models/telemetry_data.dart';
import 'playback_position.dart';
import 'playback_timeline.dart';
import 'speed_graph_painter.dart';

/// Height, in logical pixels, of the speed graph strip in portrait.
const double speedGraphHeight = 96;

/// Height, in logical pixels, of the speed graph strip in landscape.
const double speedGraphCompactHeight = 50;

/// The speed graph card: a "Speed, km/h" and "Max" header over a window of the
/// speed curve centred on the playback position, with lock and incident
/// ticks. Tapping it seeks and dragging it scrubs, both relative to the
/// centre.
///
/// The curve is drawn once per page of the ride (see [speedGraphPageIndex])
/// behind a repaint boundary and slid across the strip as [position]
/// changes, so a position tick repaints only the cursor dot, never the
/// curve. Gesture results go to the callbacks; this widget never touches the
/// video controller.
///
/// The strip is [height] tall (see [speedGraphHeight] and
/// [speedGraphCompactHeight]).
class PlaybackSpeedGraph extends StatefulWidget {
  /// Creates the graph for [samples].
  const PlaybackSpeedGraph({
    super.key,
    required this.samples,
    required this.maxSpeed,
    required this.totalDuration,
    required this.position,
    required this.incidentMarkerMs,
    required this.lockMarkerMs,
    required this.onSeek,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onScrubEnd,
    this.height = speedGraphHeight,
  });

  /// Telemetry samples of the ride, ordered by elapsed time.
  final List<TelemetryData> samples;

  /// Speed, in km/h, that reaches the top of the strip.
  final double maxSpeed;

  /// Length of the ride timeline.
  final Duration totalDuration;

  /// The playback position the strip is centred on.
  final ValueListenable<PlaybackPosition> position;

  /// Incident marker times in milliseconds from ride start.
  final List<int> incidentMarkerMs;

  /// Locked-segment marker times in milliseconds from ride start.
  final List<int> lockMarkerMs;

  /// A tap asks to seek to the given position.
  final void Function(Duration target) onSeek;

  /// A horizontal drag started.
  final VoidCallback onScrubStart;

  /// A drag moved to the given position.
  final void Function(Duration target) onScrubUpdate;

  /// A drag ended at the given position.
  final void Function(Duration target) onScrubEnd;

  /// Height of the strip under the header.
  final double height;

  @override
  State<PlaybackSpeedGraph> createState() => _PlaybackSpeedGraphState();
}

class _PlaybackSpeedGraphState extends State<PlaybackSpeedGraph> {
  Duration? _dragAnchor;
  double _dragStartDx = 0;
  Duration? _dragTarget;

  int get _graphDurationMs => math.max(
    widget.totalDuration.inMilliseconds,
    widget.samples.isEmpty ? 0 : widget.samples.last.elapsedMs,
  );

  @override
  Widget build(BuildContext context) {
    final label = MotoFonts.bodyStyle(13, color: MotoColors.dim);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: Text('Speed, km/h', style: label)),
            Text.rich(
              TextSpan(
                text: 'Max ',
                children: [
                  TextSpan(
                    text: widget.maxSpeed.round().toString(),
                    style: MotoFonts.bodyStyle(
                      13,
                      weight: FontWeight.w600,
                      color: MotoColors.text,
                    ),
                  ),
                ],
              ),
              style: label,
            ),
          ],
        ),
        const SizedBox(height: 4),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: MotoColors.hairline),
            borderRadius: BorderRadius.circular(MotoRadii.sm),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(MotoRadii.sm),
            child: SizedBox(
              width: double.infinity,
              height: widget.height,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  return Semantics(
                    label: 'Speed graph',
                    hint: 'Tap or drag horizontally to seek',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (details) => widget.onSeek(
                        speedGraphTapTarget(
                          dx: details.localPosition.dx,
                          width: width,
                          currentPosition: widget.position.value.position,
                          totalDuration: widget.totalDuration,
                        ),
                      ),
                      onHorizontalDragStart: (details) {
                        _dragAnchor = widget.position.value.position;
                        _dragStartDx = details.localPosition.dx;
                        _dragTarget = null;
                        widget.onScrubStart();
                      },
                      onHorizontalDragUpdate: (details) {
                        final anchor = _dragAnchor;
                        if (anchor == null) {
                          return;
                        }
                        final target = speedGraphDragTarget(
                          startDx: _dragStartDx,
                          dx: details.localPosition.dx,
                          width: width,
                          anchorPosition: anchor,
                          totalDuration: widget.totalDuration,
                        );
                        _dragTarget = target;
                        widget.onScrubUpdate(target);
                      },
                      onHorizontalDragEnd: (_) {
                        final anchor = _dragAnchor;
                        if (anchor == null) {
                          return;
                        }
                        _dragAnchor = null;
                        widget.onScrubEnd(_dragTarget ?? anchor);
                      },
                      child: _graphDurationMs <= 0 || widget.samples.length < 2
                          ? const SizedBox.expand()
                          : _SpeedGraphLayers(
                              samples: widget.samples,
                              maxSpeed: widget.maxSpeed,
                              windowMs: speedGraphWindowMs(_graphDurationMs),
                              width: width,
                              height: widget.height,
                              incidentMarkerMs: widget.incidentMarkerMs,
                              lockMarkerMs: widget.lockMarkerMs,
                              position: widget.position,
                            ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The two layers of the speed graph: the curve page, kept behind a repaint
/// boundary and only slid sideways per tick, and the cursor dot.
class _SpeedGraphLayers extends StatefulWidget {
  const _SpeedGraphLayers({
    required this.samples,
    required this.maxSpeed,
    required this.windowMs,
    required this.width,
    required this.height,
    required this.incidentMarkerMs,
    required this.lockMarkerMs,
    required this.position,
  });

  final List<TelemetryData> samples;
  final double maxSpeed;
  final int windowMs;
  final double width;
  final double height;
  final List<int> incidentMarkerMs;
  final List<int> lockMarkerMs;
  final ValueListenable<PlaybackPosition> position;

  @override
  State<_SpeedGraphLayers> createState() => _SpeedGraphLayersState();
}

class _SpeedGraphLayersState extends State<_SpeedGraphLayers> {
  /// The curve for page [_pageIndex]. The same widget instance is returned
  /// until the page (or an input of it) changes, so Flutter neither rebuilds
  /// nor repaints it on a position tick.
  Widget? _page;
  int _pageIndex = 0;

  @override
  void didUpdateWidget(covariant _SpeedGraphLayers oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.samples, widget.samples) ||
        oldWidget.maxSpeed != widget.maxSpeed ||
        oldWidget.windowMs != widget.windowMs ||
        oldWidget.width != widget.width ||
        !identical(oldWidget.incidentMarkerMs, widget.incidentMarkerMs) ||
        !identical(oldWidget.lockMarkerMs, widget.lockMarkerMs)) {
      _page = null;
    }
  }

  Widget _pageFor(int index) {
    final cached = _page;
    if (cached != null && index == _pageIndex) {
      return cached;
    }
    _pageIndex = index;
    return _page = RepaintBoundary(
      child: CustomPaint(
        size: Size(widget.width * speedGraphPageWindows, widget.height),
        painter: SpeedGraphPagePainter(
          samples: widget.samples,
          maxSpeed: widget.maxSpeed,
          windowMs: widget.windowMs,
          pageStartMs: (index - 1) * widget.windowMs,
          viewportWidth: widget.width,
          incidentMarkerMs: widget.incidentMarkerMs,
          lockMarkerMs: widget.lockMarkerMs,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final windowMs = widget.windowMs;
    final pxPerMs = widget.width / windowMs;
    return RepaintBoundary(
      child: ClipRect(
        child: ValueListenableBuilder<PlaybackPosition>(
          valueListenable: widget.position,
          builder: (context, value, _) {
            final positionMs = value.position.inMilliseconds;
            final index = speedGraphPageIndex(positionMs, windowMs);
            final page = _pageFor(index);
            final pageStartMs = (index - 1) * windowMs;
            // Puts the position at the centre of the strip.
            final dx = widget.width / 2 - (positionMs - pageStartMs) * pxPerMs;
            return Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  width: widget.width * speedGraphPageWindows,
                  height: widget.height,
                  child: Transform.translate(
                    offset: Offset(dx, 0),
                    child: page,
                  ),
                ),
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: SpeedGraphCursorPainter(
                        samples: widget.samples,
                        maxSpeed: widget.maxSpeed,
                        windowMs: windowMs,
                        positionMs: positionMs,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
