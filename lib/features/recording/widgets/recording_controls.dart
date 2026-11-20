// lib/features/recording/widgets/recording_controls.dart

import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/ui/thumb_button.dart';
import 'recording_view_state.dart';

/// The thumb controls at the bottom of the recording screen.
///
/// Idle: Rides and Settings, then START. Recording: STOP (a single tap;
/// press-and-hold is off with kHoldToStop) and the large LOCK, which turns
/// into LOCKED while the clip being recorded is locked. The LOCK Undo
/// (kLockUndo) and the lock tone (kLockTone) need features the app does not
/// have, so STOP stays full width and nothing promises them.
///
/// Every control keeps the accessibility label the phone harness reads
/// (START RECORDING, STOP RECORDING and its busy variants, HISTORY, LOCK,
/// Settings) while its visible text follows the boards.
class RecordingControls extends StatelessWidget {
  /// Creates the controls.
  const RecordingControls({
    super.key,
    required this.view,
    required this.onStart,
    required this.onStop,
    required this.onRides,
    required this.onSettings,
    required this.onLock,
    this.compact = false,
    this.bigTargetCut = 0,
  });

  /// The most [bigTargetCut] takes off START (220 dp) and LOCK (240 dp).
  static const double maxBigTargetCut = 90;

  /// What the screen shows.
  final RecordingViewState view;

  /// Runs the start flow.
  final VoidCallback onStart;

  /// Runs the stop flow.
  final VoidCallback onStop;

  /// Opens the ride history.
  final VoidCallback onRides;

  /// Opens the recording settings.
  final VoidCallback onSettings;

  /// Locks the current clips.
  final VoidCallback onLock;

  /// Smaller START and LOCK for a short window (a landscape or split
  /// screen before the landscape layouts exist).
  final bool compact;

  /// Height (dp, up to [maxBigTargetCut]) taken off START and LOCK on a
  /// screen shorter than the boards, so the speed keeps its room.
  final double bigTargetCut;

  double get _cut => bigTargetCut.clamp(0, maxBigTargetCut);

  @override
  Widget build(BuildContext context) {
    // START and LOCK are far above any reading size already; a larger
    // system text size would only clip them, so their words keep the board
    // size on screen.
    final unscale = 1 / MediaQuery.textScalerOf(context).scale(1).clamp(1, 3);
    return view.isRecording ? _buildLive(unscale) : _buildReady(unscale);
  }

  /// Short visible text of a busy START or STOP; the accessibility label
  /// keeps the full wording.
  String? get _busyWord {
    if (view.isApplyingSettings) {
      return 'APPLYING';
    }
    if (view.isSaving) {
      return 'SAVING';
    }
    if (view.isStarting) {
      return 'STARTING';
    }
    if (view.isPreparingCamera) {
      return 'PREPARING';
    }
    return null;
  }

  Widget _buildReady(double unscale) {
    final busyWord = _busyWord;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: ThumbButton(
                variant: ThumbButtonVariant.secondary,
                label: 'Rides',
                semanticsLabel: 'HISTORY',
                icon: Icons.format_list_bulleted_rounded,
                height: compact ? 56 : 76,
                onPressed: view.secondaryEnabled ? onRides : null,
              ),
            ),
            const SizedBox(width: MotoSize.gap),
            Expanded(
              child: ThumbButton(
                variant: ThumbButtonVariant.secondary,
                label: 'Settings',
                semanticsLabel: 'Settings',
                icon: Icons.tune_rounded,
                height: compact ? 56 : 76,
                onPressed: view.settingsEnabled ? onSettings : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: MotoSize.gapWide),
        ThumbButton(
          variant: ThumbButtonVariant.start,
          label: busyWord ?? 'START',
          labelSize:
              (busyWord == null ? (compact ? 56 : 84) : (compact ? 40 : 56)) *
              unscale,
          semanticsLabel: view.mainControlLabel,
          height: compact ? 112 : 220 - _cut,
          onPressed: view.isMainBusy ? null : onStart,
        ),
      ],
    );
  }

  Widget _buildLive(double unscale) {
    final locked = view.isSegmentLocked;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ThumbButton(
          variant: ThumbButtonVariant.stop,
          label: _busyWord ?? 'STOP',
          semanticsLabel: view.mainControlLabel,
          height: compact ? 56 : 72,
          onPressed: view.isMainBusy ? null : onStop,
        ),
        const SizedBox(height: MotoSize.gapWide),
        ThumbButton(
          variant: locked ? ThumbButtonVariant.locked : ThumbButtonVariant.lock,
          label: locked ? 'LOCKED' : 'LOCK',
          labelSize: (compact ? 56 : (locked ? 72 : 96)) * unscale,
          semanticsLabel: 'LOCK',
          semanticsHint: locked ? 'The current clips are locked' : null,
          height: compact ? 112 : 240 - _cut,
          onPressed: view.lockEnabled ? onLock : null,
        ),
      ],
    );
  }
}
