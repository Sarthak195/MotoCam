// lib/features/recording/widgets/recording_header.dart

import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/ui/state_band.dart';
import '../recording_screen_logic.dart';
import 'recording_view_state.dart';

/// The state band at the top of the recording screen (READY, STARTING, REC
/// or SAVING with the recording time) and, while the clip being recorded is
/// locked, the LOCKED band under it.
///
/// The landscape layout leaves the LOCKED band out ([showLockedBand]): its
/// 390 dp height keeps the room for the speed, and the big LOCK button
/// under the rider's thumb turns into LOCKED there.
///
/// The time has its own [StreamBuilder], so a tick rebuilds only the band.
/// The boards' "Writing, last 0.4 s ago" line (kShowWriteAge) and the
/// locked time range need data the app does not have yet, so neither is
/// drawn.
class RecordingHeader extends StatelessWidget {
  /// Creates the header.
  const RecordingHeader({
    super.key,
    required this.view,
    required this.timerStream,
    required this.elapsed,
    this.showLockedBand = true,
  });

  /// What the screen shows.
  final RecordingViewState view;

  /// Emits the recording time about once per second.
  final Stream<Duration> timerStream;

  /// The recording time now.
  final Duration elapsed;

  /// Whether a locked clip adds the LOCKED band under the state band.
  final bool showLockedBand;

  @override
  Widget build(BuildContext context) {
    final state = view.bandState;
    final showsTime = state == BandState.recording || state == BandState.saving;
    final band = StreamBuilder<Duration>(
      stream: timerStream,
      initialData: elapsed,
      builder: (context, snapshot) {
        return StateBand(
          state: state,
          trailing: formatBandElapsed(
            showsTime ? snapshot.data ?? Duration.zero : Duration.zero,
          ),
        );
      },
    );

    if (!(showLockedBand && view.isRecording && view.isSegmentLocked)) {
      return band;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        band,
        const SizedBox(height: MotoSize.gapWide),
        const StateBand(state: BandState.locked),
      ],
    );
  }
}
