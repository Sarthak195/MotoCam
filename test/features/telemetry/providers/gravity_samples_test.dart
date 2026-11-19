// TelemetryProvider.gravitySamples: the raw accelerometer handed to the
// landscape orientation pin without opening a second native stream at
// another rate.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/features/telemetry/providers/telemetry_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Duration> opened;
  late StreamController<AccelerometerEvent> idle;
  late TelemetryProvider provider;

  setUp(() {
    opened = [];
    idle = StreamController<AccelerometerEvent>.broadcast();
    provider = TelemetryProvider(
      idleGravitySource: (period) {
        opened.add(period);
        return idle.stream;
      },
    );
  });

  tearDown(() async {
    provider.dispose();
    await idle.close();
  });

  test('nothing is opened while nobody listens', () async {
    provider.updateOrientationForTesting(0, 9.81, 0);
    await Future<void>.delayed(Duration.zero);
    expect(opened, isEmpty);
    expect(idle.hasListener, isFalse);
  });

  test('a listener while tracking is off opens the idle stream at the '
      'orientation rate and gets its samples', () async {
    final samples = <({double x, double y, double z, DateTime at})>[];
    final subscription = provider.gravitySamples.listen(samples.add);
    expect(opened, [SensorInterval.uiInterval]);
    final at = DateTime(2026, 11, 19, 8);
    idle.add(AccelerometerEvent(9.81, 0.0, 0.0, at));
    await Future<void>.delayed(Duration.zero);
    expect(samples, hasLength(1));
    expect(samples.single.x, 9.81);
    expect(samples.single.at, at);

    await subscription.cancel();
    expect(idle.hasListener, isFalse, reason: 'closed with the last listener');
  });

  test('the provider\'s own orientation samples are forwarded', () async {
    final samples = <({double x, double y, double z, DateTime at})>[];
    final subscription = provider.gravitySamples.listen(samples.add);
    final at = DateTime(2026, 11, 19, 8);
    provider.updateOrientationForTesting(-9.81, 0, 0, timestamp: at);
    provider.updateRawAccelerometerForTesting(0, 9.81, 0, timestamp: at);
    await Future<void>.delayed(Duration.zero);
    expect(samples.map((s) => s.x), [-9.81, 0]);
    await subscription.cancel();
  });
}
