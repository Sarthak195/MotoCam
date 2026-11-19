// Shared set-up for the component kit tests: the real fonts, the app theme
// and the two phone surfaces of the plan (portrait 390x844 and landscape
// 844x390, at device pixel ratio 1).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/core/theme/app_theme.dart';
import 'package:motocam/core/theme/tokens.dart';

/// The two surfaces every component is checked on.
const Map<String, Size> kitSurfaces = {
  'portrait 390x844': Size(390, 844),
  'landscape 844x390': Size(844, 390),
};

/// Pumps [child] on a surface of [size], inside the app theme, a scaffold
/// and the 16 dp page gutter. Resets the view when the test ends.
Future<void> pumpKit(
  WidgetTester tester,
  Size size,
  Widget child, {
  double textScale = 1,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(MotoSize.gutter),
              child: Align(alignment: Alignment.topCenter, child: child),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Fails on any exception the frame reported, which includes RenderFlex
/// overflows.
void expectNoLayoutErrors(WidgetTester tester) {
  expect(tester.takeException(), isNull);
}

/// Applies the Android tap-target guideline and checks text contrast.
///
/// Text contrast is checked from the widgets' own colours for every text
/// (see [expectTextContrast]). Flutter's pixel-sampling
/// `textContrastGuideline` runs as well unless [pixelContrast] is false: it
/// reads the anti-aliased edges of small regular-weight Barlow (13 to 14 px)
/// as the text colour and reports ratios far below the real ones, so the
/// rows with such text turn it off.
Future<void> expectAccessibleKit(
  WidgetTester tester, {
  bool pixelContrast = true,
}) async {
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  expectTextContrast(tester);
  if (pixelContrast) {
    await expectLater(tester, meetsGuideline(textContrastGuideline));
  }
}

/// Checks every visible text span against the opaque colour it is drawn
/// on: 4.5:1, or 3:1 for large text (18 px, or 14 px bold).
void expectTextContrast(WidgetTester tester) {
  var checked = 0;
  for (final element in find.byType(RichText).evaluate()) {
    final rich = element.widget as RichText;
    final background = _backgroundOf(element);
    void visit(InlineSpan span, TextStyle inherited) {
      final style = inherited.merge(span.style);
      if (span is TextSpan) {
        final text = span.text ?? '';
        final isIcon = style.fontFamily == 'MaterialIcons';
        if (text.trim().isNotEmpty && !isIcon) {
          final colour = style.color ?? const Color(0xFF000000);
          final drawn = Color.alphaBlend(colour, background);
          final size = style.fontSize ?? 14;
          final bold = (style.fontWeight ?? FontWeight.w400).value >= 700;
          final large = size >= 18 || (size >= 14 && bold);
          expect(
            contrastRatio(drawn, background),
            greaterThanOrEqualTo(large ? 3.0 : 4.5),
            reason: '"$text" ($colour on $background, $size px)',
          );
          checked++;
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          visit(child, style);
        }
      }
    }

    visit(rich.text, const TextStyle());
  }
  expect(checked, greaterThan(0), reason: 'no text found to check');
}

Color _backgroundOf(Element element) {
  Color? found;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    Color? colour;
    if (widget is Material && widget.type != MaterialType.transparency) {
      colour = widget.color;
    } else if (widget is ColoredBox) {
      colour = widget.color;
    } else if (widget is DecoratedBox) {
      final decoration = widget.decoration;
      if (decoration is BoxDecoration) {
        colour = decoration.color;
      }
    } else if (widget is Scaffold) {
      colour = Theme.of(ancestor).scaffoldBackgroundColor;
    }
    if (colour != null && colour.a == 1) {
      found = colour;
      return false;
    }
    return true;
  });
  return found ?? MotoColors.bg;
}
