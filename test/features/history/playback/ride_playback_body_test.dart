import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/features/history/widgets/playback_legend.dart';
import 'package:motocam/features/history/widgets/playback_position.dart';
import 'package:motocam/features/history/widgets/playback_timeline.dart';
import 'package:motocam/features/history/widgets/ride_playback_body.dart';
import 'package:motocam/features/history/widgets/route_map_panel.dart';
import 'package:motocam/features/history/widgets/speed_graph_painter.dart';
import 'package:motocam/features/telemetry/models/telemetry_data.dart';

/// One sample per second for [count] seconds; the speed is the second.
List<TelemetryData> _samples(int count) => [
  for (var i = 0; i < count; i++)
    TelemetryData(
      latitude: 28.6 + i * 0.0001,
      longitude: 77.2 + i * 0.0001,
      speed: i.toDouble(),
      bearing: 0,
      accelerationG: 0,
      elapsedMs: i * 1000,
      distanceKm: i / 1000,
      timestamp: DateTime.utc(2026, 1, 1).add(Duration(seconds: i)),
    ),
];

TelemetryData _atSecond(List<TelemetryData> samples, Duration position) =>
    samples.isEmpty
    ? TelemetryData.empty()
    : samples[position.inSeconds.clamp(0, samples.length - 1)];

/// Counts how often the stubbed map is built.
class _MapProbe extends StatelessWidget {
  const _MapProbe({required this.sample});

  static int builds = 0;

  final ValueListenable<TelemetryData?> sample;

  @override
  Widget build(BuildContext context) {
    builds++;
    return ValueListenableBuilder<TelemetryData?>(
      valueListenable: sample,
      builder: (context, value, _) =>
          Text('marker ${value?.speed.toStringAsFixed(0)}'),
    );
  }
}

/// Everything a test needs to drive one [RidePlaybackBody].
class _Harness {
  _Harness({int sampleCount = 600})
    : samples = _samples(sampleCount),
      position = ValueNotifier<PlaybackPosition>(PlaybackPosition.zero);

  final List<TelemetryData> samples;
  final ValueNotifier<PlaybackPosition> position;
  final ValueNotifier<bool> showMap = ValueNotifier<bool>(true);
  final ValueNotifier<bool> fullscreen = ValueNotifier<bool>(false);

  final List<String> calls = <String>[];

  Duration get total => samples.isEmpty
      ? const Duration(seconds: 60)
      : Duration(milliseconds: samples.last.elapsedMs);

  Widget build() {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: ValueListenableBuilder<bool>(
          valueListenable: showMap,
          builder: (context, showMapValue, _) => ValueListenableBuilder<bool>(
            valueListenable: fullscreen,
            builder: (context, fullscreenValue, _) => RidePlaybackBody(
              video: const SizedBox.expand(
                child: ColoredBox(color: Colors.black),
              ),
              samples: samples,
              maxSpeed: 600,
              sampleAt: (position) => _atSecond(samples, position),
              position: position,
              totalDuration: total,
              marks: const PlaybackTimelineMarks(
                incidentMarkerMs: [120000],
                lockMarkerMs: [0],
              ),
              isFullscreen: fullscreenValue,
              showRouteMap: showMapValue,
              segmentNumber: 1,
              segmentCount: 3,
              onToggleFullscreen: () => fullscreen.value = !fullscreen.value,
              onToggleRouteMap: () => showMap.value = !showMap.value,
              onSeek: (target) => calls.add('seek ${target.inSeconds}'),
              onSeekBy: (offset) => calls.add('seekBy ${offset.inSeconds}'),
              onTogglePlay: () => calls.add('togglePlay'),
              onScrubStart: () => calls.add('scrubStart'),
              onScrubUpdate: (target) =>
                  calls.add('scrubUpdate ${target.inSeconds}'),
              onGraphScrubEnd: (target) =>
                  calls.add('graphEnd ${target.inSeconds}'),
              onSeekbarScrubEnd: (value, width) =>
                  calls.add('seekbarEnd ${value.round()}'),
              mapBuilder: (context, samples, height, sample) =>
                  _MapProbe(sample: sample),
            ),
          ),
        ),
      ),
    );
  }

  void dispose() {
    position.dispose();
    showMap.dispose();
    fullscreen.dispose();
  }
}

Finder get _pageFinder => find.byWidgetPredicate(
  (widget) => widget is CustomPaint && widget.painter is SpeedGraphPagePainter,
);

Finder get _cursorFinder => find.byWidgetPredicate(
  (widget) =>
      widget is CustomPaint && widget.painter is SpeedGraphCursorPainter,
);

Future<void> _pumpBody(WidgetTester tester, _Harness harness) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(harness.dispose);
  _MapProbe.builds = 0;
  await tester.pumpWidget(harness.build());
  await tester.pump();
}

void main() {
  testWidgets('a position tick rebuilds only what shows the position', (
    tester,
  ) async {
    final harness = _Harness();
    await _pumpBody(tester, harness);

    final panel = tester.widget<RouteMapPanel>(find.byType(RouteMapPanel));
    final legend = tester.widget<PlaybackLegend>(find.byType(PlaybackLegend));
    final graphPage = tester.widget<CustomPaint>(_pageFinder);
    expect(find.text('marker 0'), findsOneWidget);
    expect(_MapProbe.builds, 1);

    final mapBuilds = _MapProbe.builds;
    final pagePaints = SpeedGraphPagePainter.paintCount;
    final cursorPaints = SpeedGraphCursorPainter.paintCount;
    expect(pagePaints, greaterThan(0));

    for (var second = 5; second <= 9; second++) {
      harness.position.value = PlaybackPosition(
        position: Duration(seconds: second),
        isPlaying: true,
      );
      await tester.pump();
    }

    // The map, the legend, the panel and the curve were neither rebuilt nor
    // repainted.
    expect(_MapProbe.builds, mapBuilds);
    expect(
      identical(
        tester.widget<RouteMapPanel>(find.byType(RouteMapPanel)),
        panel,
      ),
      isTrue,
    );
    expect(
      identical(
        tester.widget<PlaybackLegend>(find.byType(PlaybackLegend)),
        legend,
      ),
      isTrue,
    );
    expect(
      identical(tester.widget<CustomPaint>(_pageFinder), graphPage),
      isTrue,
    );
    expect(SpeedGraphPagePainter.paintCount, pagePaints);

    // The widgets that show the position followed it.
    expect(SpeedGraphCursorPainter.paintCount, greaterThan(cursorPaints));
    expect(tester.widget<Slider>(find.byType(Slider)).value, 9000);
    expect(find.text('00:00:09'), findsOneWidget);
    expect(find.text('9.0 km/h'), findsOneWidget);
    expect(find.text('marker 9'), findsOneWidget);
    expect(find.byTooltip('Pause'), findsOneWidget);
  });

  testWidgets('the curve repaints only when the position enters a new page', (
    tester,
  ) async {
    final harness = _Harness();
    await _pumpBody(tester, harness);
    final pagePaints = SpeedGraphPagePainter.paintCount;

    // Window is 60 s, so page 0 covers positions below 60 s.
    harness.position.value = const PlaybackPosition(
      position: Duration(seconds: 59),
    );
    await tester.pump();
    expect(SpeedGraphPagePainter.paintCount, pagePaints);

    harness.position.value = const PlaybackPosition(
      position: Duration(seconds: 61),
    );
    await tester.pump();
    expect(SpeedGraphPagePainter.paintCount, pagePaints + 1);

    harness.position.value = const PlaybackPosition(
      position: Duration(seconds: 100),
    );
    await tester.pump();
    expect(SpeedGraphPagePainter.paintCount, pagePaints + 1);
  });

  testWidgets('the slid curve keeps the current sample under the cursor', (
    tester,
  ) async {
    final harness = _Harness();
    await _pumpBody(tester, harness);

    for (final second in [0, 30, 59, 61, 250]) {
      harness.position.value = PlaybackPosition(
        position: Duration(seconds: second),
      );
      await tester.pump();

      final painter =
          tester.widget<CustomPaint>(_pageFinder).painter!
              as SpeedGraphPagePainter;
      final pageLeft = tester.getTopLeft(_pageFinder).dx;
      final sampleX =
          pageLeft +
          (second * 1000 - painter.pageStartMs) *
              painter.viewportWidth /
              painter.windowMs;
      expect(sampleX, closeTo(tester.getCenter(_cursorFinder).dx, 0.01));
    }
  });

  testWidgets('the cursor dot marks the sample nearest the position', (
    tester,
  ) async {
    final harness = _Harness();
    await _pumpBody(tester, harness);
    harness.position.value = const PlaybackPosition(
      position: Duration(seconds: 30),
    );
    await tester.pump();

    final cursor = tester.renderObject(_cursorFinder);
    final size = tester.getSize(_cursorFinder);
    expect(
      cursor,
      paints..circle(
        x: size.width / 2,
        y: 56 - (30 / 600) * (56 - 8) - 4,
        color: Colors.orangeAccent,
      ),
    );
  });

  testWidgets('a collapsed map is not built, an expanded one is', (
    tester,
  ) async {
    final harness = _Harness();
    harness.showMap.value = false;
    await _pumpBody(tester, harness);
    expect(_MapProbe.builds, 0);
    expect(find.byType(_MapProbe), findsNothing);

    await tester.tap(find.text('Route Map'));
    await tester.pump();
    expect(find.byType(_MapProbe), findsOneWidget);
    expect(_MapProbe.builds, 1);

    harness.position.value = const PlaybackPosition(
      position: Duration(seconds: 4),
    );
    await tester.pump();
    expect(_MapProbe.builds, 1);
    expect(find.text('marker 4'), findsOneWidget);

    await tester.tap(find.text('Route Map'));
    await tester.pumpAndSettle();
    expect(find.byType(_MapProbe), findsNothing);
  });

  testWidgets('fullscreen hides the chrome and keeps the video', (
    tester,
  ) async {
    final harness = _Harness();
    await _pumpBody(tester, harness);
    expect(find.byType(Slider), findsOneWidget);

    harness.fullscreen.value = true;
    await tester.pump();
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(RouteMapPanel), findsNothing);
    expect(_pageFinder, findsNothing);
    expect(find.text('Tap video to show controls'), findsOneWidget);
    expect(find.byType(ColoredBox), findsWidgets);
  });

  testWidgets('a ride without samples shows no telemetry views', (
    tester,
  ) async {
    final harness = _Harness(sampleCount: 0);
    await _pumpBody(tester, harness);
    expect(find.byType(RouteMapPanel), findsNothing);
    expect(_pageFinder, findsNothing);
    expect(find.text('Speed'), findsNothing);
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('controls and seekbar report to the callbacks', (tester) async {
    final harness = _Harness();
    await _pumpBody(tester, harness);

    await tester.tap(find.byTooltip('Back 10 seconds'));
    await tester.tap(find.byTooltip('Forward 10 seconds'));
    await tester.tap(find.byTooltip('Play'));
    expect(harness.calls, ['seekBy -10', 'seekBy 10', 'togglePlay']);
    expect(find.text('Segment 1/3'), findsOneWidget);

    harness.calls.clear();
    await tester.drag(find.byType(Slider), const Offset(200, 0));
    await tester.pump();
    expect(harness.calls.first, 'scrubStart');
    expect(harness.calls.where((c) => c.startsWith('scrubUpdate')), isNotEmpty);
    expect(harness.calls.last, startsWith('seekbarEnd'));
  });

  testWidgets('the speed graph seeks on a tap and scrubs on a drag', (
    tester,
  ) async {
    final harness = _Harness();
    await _pumpBody(tester, harness);
    harness.position.value = const PlaybackPosition(
      position: Duration(seconds: 100),
    );
    await tester.pump();

    final center = tester.getCenter(_cursorFinder);
    final width = tester.getSize(_cursorFinder).width;

    // A tap at the centre seeks to the current position; one at the right
    // edge seeks half a window (30 s) ahead.
    await tester.tapAt(center);
    await tester.tapAt(center + Offset(width / 2 - 1, 0));
    expect(harness.calls[0], 'seek 100');
    expect(harness.calls[1], startsWith('seek 12'));

    harness.calls.clear();
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(Offset(width / 6, 0));
    await tester.pump();
    await gesture.moveBy(Offset(width / 6, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(harness.calls.first, 'scrubStart');
    // The first move only starts the drag (the drag is measured from where
    // it was recognised), so the target is one move of a sixth of a window
    // (10 s) past the position at the start.
    expect(harness.calls.last, 'graphEnd 110');
  });
}
