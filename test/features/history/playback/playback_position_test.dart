import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/features/history/widgets/playback_position.dart';
import 'package:motocam/features/telemetry/models/telemetry_data.dart';

TelemetryData _sampleAt(Duration position) => TelemetryData(
  latitude: 1,
  longitude: 2,
  speed: position.inSeconds.toDouble(),
  bearing: 0,
  accelerationG: 0,
  elapsedMs: position.inMilliseconds,
  distanceKm: 0,
  timestamp: DateTime.utc(2026, 1, 1),
);

void main() {
  group('PlaybackPosition', () {
    test('compares by position and playing flag', () {
      const a = PlaybackPosition(position: Duration(seconds: 1));
      const b = PlaybackPosition(position: Duration(seconds: 1));
      const c = PlaybackPosition(
        position: Duration(seconds: 1),
        isPlaying: true,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(PlaybackPosition.zero.position, Duration.zero);
    });

    test('a ValueNotifier does not notify for an equal value', () {
      final notifier = ValueNotifier<PlaybackPosition>(
        const PlaybackPosition(position: Duration(seconds: 1)),
      );
      var notifications = 0;
      notifier.addListener(() => notifications++);
      notifier.value = const PlaybackPosition(position: Duration(seconds: 1));
      expect(notifications, 0);
      notifier.value = const PlaybackPosition(position: Duration(seconds: 2));
      expect(notifications, 1);
      notifier.dispose();
    });
  });

  group('PlaybackSampleListenable', () {
    test('looks the sample up when the position changes', () {
      final position = ValueNotifier<PlaybackPosition>(PlaybackPosition.zero);
      final sample = PlaybackSampleListenable(
        position: position,
        sampleAt: _sampleAt,
      );
      var notifications = 0;
      sample.addListener(() => notifications++);
      expect(sample.value.elapsedMs, 0);

      position.value = const PlaybackPosition(position: Duration(seconds: 3));
      expect(sample.value.elapsedMs, 3000);
      expect(notifications, 1);

      // Only the playing flag changed: no new lookup, no notification.
      position.value = const PlaybackPosition(
        position: Duration(seconds: 3),
        isPlaying: true,
      );
      expect(notifications, 1);

      sample.dispose();
      position.value = const PlaybackPosition(position: Duration(seconds: 9));
      expect(notifications, 1);
      position.dispose();
    });
  });
}
