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
}
