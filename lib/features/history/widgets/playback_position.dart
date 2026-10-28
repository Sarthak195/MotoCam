import 'package:flutter/foundation.dart';

import '../../telemetry/models/telemetry_data.dart';

/// Where playback is on the ride timeline, and whether it is running.
///
/// The playback screen publishes one of these through a
/// `ValueListenable<PlaybackPosition>` on every video tick, so only the
/// widgets that show the position listen to it and rebuild.
@immutable
class PlaybackPosition {
  /// Creates a position; [isPlaying] defaults to `false`.
  const PlaybackPosition({required this.position, this.isPlaying = false});

  /// The start of the ride, not playing.
  static const PlaybackPosition zero = PlaybackPosition(
    position: Duration.zero,
  );

  /// Position on the ride timeline: the scrub preview while the rider drags
  /// the seekbar or speed graph, otherwise the playing position.
  final Duration position;

  /// Whether the video is playing.
  final bool isPlaying;

  @override
  bool operator ==(Object other) =>
      other is PlaybackPosition &&
      other.position == position &&
      other.isPlaying == isPlaying;

  @override
  int get hashCode => Object.hash(position, isPlaying);

  @override
  String toString() => 'PlaybackPosition($position, isPlaying: $isPlaying)';
}

/// The telemetry sample at a [PlaybackPosition], recomputed whenever the
/// position changes. The telemetry overlay and the route map's marker listen
/// to it, so the sample is looked up once per tick for both.
class PlaybackSampleListenable extends ChangeNotifier
    implements ValueListenable<TelemetryData> {
  /// Follows [position], looking each sample up with [sampleAt].
  PlaybackSampleListenable({
    required ValueListenable<PlaybackPosition> position,
    required this.sampleAt,
  }) : _position = position {
    _valuePosition = position.value.position;
    _value = sampleAt(_valuePosition);
    position.addListener(_onPositionChanged);
  }

  final ValueListenable<PlaybackPosition> _position;

  /// Returns the (interpolated) sample for a ride-timeline position.
  TelemetryData Function(Duration position) sampleAt;

  late TelemetryData _value;
  Duration _valuePosition = Duration.zero;

  @override
  TelemetryData get value => _value;

  void _onPositionChanged() {
    final next = _position.value.position;
    if (next == _valuePosition) {
      return;
    }
    _valuePosition = next;
    _value = sampleAt(next);
    notifyListeners();
  }

  @override
  void dispose() {
    _position.removeListener(_onPositionChanged);
    super.dispose();
  }
}
