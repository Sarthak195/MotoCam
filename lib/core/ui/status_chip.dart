// lib/core/ui/status_chip.dart

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'dashed_outline.dart';

/// How a [StatusChip] is drawn.
enum StatusChipVariant {
  /// Normal reading: grey outline.
  neutral,

  /// Advisory (for example a warm phone): amber outline.
  amber,

  /// Needs attention (hot phone, storage low): solid amber fill.
  warning,

  /// Reserved for a later release: dashed grey outline. Only for slots
  /// whose build flag is on; a hidden slot is left out of the tree instead.
  reserved,
}

/// A 52 dp instrument chip: an icon and a value with a unit, or a small
/// caption over a value.
class StatusChip extends StatelessWidget {
  /// Creates a chip.
  const StatusChip({
    super.key,
    required this.variant,
    required this.semanticsLabel,
    this.icon,
    this.value,
    this.unit,
    this.caption,
    this.width,
  });

  /// How the chip is drawn.
  final StatusChipVariant variant;

  /// Accessibility label, for example "Storage: 6.2 hours left".
  final String semanticsLabel;

  /// Leading icon.
  final IconData? icon;

  /// The reading, drawn large in Barlow Condensed with tabular figures.
  final String? value;

  /// Unit after [value], drawn smaller.
  final String? unit;

  /// Small caption above [value] (for example "APPLIED"). When set, the
  /// chip stacks caption and value instead of placing them in a row.
  final String? caption;

  /// Fixed width; the chip sizes to its content when null.
  final double? width;

  @override
  Widget build(BuildContext context) {
    final warning = variant == StatusChipVariant.warning;
    final reserved = variant == StatusChipVariant.reserved;
    final foreground = warning
        ? MotoColors.bg
        : reserved
        ? MotoColors.dim
        : MotoColors.text;
    final secondary = warning ? MotoColors.bg : MotoColors.dim;
    final iconColor = switch (variant) {
      StatusChipVariant.neutral => MotoColors.dim,
      StatusChipVariant.amber => MotoColors.amber,
      StatusChipVariant.warning => MotoColors.bg,
      StatusChipVariant.reserved => MotoColors.dim,
    };

    final Widget content;
    if (caption != null) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            caption!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MotoFonts.bodyStyle(
              12,
              letterSpacingEm: 0.08,
              color: warning ? MotoColors.bg : MotoColors.muted,
              height: 1.1,
            ),
          ),
          if (value != null)
            Text(
              unit == null ? value! : '${value!} ${unit!}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MotoFonts.condensedStyle(
                20,
                weight: FontWeight.w600,
                color: foreground,
                height: 1.1,
                tabularFigures: true,
              ),
            ),
        ],
      );
    } else {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) Icon(icon, size: 22, color: iconColor),
          if (icon != null && value != null) const SizedBox(width: 6),
          if (value != null)
            Flexible(
              child: Text.rich(
                TextSpan(
                  text: value,
                  children: [
                    if (unit != null)
                      TextSpan(
                        text: ' ${unit!}',
                        style: MotoFonts.condensedStyle(
                          18,
                          weight: FontWeight.w600,
                          color: secondary,
                        ),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MotoFonts.condensedStyle(
                  28,
                  color: foreground,
                  height: 1,
                  tabularFigures: true,
                ),
              ),
            ),
        ],
      );
    }

    Widget chip = Container(
      width: width,
      constraints: const BoxConstraints(minHeight: MotoSize.chip),
      padding: const EdgeInsets.symmetric(horizontal: MotoSize.gapWide),
      decoration: BoxDecoration(
        color: warning ? MotoColors.amber : null,
        borderRadius: BorderRadius.circular(MotoRadii.sm),
        border: switch (variant) {
          StatusChipVariant.neutral => Border.all(
            color: MotoColors.hairlineStrong,
            width: 2,
          ),
          StatusChipVariant.amber => Border.all(
            color: MotoColors.amber,
            width: 2,
          ),
          _ => null,
        },
      ),
      alignment: caption != null ? Alignment.centerLeft : Alignment.center,
      child: content,
    );
    if (reserved) {
      chip = DashedOutline(
        color: MotoColors.muted,
        radius: MotoRadii.sm,
        child: chip,
      );
    }

    return Semantics(
      container: true,
      label: semanticsLabel,
      child: ExcludeSemantics(child: chip),
    );
  }
}
