// lib/features/history/widgets/ride_export_flow.dart
//
// The rider's side of ride export, shared by Ride History and Playback:
// the gate check, the choice dialog, the folder picker and the closing
// summary. CameraProvider runs the export itself ([CameraProvider.
// runRideExport]); the export core is services/ride_export.dart.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/services/ride_export_channel.dart';
import '../../../core/utils/format_utils.dart';
import '../../camera/providers/camera_provider.dart';
import '../models/ride_record.dart';
import '../services/ride_export.dart';

/// What the rider chose in the [RideExportDialog].
@immutable
class RideExportChoice {
  /// Creates a choice.
  const RideExportChoice({required this.clips, required this.includeRideData});

  /// Which clips to export.
  final RideExportClips clips;

  /// Whether the ride file goes with them.
  final bool includeRideData;
}

/// Exports [ride] to a picked folder or the share sheet ([destination]):
/// checks the gate, holds the move into private storage for the whole
/// flow, reads the ride file once, asks what to export, picks the folder
/// (for a folder), checks the gate again, runs the export through
/// [CameraProvider.runRideExport] and shows its summary for 8 s.
Future<void> runRideExportFlow(
  BuildContext context,
  RideRecord ride,
  RideExportDestination destination,
) async {
  // Both are captured before the first await: the screen may close while
  // the export runs.
  final messenger = ScaffoldMessenger.of(context);
  final camera = context.read<CameraProvider>();
  void show(String text, {int seconds = 3}) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(text),
        duration: Duration(seconds: seconds),
      ),
    );
  }

  final blocked = camera.rideExportBlockedReason;
  if (blocked != null) {
    show(blocked);
    return;
  }
  // No file of the ride moves into private storage until the flow ends;
  // released last, after the export flag is cleared.
  final releaseMigration = camera.holdRecordingsMigration();
  try {
    final RideExportSource source;
    try {
      source = await loadRideExportSource(ride);
    } on RideExportFailure catch (e) {
      show(e.message ?? rideExportFailureText(e.code));
      return;
    }
    final evidence = await planRideExport(
      source,
      clips: RideExportClips.evidence,
      includeRideData: source.hasRideData,
    );
    final all = await planRideExport(
      source,
      clips: RideExportClips.all,
      includeRideData: source.hasRideData,
    );
    if (!context.mounted) {
      return;
    }
    final choice = await showDialog<RideExportChoice>(
      context: context,
      builder: (_) => RideExportDialog(
        destination: destination,
        evidence: evidence,
        all: all,
        hasRideData: source.hasRideData,
      ),
    );
    if (choice == null || !context.mounted) {
      return;
    }
    String? treeUri;
    if (destination == RideExportDestination.folder) {
      try {
        treeUri = await const RideExportChannel().pickExportFolder();
      } on RideExportFailure catch (e) {
        show(rideExportFailureText(e.code));
        return;
      }
      if (treeUri == null) {
        return;
      }
    }
    final stillBlocked = camera.rideExportBlockedReason;
    if (stillBlocked != null) {
      show(stillBlocked);
      return;
    }
    final plan = await planRideExport(
      source,
      clips: choice.clips,
      includeRideData: choice.includeRideData,
    );
    final result = await camera.runRideExport(
      plan,
      rideKey: ride.telemetryPath ?? ride.videoPath,
      destination: destination,
      treeUri: treeUri,
    );
    show(
      result == null
          ? camera.rideExportBlockedReason ??
                'Could not export the ride on this phone.'
          : rideExportSummary(result),
      seconds: 8,
    );
  } finally {
    releaseMigration();
  }
}

/// The export dialog: which clips ([evidence] or [all], the plans of both
/// choices), whether to include the ride data, and what the rider should
/// know before handing the files over. Pops a [RideExportChoice], or
/// `null` on Cancel.
class RideExportDialog extends StatefulWidget {
  /// Creates the dialog.
  const RideExportDialog({
    super.key,
    required this.destination,
    required this.evidence,
    required this.all,
    required this.hasRideData,
  });

  /// Folder or share; sets the title, the button and the notes.
  final RideExportDestination destination;

  /// The plan of the locked and incident clips.
  final RideExportPlan evidence;

  /// The plan of all clips.
  final RideExportPlan all;

  /// Whether the ride has a ride file to include.
  final bool hasRideData;

  @override
  State<RideExportDialog> createState() => _RideExportDialogState();
}

class _RideExportDialogState extends State<RideExportDialog> {
  late RideExportClips _clips = widget.evidence.clips.isEmpty
      ? RideExportClips.all
      : RideExportClips.evidence;
  late bool _includeRideData = widget.hasRideData;

  String _label(String text, RideExportPlan plan) =>
      '$text (${plan.clips.length}, ${formatFileSize(plan.clipBytes)})';

  @override
  Widget build(BuildContext context) {
    final share = widget.destination == RideExportDestination.share;
    final chosen = _clips == RideExportClips.evidence
        ? widget.evidence
        : widget.all;
    final hasSomething = chosen.clips.isNotEmpty || _includeRideData;
    final notes = <String>[
      'Videos show other road users: share them only for your own records, '
          'the police or your insurer.',
      if (share)
        'MotoCam cannot check a share. In messengers send as a document, not '
            'as video, or the video is re-encoded.'
      else
        'The folder you pick is shared storage: other apps with media or '
            'storage access, and gallery backups, may see these files.',
      if (_includeRideData)
        'All exports from this phone carry the same public key, so they can '
            'be linked to each other.',
      'Keep MotoCam open until the export finishes.',
    ];
    return AlertDialog(
      scrollable: true,
      title: Text(share ? 'Share ride' : 'Export ride'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RadioGroup<RideExportClips>(
            groupValue: _clips,
            onChanged: (value) {
              if (value != null) {
                setState(() => _clips = value);
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<RideExportClips>(
                  value: RideExportClips.evidence,
                  enabled: widget.evidence.clips.isNotEmpty,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    _label('Locked and incident clips', widget.evidence),
                  ),
                ),
                RadioListTile<RideExportClips>(
                  value: RideExportClips.all,
                  contentPadding: EdgeInsets.zero,
                  title: Text(_label('All clips', widget.all)),
                ),
              ],
            ),
          ),
          CheckboxListTile(
            value: _includeRideData,
            onChanged: widget.hasRideData
                ? (value) => setState(() => _includeRideData = value ?? false)
                : null,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Include ride data'),
            subtitle: const Text(
              'Route, speed every second and private file paths. Needed to '
              'check the signature. Leave it out to hand over video only.',
            ),
          ),
          const SizedBox(height: 8),
          for (final note in notes)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(note)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: hasSomething
              ? () => Navigator.of(context).pop(
                  RideExportChoice(
                    clips: _clips,
                    includeRideData: _includeRideData,
                  ),
                )
              : null,
          child: Text(share ? 'Share' : 'Export'),
        ),
      ],
    );
  }
}
