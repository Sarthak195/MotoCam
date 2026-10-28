/// Shared display formatting helpers.
library;

/// Formats [duration] as `HH:MM:SS` (hours are not wrapped at 24), the one
/// elapsed-time format used by the recording screen, Ride History and
/// playback. Negative durations are shown as `00:00:00`.
String formatElapsed(Duration duration) {
  final safe = duration.isNegative ? Duration.zero : duration;
  final hours = safe.inHours;
  final minutes = safe.inMinutes.remainder(60);
  final seconds = safe.inSeconds.remainder(60);
  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}
