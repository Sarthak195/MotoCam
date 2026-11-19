// lib/core/ui/segmented_row.dart

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// One choice of a [SegmentedRow].
@immutable
class SegmentOption<T> {
  /// Creates a choice.
  const SegmentOption({
    required this.value,
    required this.label,
    this.enabled = true,
    this.semanticsLabel,
  });

  /// The value chosen.
  final T value;

  /// Visible text.
  final String label;

  /// False draws the choice struck through and ignores taps.
  final bool enabled;

  /// Accessibility label; [label] when null.
  final String? semanticsLabel;
}

/// A settings row: a label and an optional status ("Applied 1080p") over a
/// 50 dp tray of equal segments, the selected one filled light.
class SegmentedRow<T> extends StatelessWidget {
  /// Creates a segmented row.
  const SegmentedRow({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.status,
  });

  /// Row label, for example "Resolution".
  final String label;

  /// The choices, left to right.
  final List<SegmentOption<T>> options;

  /// The chosen value.
  final T selected;

  /// Called with a new value; null disables the whole row.
  final ValueChanged<T>? onChanged;

  /// Small dim status on the right of the label.
  final String? status;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              label,
              style: MotoFonts.bodyStyle(
                16,
                weight: FontWeight.w600,
                color: MotoColors.text,
              ),
            ),
            if (status != null) ...[
              const SizedBox(width: MotoSize.gapWide),
              Expanded(
                child: Text(
                  status!,
                  textAlign: TextAlign.end,
                  style: MotoFonts.bodyStyle(13, color: MotoColors.dim),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Semantics(
          container: true,
          label: label,
          explicitChildNodes: true,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: MotoColors.surface,
              borderRadius: BorderRadius.circular(MotoRadii.sm),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: MotoSize.tray),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final option in options)
                      Expanded(child: _segment(option)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _segment(SegmentOption<T> option) {
    final isSelected = option.value == selected;
    final enabled = onChanged != null && option.enabled;
    final Color foreground;
    if (isSelected) {
      foreground = MotoColors.bg;
    } else if (option.enabled) {
      foreground = MotoColors.dim;
    } else {
      foreground = MotoColors.muted;
    }
    // The whole tray height (50 dp) takes taps; the filled segment is drawn
    // 3 dp inside it, with 4 dp between segments, as on the boards.
    return Semantics(
      container: true,
      button: true,
      inMutuallyExclusiveGroup: true,
      checked: isSelected,
      selected: isSelected,
      enabled: enabled,
      label: option.semanticsLabel ?? option.label,
      onTap: enabled ? () => onChanged!(option.value) : null,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => onChanged!(option.value) : null,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            decoration: BoxDecoration(
              color: isSelected ? MotoColors.text : null,
              borderRadius: BorderRadius.circular(MotoRadii.segment),
            ),
            child: Text(
              option.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style:
                  MotoFonts.condensedStyle(
                    20,
                    weight: isSelected ? FontWeight.w700 : FontWeight.w600,
                    color: foreground,
                    tabularFigures: true,
                  ).copyWith(
                    decoration: option.enabled
                        ? null
                        : TextDecoration.lineThrough,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}
