import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/features/history/widgets/playback_seekbar_track_shape.dart';
import 'package:motocam/features/history/widgets/playback_timeline.dart';

Future<void> _pumpSeekbar(
  WidgetTester tester,
  PlaybackSeekbarTrackShape shape,
) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 336,
            height: 34,
            child: SliderTheme(
              data: const SliderThemeData().copyWith(trackShape: shape),
              child: Slider(value: 0, max: 100000, onChanged: (_) {}),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('paints incident and lock markers on the seekbar track', (
    tester,
  ) async {
    await _pumpSeekbar(
      tester,
      const PlaybackSeekbarTrackShape(
        totalDurationMs: 100000,
        incidentMarkerMs: <int>[25000],
        lockMarkerMs: <int>[50000, 75000],
      ),
    );

    final slider = tester.renderObject(find.byType(Slider));
    // One tick per marker: two lock markers and one incident marker.
    expect(
      slider,
      paints
        ..line(color: lockMarkerColor.withValues(alpha: 0.9))
        ..line(color: lockMarkerColor.withValues(alpha: 0.9))
        ..line(color: incidentMarkerColor.withValues(alpha: 0.9)),
    );
  });

  testWidgets('paints missing, failed-check and no-video ranges', (
    tester,
  ) async {
    await _pumpSeekbar(
      tester,
      const PlaybackSeekbarTrackShape(
        totalDurationMs: 100000,
        noVideoRanges: <PlaybackRange>[PlaybackRange(startMs: 0, endMs: 10000)],
        missingRanges: <PlaybackRange>[
          PlaybackRange(startMs: 20000, endMs: 30000),
        ],
        failedCheckRanges: <PlaybackRange>[
          PlaybackRange(startMs: 40000, endMs: 50000),
        ],
      ),
    );

    final slider = tester.renderObject(find.byType(Slider));
    expect(
      slider,
      paints
        ..rect(color: noVideoColor.withValues(alpha: 0.86))
        ..rect(color: missingFootageColor.withValues(alpha: 0.86))
        ..rect(color: failedCheckColor.withValues(alpha: 0.86)),
    );
  });
}
