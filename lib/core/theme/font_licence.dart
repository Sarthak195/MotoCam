// lib/core/theme/font_licence.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Asset path of the SIL Open Font License shipped with the Barlow fonts.
const String fontLicenceAsset = 'assets/fonts/OFL.txt';

/// Lists the licence of the bundled Barlow and Barlow Condensed fonts on
/// Flutter's licence page, next to the OpenStreetMap entry.
///
/// The text is read from [fontLicenceAsset] only when the licence page asks
/// for it. Call once at startup; later calls do nothing.
void registerFontLicence() {
  if (_registered) {
    return;
  }
  _registered = true;
  LicenseRegistry.addLicense(_fontLicences);
}

Stream<LicenseEntry> _fontLicences() async* {
  final text = await rootBundle.loadString(fontLicenceAsset);
  yield LicenseEntryWithLineBreaks(const <String>[
    'Barlow',
    'Barlow Condensed',
  ], text);
}

bool _registered = false;
