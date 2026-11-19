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
  const RideExportChoice({
    required this.clips,
    required this.includeRideData,
    this.section,
  });

  /// Which clips to export.
  final RideExportClips clips;

  /// The clips of a [RideExportClips.section] choice, else `null`.
  final RideExportSection? section;

  /// Whether the ride file goes with them.
  final bool includeRideData;
}

/// Exports [ride] to a picked folder or the share sheet ([destination]):
/// checks the gate, holds the move into private storage for the whole
/// flow, reads the ride file once, asks what to export, picks the folder
/// (for a folder), checks the gate again, runs the export through
/// [CameraProvider.runRideExport] and shows its summary for 8 s.
///
/// [currentClipPath] (Playback: the clip under the playhead) is the
/// section the dialog starts with; without it (or when it is not a clip of
/// the ride) the section starts as the whole ride.
Future<void> runRideExportFlow(
  BuildContext context,
  RideRecord ride,
  RideExportDestination destination, {
  String? currentClipPath,
}) async {
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
    final current = currentClipPath == null
        ? null
        : rideClipNumberOf(source.ride, currentClipPath);
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
        initialSection: current == null
            ? null
            : RideExportSection(current, current),
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
      section: choice.section,
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
/// choices, or a section of whole clips picked on a slider when the ride
/// has more than one clip), whether to include the ride data, and what the
/// rider should know before handing the files over. Pops a
/// [RideExportChoice], or `null` on Cancel.
class RideExportDialog extends StatefulWidget {
  /// Creates the dialog.
  const RideExportDialog({
    super.key,
    required this.destination,
    required this.evidence,
    required this.all,
    required this.hasRideData,
    this.initialSection,
  });

  /// Folder or share; sets the title, the button and the notes.
  final RideExportDestination destination;

  /// The plan of the locked and incident clips.
  final RideExportPlan evidence;

  /// The plan of all clips.
  final RideExportPlan all;

  /// Whether the ride has a ride file to include.
  final bool hasRideData;

  /// The section the slider starts at (Playback: the clip under the
  /// playhead); the whole ride when `null` or outside the ride.
  final RideExportSection? initialSection;

  @override
  State<RideExportDialog> createState() => _RideExportDialogState();
}

class _RideExportDialogState extends State<RideExportDialog> {
  late RideExportClips _clips = widget.evidence.clips.isEmpty
      ? RideExportClips.all
      : RideExportClips.evidence;
  late bool _includeRideData = widget.hasRideData;

  /// The ride (as the plans read it) and its clip count.
  late final RideRecord _ride = widget.all.source.ride;
  late final int _clipCount = _ride.segmentPaths.length;

  late RideExportSection _section = _initialSection();

  RideExportSection _initialSection() {
    final initial = widget.initialSection;
    return initial != null &&
            initial.firstClip >= 1 &&
            initial.firstClip <= initial.lastClip &&
            initial.lastClip <= _clipCount
        ? initial
        : RideExportSection(1, _clipCount);
  }

  String _label(String text, RideExportPlan plan) =>
      '$text (${plan.clips.length}, ${formatFileSize(plan.clipBytes)})';

  /// The existing clips of [_section] (from the all-clips plan).
  List<RideExportItem> _sectionClips() {
    final numbers = <String, int>{
      for (var i = 0; i < _clipCount; i++) _ride.segmentPaths[i]: i + 1,
    };
    return <RideExportItem>[
      for (final item in widget.all.clips)
        if (numbers[item.sourcePath] case final number?)
          if (number >= _section.firstClip && number <= _section.lastClip) item,
    ];
  }

  /// For example 'Clips 3 to 5 of 6 (14:05 to 14:21), 3 clips, 1.1 GB';
  /// without a timeline the ride times are left out.
  String _sectionLabel(List<RideExportItem> clips) {
    final first = _section.firstClip;
    final last = _section.lastClip;
    final range = first == last
        ? 'Clip $first of $_clipCount'
        : 'Clips $first to $last of $_clipCount';
    final span = rideExportSectionSpan(_ride, _section);
    final times = span == null
        ? ''
        : ' (${rideExportClockText(_ride, span.fromMs)} to '
              '${rideExportClockText(_ride, span.toMs)})';
    final count = clips.length == 1 ? '1 clip' : '${clips.length} clips';
    final bytes = clips.fold(0, (sum, item) => sum + item.bytes);
    return '$range$times, $count, ${formatFileSize(bytes)}';
  }

  Widget _buildSection(List<RideExportItem> clips) {
    final hasTimeline = _ride.segmentTimeline.isNotEmpty;
    final locks = <int>{
      if (hasTimeline)
        for (final path in _ride.lockedSegmentPaths)
          ?rideClipNumberOf(_ride, path),
    };
    final incidents = <int>{if (hasTimeline) ...rideIncidentClipNumbers(_ride)};
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RangeSlider(
          values: RangeValues(
            _section.firstClip.toDouble(),
            _section.lastClip.toDouble(),
          ),
          min: 1,
          max: _clipCount.toDouble(),
          divisions: _clipCount - 1,
          onChanged: (values) => setState(
            () => _section = RideExportSection(
              values.start.round(),
              values.end.round(),
            ),
          ),
        ),
        if (locks.isNotEmpty || incidents.isNotEmpty)
          _SectionMarks(
            clipCount: _clipCount,
            locks: locks,
            incidents: incidents,
          ),
        Text(_sectionLabel(clips)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final share = widget.destination == RideExportDestination.share;
    final sectionClips = _sectionClips();
    final chosen = switch (_clips) {
      RideExportClips.evidence => widget.evidence.clips,
      RideExportClips.all => widget.all.clips,
      RideExportClips.section => sectionClips,
    };
    final hasSomething = chosen.isNotEmpty || _includeRideData;
    final isSection = _clips == RideExportClips.section;
    final notes = <String>[
      'Videos show other road users: share them only for your own records, '
          'the police or your insurer.',
      if (share)
        'MotoCam cannot check a share. In messengers send as a document, not '
            'as video, or the video is re-encoded.'
      else
        'The folder you pick is shared storage: other apps with media or '
            'storage access, and gallery backups, may see these files.',
      if (_includeRideData && isSection)
        'The ride data covers the whole ride, including the route outside '
            'this section.',
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
                if (_clipCount > 1)
                  RadioListTile<RideExportClips>(
                    value: RideExportClips.section,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('A section of the ride'),
                  ),
              ],
            ),
          ),
          if (isSection) _buildSection(sectionClips),
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
                    section: isSection ? _section : null,
                  ),
                )
              : null,
          child: Text(share ? 'Share' : 'Export'),
        ),
      ],
    );
  }
}

/// Small lock and incident marks under the section slider, at the clip
/// numbers in [locks] and [incidents] (1 to [clipCount]).
class _SectionMarks extends StatelessWidget {
  const _SectionMarks({
    required this.clipCount,
    required this.locks,
    required this.incidents,
  });

  final int clipCount;
  final Set<int> locks;
  final Set<int> incidents;

  /// The slider's track inset on each side (its thumb overlay radius).
  static const double _inset = 24;
  static const double _size = 12;

  /// The horizontal alignment of [clip]'s stop: -1 first, 1 last.
  double _x(int clip) =>
      clipCount < 2 ? 0 : 2 * (clip - 1) / (clipCount - 1) - 1;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // No LayoutBuilder: the dialog measures its content's intrinsic width.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _inset - _size / 2),
      child: SizedBox(
        height: 2 * _size + 2,
        child: Stack(
          children: [
            for (final clip in locks)
              Align(
                alignment: Alignment(_x(clip), -1),
                child: Icon(
                  Icons.lock,
                  size: _size,
                  color: colors.primary,
                  semanticLabel: 'Locked clip $clip',
                ),
              ),
            for (final clip in incidents)
              Align(
                alignment: Alignment(_x(clip), 1),
                child: Icon(
                  Icons.warning_amber,
                  size: _size,
                  color: colors.error,
                  semanticLabel: 'Incident in clip $clip',
                ),
              ),
          ],
        ),
      ),
    );
  }
}
