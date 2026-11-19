// lib/features/recording/widgets/recording_header.dart

import 'package:flutter/material.dart';

import 'recording_view_state.dart';

/// The top row of the recording screen: the app name, Blackout and
/// Settings.
class RecordingHeader extends StatelessWidget {
  /// Creates the header.
  const RecordingHeader({
    super.key,
    required this.view,
    required this.onBlackout,
    required this.onSettings,
  });

  /// What the screen shows.
  final RecordingViewState view;

  /// Toggles Blackout.
  final VoidCallback onBlackout;

  /// Opens the recording settings.
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'MotoCam',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          Row(
            children: [
              IconButton(
                icon: Icon(
                  view.isBlackoutMode ? Icons.light_mode : Icons.dark_mode,
                  color: view.isRecording ? Colors.white : Colors.white30,
                ),
                tooltip: view.isBlackoutMode
                    ? 'Exit blackout'
                    : 'Enter blackout',
                onPressed: view.blackoutEnabled ? onBlackout : null,
              ),
              IconButton(
                icon: const Icon(Icons.settings, color: Colors.white),
                tooltip: 'Settings',
                onPressed: view.settingsEnabled ? onSettings : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
