import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/features/camera/providers/camera_provider.dart';

void main() {
  String? reason({
    bool isAndroid = true,
    bool recording = false,
    bool migrationRunning = false,
    bool importRunning = false,
    bool storageBudgetRunning = false,
    bool persistingRide = false,
    bool maintenancePending = false,
    bool exportRunning = false,
  }) => CameraProvider.rideExportBlockedReasonFor(
    isAndroid: isAndroid,
    recording: recording,
    migrationRunning: migrationRunning,
    importRunning: importRunning,
    storageBudgetRunning: storageBudgetRunning,
    persistingRide: persistingRide,
    maintenancePending: maintenancePending,
    exportRunning: exportRunning,
  );

  test('an export may start when nothing else runs', () {
    expect(reason(), isNull);
  });

  test('each job refuses with its own sentence', () {
    expect(reason(isAndroid: false), 'Export is available on Android only.');
    expect(reason(recording: true), 'Stop recording before exporting.');
    expect(
      reason(migrationRunning: true),
      'Rides are being moved to private storage. Try again when the move '
      'finishes.',
    );
    expect(
      reason(importRunning: true),
      'Rides are being imported from the old folder. Try again when the '
      'import finishes.',
    );
    expect(
      reason(storageBudgetRunning: true),
      'Old rides are being deleted for the storage budget. Try again in a '
      'moment.',
    );
    expect(
      reason(persistingRide: true),
      'A ride is still being saved. Try again in a moment.',
    );
    expect(
      reason(maintenancePending: true),
      'MotoCam is tidying up after the last recording. Try again in a '
      'moment.',
    );
    expect(reason(exportRunning: true), 'An export is already running.');
  });

  test('the first refusal in gate order wins', () {
    // Drop the jobs one at a time, from the first in order; each time the
    // next one's sentence is given.
    final order = <String?>[
      reason(
        isAndroid: false,
        recording: true,
        migrationRunning: true,
        importRunning: true,
        storageBudgetRunning: true,
        persistingRide: true,
        maintenancePending: true,
        exportRunning: true,
      ),
      reason(
        recording: true,
        migrationRunning: true,
        importRunning: true,
        storageBudgetRunning: true,
        persistingRide: true,
        maintenancePending: true,
        exportRunning: true,
      ),
      reason(
        migrationRunning: true,
        importRunning: true,
        storageBudgetRunning: true,
        persistingRide: true,
        maintenancePending: true,
        exportRunning: true,
      ),
      reason(
        importRunning: true,
        storageBudgetRunning: true,
        persistingRide: true,
        maintenancePending: true,
        exportRunning: true,
      ),
      reason(
        storageBudgetRunning: true,
        persistingRide: true,
        maintenancePending: true,
        exportRunning: true,
      ),
      reason(
        persistingRide: true,
        maintenancePending: true,
        exportRunning: true,
      ),
      reason(maintenancePending: true, exportRunning: true),
      reason(exportRunning: true),
    ];
    expect(order, <String?>[
      reason(isAndroid: false),
      reason(recording: true),
      reason(migrationRunning: true),
      reason(importRunning: true),
      reason(storageBudgetRunning: true),
      reason(persistingRide: true),
      reason(maintenancePending: true),
      reason(exportRunning: true),
    ]);
    expect(order.toSet(), hasLength(order.length));
  });

  test('a new provider has no export running and no progress', () {
    final provider = CameraProvider();
    addTearDown(provider.dispose);

    expect(provider.rideExportProgress.value, isNull);
  });
}
