import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/utils/format_utils.dart';

void main() {
  test('formatElapsed pads hours, minutes and seconds', () {
    expect(formatElapsed(Duration.zero), '00:00:00');
    expect(formatElapsed(const Duration(minutes: 5)), '00:05:00');
    expect(
      formatElapsed(const Duration(hours: 26, minutes: 3, seconds: 9)),
      '26:03:09',
    );
    expect(formatElapsed(const Duration(seconds: -4)), '00:00:00');
  });

  test('formatFileSize uses decimal units with up to 3 significant digits', () {
    expect(formatFileSize(0), '0 B');
    expect(formatFileSize(999), '999 B');
    expect(formatFileSize(1000), '1 KB');
    expect(formatFileSize(1500), '1.5 KB');
    expect(formatFileSize(812000), '812 KB');
    expect(formatFileSize(999499), '999 KB');
    // Rounds up to 1000 KB, so it moves to the next unit.
    expect(formatFileSize(999999), '1 MB');
    expect(formatFileSize(1000000), '1 MB');
    expect(formatFileSize(361000000), '361 MB');
    expect(formatFileSize(12340000), '12.3 MB');
    expect(formatFileSize(1080000000), '1.08 GB');
    expect(formatFileSize(999999999999), '1 TB');
    expect(formatFileSize(-5), '0 B');
  });
}
