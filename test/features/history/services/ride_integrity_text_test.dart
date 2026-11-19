import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/features/history/models/ride_record.dart';
import 'package:motocam/features/history/services/ride_integrity_text.dart';

RideRecord _ride({
  String? telemetryPath = '/r/ride_x.telemetry.json',
  bool complete = true,
  RideIntegrityReport integrity = const RideIntegrityReport.unknown(),
  bool mock = false,
}) => RideRecord(
  videoPath: '/r/a.mp4',
  segmentPaths: const <String>['/r/a.mp4'],
  lockedSegmentPaths: const <String>[],
  createdAt: DateTime(2026, 11, 13, 13, 21),
  telemetryPath: telemetryPath,
  rideSessionId: 'x',
  isSessionComplete: complete,
  distanceKm: 0,
  maxSpeedKmh: 0,
  averageSpeedKmh: 0,
  segmentTimeline: const <RideSegmentTimelineEntry>[],
  samples: const [],
  integrity: integrity,
  quarantinedSegmentPaths: const <String>[],
  mockLocationDetected: mock,
);

void main() {
  String text(RideIntegrityStatus status, RideSignedBy signedBy) =>
      rideIntegrityTextFor(
        status: status,
        signedBy: signedBy,
        issues: const <String>[],
        hasTelemetry: true,
        isSessionComplete: true,
      );

  test('a verified ride names who signed it', () {
    expect(
      text(RideIntegrityStatus.verified, RideSignedBy.thisDevice),
      'Integrity: ride data unmodified and signed by this phone\'s MotoCam '
      'key (it shows no edit by anyone without that key; it does not prove '
      'the footage is genuine)',
    );
    expect(
      text(RideIntegrityStatus.verified, RideSignedBy.otherKey),
      'Integrity: ride data unmodified; signed by another phone or an '
      'earlier install of MotoCam',
    );
    expect(
      text(RideIntegrityStatus.verified, RideSignedBy.unknownSigner),
      'Integrity: ride data unmodified; signed, but this phone\'s key could '
      'not be read to check by whom',
    );
    expect(
      text(RideIntegrityStatus.verified, RideSignedBy.none),
      'Integrity: ride data unmodified since recording',
    );
  });

  test('a failed check says so, and names a removed signature', () {
    expect(
      text(RideIntegrityStatus.modified, RideSignedBy.none),
      'Integrity: check failed',
    );
    expect(
      rideIntegrityTextFor(
        status: RideIntegrityStatus.modified,
        signedBy: RideSignedBy.none,
        issues: const <String>['signature-removed'],
        hasTelemetry: true,
        isSessionComplete: true,
      ),
      'Integrity: check failed (this phone signed this ride, but the '
      'signature was removed or replaced)',
    );
    expect(
      rideIntegrityText(
        _ride(integrity: RideIntegrityReport.modified(const <String>['x'])),
      ),
      'Integrity: check failed',
    );
  });

  test('an unchecked ride says why', () {
    expect(
      rideIntegrityText(_ride(telemetryPath: null)),
      'Integrity: not available',
    );
    expect(
      rideIntegrityText(_ride()),
      'Integrity: not available (recorded by an older version)',
    );
    expect(
      rideIntegrityText(_ride(complete: false)),
      'Integrity: not available (ride was not saved completely)',
    );
  });

  test('the line adds the simulated GPS sentence', () {
    expect(
      rideIntegrityLine(_ride()),
      'Integrity: not available (recorded by an older version)',
    );
    expect(
      rideIntegrityLine(_ride(mock: true)),
      'Integrity: not available (recorded by an older version). GPS came '
      'from a simulated (mock) location provider.',
    );
  });
}
