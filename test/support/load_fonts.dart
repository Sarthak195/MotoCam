// Loads the bundled Barlow fonts into the test engine. flutter_test draws
// every family as Ahem (each glyph one em square) unless the real font
// files are loaded, which makes layout and overflow checks meaningless for
// large condensed type.

import 'package:flutter/services.dart';

/// The bundled font files, by family.
const Map<String, List<String>> bundledFonts = {
  'Barlow': [
    'assets/fonts/Barlow-Regular.ttf',
    'assets/fonts/Barlow-Medium.ttf',
    'assets/fonts/Barlow-SemiBold.ttf',
  ],
  'Barlow Condensed': [
    'assets/fonts/BarlowCondensed-Medium.ttf',
    'assets/fonts/BarlowCondensed-SemiBold.ttf',
    'assets/fonts/BarlowCondensed-Bold.ttf',
  ],
};

bool _loaded = false;

/// Loads every bundled font once per test isolate.
Future<void> loadBundledFonts() async {
  if (_loaded) {
    return;
  }
  for (final entry in bundledFonts.entries) {
    final loader = FontLoader(entry.key);
    for (final asset in entry.value) {
      loader.addFont(rootBundle.load(asset));
    }
    await loader.load();
  }
  _loaded = true;
}
