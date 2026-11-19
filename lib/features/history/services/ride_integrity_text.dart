// lib/features/history/services/ride_integrity_text.dart
//
// The full integrity sentence of a ride, shared by Ride History (the row's
// tooltip and accessibility text) and, later, the Playback strip. Pure: no
// widgets, no I/O.

import '../models/ride_record.dart';

/// The integrity sentence of [ride], for example "Integrity: ride data
/// unmodified since recording".
String rideIntegrityText(RideRecord ride) => rideIntegrityTextFor(
  status: ride.integrity.status,
  signedBy: ride.integrity.signedBy,
  issues: ride.integrity.issues,
  hasTelemetry: ride.telemetryPath != null,
  isSessionComplete: ride.isSessionComplete,
);

/// [rideIntegrityText] from plain values, so every case can be checked
/// without a signed ride file.
String rideIntegrityTextFor({
  required RideIntegrityStatus status,
  required RideSignedBy signedBy,
  required List<String> issues,
  required bool hasTelemetry,
  required bool isSessionComplete,
}) {
  switch (status) {
    case RideIntegrityStatus.verified:
      return switch (signedBy) {
        RideSignedBy.thisDevice =>
          'Integrity: ride data unmodified and signed by this phone\'s '
              'MotoCam key (it shows no edit by anyone without that key; it '
              'does not prove the footage is genuine)',
        RideSignedBy.otherKey =>
          'Integrity: ride data unmodified; signed by another phone or an '
              'earlier install of MotoCam',
        RideSignedBy.unknownSigner =>
          'Integrity: ride data unmodified; signed, but this phone\'s key '
              'could not be read to check by whom',
        RideSignedBy.none => 'Integrity: ride data unmodified since recording',
      };
    case RideIntegrityStatus.modified:
      return issues.contains('signature-removed')
          ? 'Integrity: check failed (this phone signed this ride, but the '
                'signature was removed or replaced)'
          : 'Integrity: check failed';
    case RideIntegrityStatus.unknown:
      if (!hasTelemetry) {
        return 'Integrity: not available';
      }
      return isSessionComplete
          ? 'Integrity: not available (recorded by an older version)'
          : 'Integrity: not available (ride was not saved completely)';
  }
}

/// [rideIntegrityText] plus the simulated GPS sentence when the ride's GPS
/// came from a mock-location provider.
String rideIntegrityLine(RideRecord ride) {
  final text = rideIntegrityText(ride);
  if (!ride.mockLocationDetected) {
    return text;
  }
  return '$text. GPS came from a simulated (mock) location provider.';
}
