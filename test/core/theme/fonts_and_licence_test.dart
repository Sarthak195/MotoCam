import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/core/theme/font_licence.dart';
import 'package:motocam/core/theme/tokens.dart';

import '../../support/load_fonts.dart';

double _width(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('bundled fonts', () {
    setUpAll(loadBundledFonts);

    test('every font file is a TrueType font', () async {
      for (final assets in bundledFonts.values) {
        for (final asset in assets) {
          final data = await rootBundle.load(asset);
          expect(data.getUint32(0), 0x00010000, reason: asset);
        }
      }
    });

    test('both families load and replace the Ahem test font', () {
      // Ahem draws every glyph as a 1 em square, so 'MMMM' at 20 px would
      // be exactly 80 px wide, and 'iiii' would be too.
      for (final family in bundledFonts.keys) {
        final style = TextStyle(fontFamily: family, fontSize: 20);
        expect(
          _width('iiii', style),
          lessThan(_width('MMMM', style)),
          reason: family,
        );
        expect(_width('MMMM', style), isNot(80));
      }
    });

    test('Barlow Condensed is narrower than Barlow', () {
      const sample = 'START RECORDING';
      expect(
        _width(sample, MotoFonts.condensedStyle(40)),
        lessThan(
          _width(sample, MotoFonts.bodyStyle(40, weight: FontWeight.w600)),
        ),
      );
    });

    test('tabular figures make every digit the same width', () {
      for (final family in bundledFonts.keys) {
        final style = TextStyle(
          fontFamily: family,
          fontSize: 50,
          fontWeight: FontWeight.w700,
          fontFeatures: MotoFonts.tabular,
        );
        final widths = {
          for (final digit in '0123456789'.split(''))
            _width(digit * 4, style).toStringAsFixed(2),
        };
        expect(widths, hasLength(1), reason: family);
      }
    });
  });

  test('pubspec declares both families with the board weights', () async {
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json'))
            as List<dynamic>;
    final declared = <String, Map<String, int?>>{};
    for (final family in manifest.cast<Map<String, dynamic>>()) {
      final fonts = (family['fonts'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      declared[family['family'] as String] = {
        for (final font in fonts)
          (font['asset'] as String).split('/').last: font['weight'] as int?,
      };
    }
    expect(declared[MotoFonts.body], {
      'Barlow-Regular.ttf': 400,
      'Barlow-Medium.ttf': 500,
      'Barlow-SemiBold.ttf': 600,
    });
    expect(declared[MotoFonts.condensed], {
      'BarlowCondensed-Medium.ttf': 500,
      'BarlowCondensed-SemiBold.ttf': 600,
      'BarlowCondensed-Bold.ttf': 700,
    });
  });

  group('font licence', () {
    test('the OFL text is bundled', () async {
      final text = await rootBundle.loadString(fontLicenceAsset);
      expect(text, contains('SIL OPEN FONT LICENSE Version 1.1'));
      expect(text, contains('The Barlow Project Authors'));
    });

    test('is registered once and lists both families', () async {
      registerFontLicence();
      registerFontLicence();
      final entries = await LicenseRegistry.licenses
          .where((entry) => entry.packages.contains('Barlow'))
          .toList();
      expect(entries, hasLength(1));
      expect(entries.single.packages, contains('Barlow Condensed'));
      final paragraphs = entries.single.paragraphs
          .map((paragraph) => paragraph.text)
          .join('\n');
      expect(paragraphs, contains('SIL OPEN FONT LICENSE'));
    });
  });
}
