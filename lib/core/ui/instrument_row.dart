// lib/core/ui/instrument_row.dart

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// A list row of the parked screens (checklist, settings, history): a
/// leading icon, a title over a dim subtitle, and a trailing slot for a
/// status word or a button.
class InstrumentRow extends StatelessWidget {
  /// Creates a row.
  const InstrumentRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.attention = false,
    this.minHeight = MotoSize.row,
    this.borderRadius = const BorderRadius.all(Radius.circular(MotoRadii.md)),
    this.semanticsLabel,
  });

  /// Row title.
  final String title;

  /// Dim second line.
  final String? subtitle;

  /// Leading icon, coloured dim unless it sets its own colour.
  final Widget? leading;

  /// Trailing status word or button.
  final Widget? trailing;

  /// Makes the whole row tappable when set.
  final VoidCallback? onTap;

  /// Draws the amber outline of an item that needs attention.
  final bool attention;

  /// Minimum height (64 on the checklist, 48 for settings links).
  final double minHeight;

  /// Corner radius; grouped settings links square their inner corners.
  final BorderRadius borderRadius;

  /// Accessibility label for a tappable row; title and subtitle when null.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final body = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: EdgeInsets.fromLTRB(attention ? 12 : 14, 6, 8, 6),
        child: Row(
          children: [
            if (leading != null) ...[
              IconTheme.merge(
                data: const IconThemeData(color: MotoColors.dim, size: 24),
                child: leading!,
              ),
              const SizedBox(width: MotoSize.gapWide),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: MotoFonts.bodyStyle(
                      17,
                      weight: FontWeight.w600,
                      color: MotoColors.text,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: MotoFonts.bodyStyle(14, color: MotoColors.dim),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: MotoSize.gapWide),
              trailing!,
            ],
          ],
        ),
      ),
    );

    final shape = RoundedRectangleBorder(
      borderRadius: borderRadius,
      side: attention
          ? const BorderSide(
              color: MotoColors.amber,
              width: 2,
              strokeAlign: BorderSide.strokeAlignInside,
            )
          : BorderSide.none,
    );

    return Material(
      color: MotoColors.surface,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? body
          : Semantics(
              button: true,
              label: semanticsLabel,
              child: InkWell(
                onTap: onTap,
                highlightColor: MotoColors.text.withValues(alpha: 0.08),
                splashColor: MotoColors.text.withValues(alpha: 0.12),
                child: body,
              ),
            ),
    );
  }
}
