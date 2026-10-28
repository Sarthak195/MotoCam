// lib/features/map/map_licence.dart

import 'package:flutter/foundation.dart';

import 'map_source_config.dart';

/// Lists the OpenStreetMap data licence on Flutter's licence page (the
/// "About and licences" entry of the recording settings sheet).
///
/// Call once at startup; later calls do nothing.
void registerMapLicence() {
  if (_registered) {
    return;
  }
  _registered = true;
  LicenseRegistry.addLicense(
    () => Stream<LicenseEntry>.value(
      const LicenseEntryWithLineBreaks(<String>[
        'OpenStreetMap',
      ], MapSourceConfig.licenceSummary),
    ),
  );
}

bool _registered = false;
