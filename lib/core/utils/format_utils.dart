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

/// Formats a file size with decimal units (1 MB = 1,000,000 bytes), like
/// Android's storage screens, to three significant digits at most and
/// without trailing zeros: `812 KB`, `361 MB`, `1.08 GB`, `1 MB`. Sizes
/// that round up to 1000 move to the next unit (999,999 bytes is `1 MB`).
String formatFileSize(int bytes) {
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  if (bytes < 1000) {
    return '${bytes < 0 ? 0 : bytes} B';
  }
  var value = bytes / 1000;
  var unit = 1;
  String text() =>
      value.toStringAsFixed(value < 10 ? 2 : (value < 100 ? 1 : 0));
  while (double.parse(text()) >= 1000 && unit < units.length - 1) {
    value = double.parse(text()) / 1000;
    unit++;
  }
  var shown = text();
  if (shown.contains('.')) {
    shown = shown.replaceFirst(RegExp(r'\.?0+$'), '');
  }
  return '$shown ${units[unit]}';
}
