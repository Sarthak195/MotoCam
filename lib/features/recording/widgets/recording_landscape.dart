// lib/features/recording/widgets/recording_landscape.dart
//
// The landscape recording screen's own pieces (redesign A, boards
// A-Land-Record-Ready and A-Land-Record-Live): the narrow rail on the left
// and the thumb column on the right. The screen's State assembles them
// around the live view, the state band and the chips; like the portrait
// widgets they take plain values and callbacks only.

import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/ui/thumb_button.dart';
import 'recording_view_state.dart';

/// Width of the landscape rail, as on the boards.
const double landscapeRailWidth = 64;

/// Width of the landscape thumb column on the boards (844 dp wide).
const double landscapeThumbColumnWidth = 260;

/// The rail at the left edge of the landscape recording screen.
///
/// Idle only: Rides and Settings. Board A-Land-Record-Live has no rail, so
/// the screen leaves it out while recording: Blackout is in the chip row,
/// and Settings and Pop-out are in the parked details panel, as in
/// portrait. Each button keeps the accessibility label the phone harness
/// reads (HISTORY, Settings).
class RecordingLandscapeRail extends StatelessWidget {
  /// Creates the rail.
  const RecordingLandscapeRail({
    super.key,
    required this.view,
    required this.onRides,
    required this.onSettings,
  });

  /// What the screen shows.
  final RecordingViewState view;

  /// Opens the ride history.
  final VoidCallback onRides;

  /// Opens the recording settings.
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    // The rail is as narrow as the boards draw it; a larger system text
    // size would only fade its words, so they keep the board size (the
    // accessibility labels are unchanged).
    final unscale = 1 / MediaQuery.textScalerOf(context).scale(1).clamp(1, 3);
    final buttons = [
      ThumbButton(
        variant: ThumbButtonVariant.secondary,
        label: 'Rides',
        labelSize: 17 * unscale,
        semanticsLabel: 'HISTORY',
        icon: Icons.format_list_bulleted_rounded,
        direction: Axis.vertical,
        height: MotoSize.minTarget,
        onPressed: view.secondaryEnabled ? onRides : null,
      ),
      ThumbButton(
        variant: ThumbButtonVariant.secondary,
        label: 'Settings',
        labelSize: 17 * unscale,
        semanticsLabel: 'Settings',
        icon: Icons.tune_rounded,
        direction: Axis.vertical,
        height: MotoSize.minTarget,
        onPressed: view.settingsEnabled ? onSettings : null,
      ),
    ];
    return SizedBox(
      width: landscapeRailWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            if (i > 0) const SizedBox(height: MotoSize.gap),
            Expanded(child: buttons[i]),
          ],
        ],
      ),
    );
  }
}

/// The thumb column at the right edge of the landscape recording screen.
///
/// Idle: the state band ([band]) above the big START. Recording: STOP (a
/// single tap, kHoldToStop is off, so no "hold 1 s" caption) above the big
/// LOCK, which turns into LOCKED while the clip being recorded is locked.
/// The busy wording, the enabled rules and the harness labels (START
/// RECORDING, STOP RECORDING and its busy variants, LOCK) are the portrait
/// controls' own, from the same [RecordingViewState].
class RecordingLandscapeThumbColumn extends StatelessWidget {
  /// Creates the thumb column.
  const RecordingLandscapeThumbColumn({
    super.key,
    required this.view,
    required this.band,
    required this.onStart,
    required this.onStop,
    required this.onLock,
  });

  /// The state band drawn above START while idle.
  final Widget band;

  /// What the screen shows.
  final RecordingViewState view;

  /// Runs the start flow.
  final VoidCallback onStart;

  /// Runs the stop flow.
  final VoidCallback onStop;

  /// Locks the current clips.
  final VoidCallback onLock;

  /// Height of STOP, as on the board.
  static const double stopHeight = 72;

  @override
  Widget build(BuildContext context) {
    // START and LOCK are far above any reading size already; a larger
    // system text size would only clip them, so their words keep the board
    // size on screen, as in portrait.
    final unscale = 1 / MediaQuery.textScalerOf(context).scale(1).clamp(1, 3);
    final busyWord = view.mainBusyWord;
    if (!view.isRecording) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          band,
          const SizedBox(height: MotoSize.gapWide),
          Expanded(
            child: _BigTarget(
              boardLabelSize: busyWord == null ? 76 : 44,
              unscale: unscale,
              builder: (labelSize) => ThumbButton(
                variant: ThumbButtonVariant.start,
                label: busyWord ?? 'START',
                labelSize: labelSize,
                semanticsLabel: view.mainControlLabel,
                direction: Axis.vertical,
                onPressed: view.isMainBusy ? null : onStart,
              ),
            ),
          ),
        ],
      );
    }
    final locked = view.isSegmentLocked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ThumbButton(
          variant: ThumbButtonVariant.stop,
          label: busyWord ?? 'STOP',
          semanticsLabel: view.mainControlLabel,
          height: stopHeight,
          onPressed: view.isMainBusy ? null : onStop,
        ),
        const SizedBox(height: MotoSize.gapWide),
        Expanded(
          child: _BigTarget(
            boardLabelSize: locked ? 64 : 88,
            unscale: unscale,
            builder: (labelSize) => ThumbButton(
              variant: locked
                  ? ThumbButtonVariant.locked
                  : ThumbButtonVariant.lock,
              label: locked ? 'LOCKED' : 'LOCK',
              labelSize: labelSize,
              semanticsLabel: 'LOCK',
              semanticsHint: locked ? 'The current clips are locked' : null,
              direction: Axis.vertical,
              onPressed: view.lockEnabled ? onLock : null,
            ),
          ),
        ),
      ],
    );
  }
}

/// Sizes the word of START or LOCK (glyph above the word) to the height it
/// gets: the board size when there is room, smaller on a short window, so
/// the column never overflows.
class _BigTarget extends StatelessWidget {
  const _BigTarget({
    required this.boardLabelSize,
    required this.unscale,
    required this.builder,
  });

  final double boardLabelSize;
  final double unscale;
  final Widget Function(double labelSize) builder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The glyph is about 0.9 of the word, the gap between them 22 dp
        // and the button's own padding 8 dp.
        final fit = (constraints.maxHeight - 34) / 2;
        final size = (boardLabelSize * unscale).clamp(
          12.0,
          fit.clamp(12.0, double.infinity),
        );
        return builder(size);
      },
    );
  }
}
