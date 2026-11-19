// lib/core/ui/state_band.dart

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'moto_glyph.dart';

/// The recording states the band shows.
enum BandState {
  /// Camera ready, not recording.
  ready,

  /// START pressed, recording not confirmed yet.
  starting,

  /// Recording.
  recording,

  /// STOP pressed, the last clip is being finalised.
  saving,

  /// Clips are locked against looping deletion.
  locked,
}

/// The band at the top of the recording screen that names the state.
///
/// States differ by fill, outline and glyph shape as well as by colour:
/// READY is an outlined band with an open ring, STARTING an outlined band in
/// the REC colour with a ring and dot, REC a solid band with a filled dot,
/// SAVING a grey band with a square, and LOCKED a solid blue band with a
/// padlock.
class StateBand extends StatelessWidget {
  /// Creates a state band.
  const StateBand({
    super.key,
    required this.state,
    this.trailing,
    this.detail,
    this.semanticsLabel,
  });

  /// The state to show.
  final BandState state;

  /// Right-aligned value: the elapsed time, or the locked time range.
  final String? trailing;

  /// Optional second line under the state (shown on the REC band).
  final String? detail;

  /// Accessibility label; a plain description of [state] when null.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final spec = _BandSpec.of(state);
    final hasDetail = detail != null && detail!.isNotEmpty;
    // The state word keeps its full width; the trailing value scales down
    // into what is left, so a long range never pushes the word out.
    final headline = LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxWidth - 30 - spec.gap;
        return Row(
          children: [
            spec.glyph(),
            SizedBox(width: spec.gap),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: (room - (trailing == null ? 0 : 64)).clamp(
                  0.0,
                  double.infinity,
                ),
              ),
              child: Text(
                spec.label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
                style: MotoFonts.condensedStyle(
                  spec.labelSize,
                  letterSpacingEm: spec.labelSpacingEm,
                  color: spec.foreground,
                  height: 1,
                ),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: MotoSize.gapWide),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    trailing!,
                    maxLines: 1,
                    softWrap: false,
                    style: MotoFonts.condensedStyle(
                      spec.trailingSize,
                      weight: spec.trailingWeight,
                      color: spec.trailingColor,
                      height: 1,
                      tabularFigures: true,
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );

    return Semantics(
      container: true,
      liveRegion: true,
      label: semanticsLabel ?? spec.semanticsLabel,
      child: ExcludeSemantics(
        child: Container(
          constraints: BoxConstraints(
            minHeight: hasDetail ? _minHeightWithDetail : spec.minHeight,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: spec.horizontalPadding,
            vertical: MotoSize.gapWide,
          ),
          decoration: BoxDecoration(
            color: spec.fill,
            borderRadius: BorderRadius.circular(MotoRadii.md),
            border: spec.outline == null
                ? null
                : Border.all(color: spec.outline!, width: 2),
          ),
          child: hasDetail
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    headline,
                    const SizedBox(height: MotoSize.gapWide),
                    Text(
                      detail!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: MotoFonts.bodyStyle(
                        16,
                        weight: FontWeight.w600,
                        color: spec.foreground,
                      ),
                    ),
                  ],
                )
              : Align(alignment: Alignment.centerLeft, child: headline),
        ),
      ),
    );
  }
}

/// Height of a band with a second line, as the REC band on the boards.
const double _minHeightWithDetail = 112;

class _BandSpec {
  const _BandSpec({
    required this.label,
    required this.semanticsLabel,
    required this.foreground,
    required this.trailingColor,
    required this.glyph,
    this.fill,
    this.outline,
    this.labelSize = 40,
    this.labelSpacingEm = 0.06,
    this.trailingSize = 28,
    this.trailingWeight = FontWeight.w600,
    this.minHeight = 72,
    this.gap = 14,
    this.horizontalPadding = 18,
  });

  final String label;
  final String semanticsLabel;
  final Color foreground;
  final Color trailingColor;
  final Widget Function() glyph;
  final Color? fill;
  final Color? outline;
  final double labelSize;
  final double labelSpacingEm;
  final double trailingSize;
  final FontWeight trailingWeight;
  final double minHeight;
  final double gap;
  final double horizontalPadding;

  static _BandSpec of(BandState state) {
    switch (state) {
      case BandState.ready:
        return _BandSpec(
          label: 'READY',
          semanticsLabel: 'State: ready, not recording',
          foreground: MotoColors.text,
          trailingColor: MotoColors.muted,
          outline: MotoColors.muted,
          glyph: () => const MotoGlyph(
            shape: MotoGlyphShape.ring,
            size: 30,
            color: MotoColors.text,
          ),
        );
      case BandState.starting:
        return _BandSpec(
          label: 'STARTING',
          semanticsLabel: 'State: starting the recording',
          foreground: MotoColors.text,
          trailingColor: MotoColors.dim,
          outline: MotoColors.rec,
          glyph: () => const MotoGlyph(
            shape: MotoGlyphShape.ringDot,
            size: 30,
            color: MotoColors.rec,
          ),
        );
      case BandState.recording:
        return _BandSpec(
          label: 'REC',
          semanticsLabel: 'Recording, video is being written',
          foreground: MotoColors.bg,
          trailingColor: MotoColors.bg,
          fill: MotoColors.rec,
          labelSize: 44,
          trailingSize: 50,
          trailingWeight: FontWeight.w700,
          gap: 12,
          glyph: () => const MotoGlyph(
            shape: MotoGlyphShape.dot,
            size: 30,
            color: MotoColors.bg,
          ),
        );
      case BandState.saving:
        return _BandSpec(
          label: 'SAVING',
          semanticsLabel: 'State: saving the recording',
          foreground: MotoColors.text,
          trailingColor: MotoColors.dim,
          fill: MotoColors.surfaceTop,
          outline: MotoColors.text,
          glyph: () => const MotoGlyph(
            shape: MotoGlyphShape.square,
            size: 30,
            color: MotoColors.text,
          ),
        );
      case BandState.locked:
        return _BandSpec(
          label: 'LOCKED',
          semanticsLabel: 'Locked: the current clips are protected',
          foreground: MotoColors.bg,
          trailingColor: MotoColors.bg,
          fill: MotoColors.lock,
          labelSize: 26,
          labelSpacingEm: 0.05,
          trailingWeight: FontWeight.w700,
          minHeight: 60,
          gap: 12,
          horizontalPadding: 16,
          glyph: () =>
              const Icon(Icons.lock_rounded, size: 26, color: MotoColors.bg),
        );
    }
  }
}
