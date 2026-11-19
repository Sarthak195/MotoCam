// lib/features/recording/widgets/recording_controls.dart

import 'package:flutter/material.dart';

import '../recording_screen_logic.dart';
import 'recording_view_state.dart';

/// START or STOP, Rides (or Pop-out while recording) and LOCK.
class RecordingControls extends StatelessWidget {
  /// Creates the controls.
  const RecordingControls({
    super.key,
    required this.view,
    required this.onStart,
    required this.onStop,
    required this.onRides,
    required this.onPop,
    required this.onLock,
  });

  /// What the screen shows.
  final RecordingViewState view;

  /// Runs the start flow.
  final VoidCallback onStart;

  /// Runs the stop flow.
  final VoidCallback onStop;

  /// Opens the ride history.
  final VoidCallback onRides;

  /// Leaves the recording screen into Picture-in-Picture.
  final VoidCallback onPop;

  /// Locks the current clips.
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    // While recording this button minimises into PiP instead of opening
    // history, so it says so.
    final historyLabel = view.isRecording ? 'MINIMISE' : 'HISTORY';
    final historyIcon = view.isRecording
        ? Icons.picture_in_picture_alt
        : Icons.video_library_outlined;
    final presetWarning = view.presetWarning;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton(
                onPressed: view.isMainBusy
                    ? null
                    : (view.isRecording ? onStop : onStart),
                style: ElevatedButton.styleFrom(
                  backgroundColor: view.isRecording
                      ? recordingStopButtonColor
                      : recordingStartButtonColor,
                  foregroundColor: recordingButtonLabelColor,
                  disabledBackgroundColor: Colors.grey.shade800,
                  disabledForegroundColor: Colors.white70,
                  minimumSize: const Size(double.infinity, 52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  view.mainControlLabel,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (view.isApplyingSettings)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Applying settings... camera controls are temporarily locked.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (presetWarning != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    presetWarning,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.orange,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: view.secondaryEnabled
                      ? (view.isRecording ? onPop : onRides)
                      : null,
                  icon: Icon(historyIcon, color: Colors.blue),
                  label: Text(
                    historyLabel,
                    style: const TextStyle(fontSize: 14, color: Colors.blue),
                  ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    side: const BorderSide(color: Colors.blue),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: view.lockEnabled ? onLock : null,
                  icon: const Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.orange,
                  ),
                  label: const Text(
                    'LOCK',
                    style: TextStyle(fontSize: 14, color: Colors.orange),
                  ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    side: BorderSide(
                      color: view.isRecording
                          ? Colors.orange
                          : Colors.orange.withValues(alpha: 0.3),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
