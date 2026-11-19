// lib/core/ui/thumb_button.dart

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'moto_glyph.dart';

/// The kinds of [ThumbButton].
enum ThumbButtonVariant {
  /// START: light fill, dark label, a ring and red dot.
  start,

  /// STOP: dark fill with a REC-coloured outline and a red square.
  stop,

  /// LOCK: solid blue fill, dark label.
  lock,

  /// LOCKED: dark fill with a thick blue outline and a blue label.
  locked,

  /// Secondary actions (Rides, Settings): raised grey fill.
  secondary,

  /// Quiet actions (Dark, Pop-out): low fill, dim label under the icon.
  quiet,
}

/// A large, glove-friendly button: at least 48 dp in both directions, with
/// a visible press state.
///
/// The visible [label] and the accessibility [semanticsLabel] are separate,
/// so the phone harness can keep finding `START RECORDING` while the button
/// reads "START".
class ThumbButton extends StatelessWidget {
  /// Creates a thumb button.
  const ThumbButton({
    super.key,
    required this.variant,
    required this.label,
    required this.semanticsLabel,
    required this.onPressed,
    this.height,
    this.labelSize,
    this.icon,
    this.hint,
    this.direction = Axis.horizontal,
    this.semanticsOnLongPress,
    this.semanticsHint,
    this.holdProgress = 0,
  });

  /// Which button this is.
  final ThumbButtonVariant variant;

  /// Visible text.
  final String label;

  /// Accessibility label.
  final String semanticsLabel;

  /// Called on tap; null draws the disabled state.
  final VoidCallback? onPressed;

  /// Height; each variant has a board default.
  final double? height;

  /// Label font size; each variant has a board default.
  final double? labelSize;

  /// Icon for the secondary and quiet variants, or to replace the padlock
  /// of LOCK and LOCKED.
  final IconData? icon;

  /// Small text after (or under) the label, such as "hold 1 s".
  final String? hint;

  /// Row (icon beside the label) or column (icon above), as in landscape.
  /// Quiet buttons are always a column.
  final Axis direction;

  /// Accessibility long-press action (used by HoldButton for TalkBack).
  final VoidCallback? semanticsOnLongPress;

  /// Accessibility hint, read after the label.
  final String? semanticsHint;

  /// Progress of a press-and-hold, 0 to 1, drawn as a fill from the left.
  final double holdProgress;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final spec = _ThumbSpec.of(variant, enabled: enabled);
    final size = labelSize ?? spec.labelSize;
    final glyph = _glyph(spec, size);
    final vertical =
        direction == Axis.vertical || variant == ThumbButtonVariant.quiet;

    final labelText = Text(
      label,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.fade,
      style: spec.condensedLabel
          ? MotoFonts.condensedStyle(
              size,
              weight: spec.labelWeight,
              letterSpacingEm: spec.labelSpacingEm,
              color: spec.foreground,
              height: 1,
            )
          : MotoFonts.bodyStyle(size, color: spec.foreground),
    );
    final hintText = hint == null
        ? null
        : Text(
            hint!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MotoFonts.bodyStyle(
              variant == ThumbButtonVariant.locked ? 16 : 15,
              color: enabled ? MotoColors.dim : spec.foreground,
            ),
          );

    final List<Widget> children = [
      ?glyph,
      if (glyph != null) SizedBox.square(dimension: spec.gap),
      Flexible(child: labelText),
      if (hintText != null && !vertical) ...[
        const SizedBox(width: 14),
        Flexible(child: hintText),
      ],
    ];
    final Widget content = vertical
        ? Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              ...children,
              if (hintText != null) ...[const SizedBox(height: 8), hintText],
            ],
          )
        : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: children,
          );

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(spec.radius),
      side: spec.outline == null
          ? BorderSide.none
          : BorderSide(
              color: spec.outline!,
              width: spec.outlineWidth,
              strokeAlign: BorderSide.strokeAlignInside,
            ),
    );

    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: semanticsLabel,
      hint: semanticsHint,
      onTap: onPressed,
      onLongPress: enabled ? semanticsOnLongPress : null,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: height ?? spec.height,
          minWidth: MotoSize.minTarget,
        ),
        child: Material(
          color: spec.fill,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            highlightColor: spec.foreground.withValues(alpha: 0.14),
            splashColor: spec.foreground.withValues(alpha: 0.18),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (holdProgress > 0)
                  Positioned.fill(
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: holdProgress.clamp(0.0, 1.0),
                      child: ColoredBox(color: spec.holdFill),
                    ),
                  ),
                Padding(
                  // The boards use no inner padding; 2 dp keeps the label
                  // off the outline.
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 4,
                  ),
                  child: Center(child: content),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget? _glyph(_ThumbSpec spec, double labelSize) {
    switch (variant) {
      case ThumbButtonVariant.start:
        return MotoGlyph(
          shape: MotoGlyphShape.startMark,
          size: labelSize * 0.9,
          color: spec.foreground,
          accent: onPressed == null ? spec.foreground : MotoColors.recDot,
        );
      case ThumbButtonVariant.stop:
        return MotoGlyph(
          shape: MotoGlyphShape.square,
          size: labelSize * 0.8,
          color: onPressed == null ? spec.foreground : MotoColors.rec,
        );
      case ThumbButtonVariant.lock:
      case ThumbButtonVariant.locked:
        return Icon(
          icon ?? Icons.lock_rounded,
          size: labelSize * 0.8,
          color: spec.foreground,
        );
      case ThumbButtonVariant.secondary:
        return icon == null
            ? null
            : Icon(icon, size: 26, color: spec.foreground);
      case ThumbButtonVariant.quiet:
        return icon == null
            ? null
            : Icon(icon, size: 24, color: spec.foreground);
    }
  }
}

class _ThumbSpec {
  const _ThumbSpec({
    required this.fill,
    required this.foreground,
    required this.radius,
    required this.height,
    required this.labelSize,
    required this.gap,
    required this.holdFill,
    this.outline,
    this.outlineWidth = 0,
    this.labelWeight = FontWeight.w700,
    this.labelSpacingEm = 0,
    this.condensedLabel = true,
  });

  final Color fill;
  final Color foreground;
  final double radius;
  final double height;
  final double labelSize;
  final double gap;
  final Color holdFill;
  final Color? outline;
  final double outlineWidth;
  final FontWeight labelWeight;
  final double labelSpacingEm;
  final bool condensedLabel;

  static _ThumbSpec of(ThumbButtonVariant variant, {required bool enabled}) {
    final base = switch (variant) {
      ThumbButtonVariant.start => const _ThumbSpec(
        fill: MotoColors.text,
        foreground: MotoColors.bg,
        radius: MotoRadii.xl,
        height: 220,
        labelSize: 84,
        gap: 22,
        labelSpacingEm: 0.04,
        holdFill: Color(0x33000000),
      ),
      ThumbButtonVariant.stop => const _ThumbSpec(
        fill: MotoColors.bg,
        foreground: MotoColors.text,
        outline: MotoColors.rec,
        outlineWidth: 3,
        radius: MotoRadii.stop,
        height: 72,
        labelSize: 34,
        gap: 14,
        labelSpacingEm: 0.06,
        holdFill: Color(0x59FF5A3D),
      ),
      ThumbButtonVariant.lock => const _ThumbSpec(
        fill: MotoColors.lock,
        foreground: MotoColors.bg,
        radius: MotoRadii.xl,
        height: 240,
        labelSize: 96,
        gap: 22,
        labelSpacingEm: 0.04,
        holdFill: Color(0x33000000),
      ),
      ThumbButtonVariant.locked => const _ThumbSpec(
        fill: MotoColors.bg,
        foreground: MotoColors.lock,
        outline: MotoColors.lock,
        outlineWidth: 8,
        radius: MotoRadii.xl,
        height: 240,
        labelSize: 72,
        gap: 18,
        labelSpacingEm: 0.04,
        holdFill: Color(0x337FB2FF),
      ),
      ThumbButtonVariant.secondary => const _ThumbSpec(
        fill: MotoColors.surfaceHigh,
        foreground: MotoColors.text,
        outline: MotoColors.hairlineStrong,
        outlineWidth: 1,
        radius: MotoRadii.md,
        height: 76,
        labelSize: 26,
        labelWeight: FontWeight.w600,
        gap: 10,
        holdFill: Color(0x33EEF0EA),
      ),
      ThumbButtonVariant.quiet => const _ThumbSpec(
        fill: MotoColors.surface,
        foreground: MotoColors.dim,
        outline: MotoColors.hairlineStrong,
        outlineWidth: 1,
        radius: MotoRadii.md,
        height: 76,
        labelSize: 14,
        gap: 4,
        condensedLabel: false,
        holdFill: Color(0x33B4B9AF),
      ),
    };
    if (enabled) {
      return base;
    }
    // Disabled: a dark grey fill with dim text, the same shape as the
    // enabled button so it does not read as a different control.
    return _ThumbSpec(
      fill: MotoColors.surfaceTop,
      foreground: MotoColors.dim,
      outline: base.outline == null ? null : MotoColors.hairlineStrong,
      outlineWidth: base.outlineWidth,
      radius: base.radius,
      height: base.height,
      labelSize: base.labelSize,
      labelWeight: base.labelWeight,
      labelSpacingEm: base.labelSpacingEm,
      condensedLabel: base.condensedLabel,
      gap: base.gap,
      holdFill: const Color(0x00000000),
    );
  }
}
