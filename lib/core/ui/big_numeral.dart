// lib/core/ui/big_numeral.dart

import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';

/// A large reading in Barlow Condensed with tabular figures (speed, or a
/// timer), with an optional unit set small at its baseline.
///
/// It scales down to fit its width, so a three-digit speed never overflows.
class BigNumeral extends StatelessWidget {
  /// Creates a big numeral.
  const BigNumeral({
    super.key,
    required this.value,
    required this.semanticsLabel,
    this.unit,
    this.size = 220,
    this.color = MotoColors.text,
    this.unitColor = MotoColors.dim,
  });

  /// The reading, for example "62" or "41:12".
  final String value;

  /// Accessibility label, for example "Speed 62 kilometres per hour".
  final String semanticsLabel;

  /// Unit, for example "km/h".
  final String? unit;

  /// Font size of [value] at full scale.
  final double size;

  /// Colour of [value].
  final Color color;

  /// Colour of [unit].
  final Color unitColor;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: semanticsLabel,
      excludeSemantics: true,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              maxLines: 1,
              softWrap: false,
              style: MotoFonts.condensedStyle(
                size,
                letterSpacingEm: -0.02,
                color: color,
                height: 1,
                tabularFigures: true,
              ),
            ),
            if (unit != null) ...[
              const SizedBox(width: MotoSize.gap),
              Text(
                unit!,
                maxLines: 1,
                softWrap: false,
                style: MotoFonts.condensedStyle(
                  24,
                  weight: FontWeight.w600,
                  color: unitColor,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
