// lib/features/recording/widgets/recording_profile_bar.dart

import 'package:flutter/material.dart';

import 'recording_view_state.dart';

/// The recording profile chips and the warnings under them.
class RecordingProfileBar extends StatelessWidget {
  /// Creates the profile bar.
  const RecordingProfileBar({super.key, required this.view});

  /// What the screen shows.
  final RecordingViewState view;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      if (view.cameraName.isNotEmpty) _chip('Cam ${view.cameraName}'),
      _chip(view.resolutionLabel),
      _chip(view.fpsLabel),
      _chip('${view.requestedBitrateMbps} Mbps'),
      _chip(view.audioEnabled ? 'Audio On' : 'Audio Off'),
      _chip('${view.segmentLabel} x ${view.loopSegmentCount} loop'),
      _chip('Incident ${view.incidentSensitivityName.toUpperCase()}'),
      _chip('Speed ${view.speedRefreshMs}ms'),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: chips.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, index) => chips[index],
            ),
          ),
          if (view.incidentDetectionUnavailable)
            _warning(
              'Incident detection unavailable (no motion sensor): '
              'clips are not auto-locked. Use LOCK.',
            ),
          if (view.locationOff)
            _warning(
              'Location is off: no speed, distance or route is recorded.',
            ),
          if (view.highIncidentSensitivity)
            _warning(
              'High incident sensitivity may increase auto-lock frequency.',
            ),
        ],
      ),
    );
  }

  Widget _warning(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.orange.withValues(alpha: 0.9),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _chip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
