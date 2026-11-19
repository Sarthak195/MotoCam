// lib/features/history/widgets/ride_export_flow.dart
//
// The rider's side of ride export, shared by Ride History and Playback:
// the gate check, the choice dialog, the folder picker and the closing
// summary. CameraProvider runs the export itself ([CameraProvider.
// runRideExport]); the export core is services/ride_export.dart.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/build_flags.dart';
import '../../../core/services/ride_export_channel.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/format_utils.dart';
import '../../../core/utils/path_utils.dart' as path_utils;
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

  /// The range of a [RideExportClips.section] choice, else `null`.
  final RideExportSection? section;

  /// Whether the ride file goes with them (never for a section).
  final bool includeRideData;
}

/// Exports [ride] to a picked folder or the share sheet ([destination]):
/// checks the gate, holds the move into private storage for the whole
/// flow, reads the ride file once, asks what to export, picks the folder
/// (for a folder), checks the gate again, runs the export through
/// [CameraProvider.runRideExport] and shows its summary for 8 s.
///
/// [playheadMs] (Playback: the playhead, in ms from the ride start) centres
/// the section the dialog starts with; without it the section starts as
/// the first minute of the ride.
Future<void> runRideExportFlow(
  BuildContext context,
  RideRecord ride,
  RideExportDestination destination, {
  int? playheadMs,
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
        playheadMs: playheadMs,
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
    messenger.showSnackBar(
      rideExportSummarySnackBar(
        text: result == null
            ? camera.rideExportBlockedReason ??
                  'Could not export the ride on this phone.'
            : rideExportSummary(result),
        success: rideExportSummaryIsClean(result),
      ),
    );
  } finally {
    releaseMigration();
  }
}

/// Whether an export's summary gets the check mark: a folder export that
/// finished with every clip matching its recorded hash. A share never
/// does, because MotoCam cannot check what the receiving app got; nor does
/// a run that stopped, failed, could not start (`null`) or found clips
/// that differ.
bool rideExportSummaryIsClean(RideExportResult? result) =>
    result != null &&
    result.outcome == RideExportOutcome.done &&
    result.destination == RideExportDestination.folder &&
    result.sourceDiffers == 0;

/// The closing summary of an export, shown for 8 s: a check mark when
/// the export is clean ([success], see [rideExportSummaryIsClean]),
/// otherwise an amber mark, then the summary [text] (every outcome:
/// done, paused, cancelled, failed, share, clips that differ). "Open
/// folder" waits behind [kOpenExportFolder] and is not in the tree.
SnackBar rideExportSummarySnackBar({
  required String text,
  required bool success,
}) {
  return SnackBar(
    duration: const Duration(seconds: 8),
    content: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          success ? Icons.check_circle : Icons.info_outline,
          size: 28,
          color: success ? MotoColors.text : MotoColors.amber,
          semanticLabel: success ? 'Done' : 'Note',
        ),
        const SizedBox(width: MotoSize.gapWide),
        Expanded(child: Text(text)),
      ],
    ),
    action: kOpenExportFolder && success
        ? SnackBarAction(label: 'Open folder', onPressed: () {})
        : null,
  );
}

/// The title of the dialog's collapsible list of notes.
const String rideExportNotesTitle = 'Before you hand this over';

/// The export dialog: which clips ([evidence] or [all], the plans of both
/// choices, or a section: an exact range of whole seconds picked on a
/// slider, offered when the ride has a timeline), whether to include the
/// ride data (never for a section), and what the rider should know before
/// handing the files over. Pops a [RideExportChoice], or `null` on Cancel.
class RideExportDialog extends StatefulWidget {
  /// Creates the dialog.
  const RideExportDialog({
    super.key,
    required this.destination,
    required this.evidence,
    required this.all,
    required this.hasRideData,
    this.playheadMs,
  });

  /// Folder or share; sets the title, the button and the notes.
  final RideExportDestination destination;

  /// The plan of the locked and incident clips.
  final RideExportPlan evidence;

  /// The plan of all clips (its sizes give the section's estimate).
  final RideExportPlan all;

  /// Whether the ride has a ride file to include.
  final bool hasRideData;

  /// The playhead (Playback), in ms from the ride start: the section
  /// starts 30 s before it and ends 30 s after it, within the ride.
  /// Without it the section is the first minute.
  final int? playheadMs;

  @override
  State<RideExportDialog> createState() => _RideExportDialogState();
}

class _RideExportDialogState extends State<RideExportDialog> {
  late RideExportClips _clips = widget.evidence.clips.isEmpty
      ? RideExportClips.all
      : RideExportClips.evidence;
  late bool _includeRideData = widget.hasRideData;

  /// Whether the "Before you hand this over" notes are open (they are
  /// when the dialog opens).
  bool _notesExpanded = true;

  /// The ride (as the plans read it).
  late final RideRecord _ride = widget.all.source.ride;

  /// The ride's length for a section, or `null` without a timeline.
  late final int? _lengthMs = rideExportLengthMs(_ride);

  /// The slider's end, in whole seconds.
  late final int _maxSeconds = ((_lengthMs ?? 0) / 1000).ceil();

  /// Whether the ride offers a section (it has a timeline of 1 s or more).
  bool get _offersSection => _lengthMs != null && _maxSeconds >= 1;

  /// The section's ends, in whole seconds of ride time.
  late int _fromSeconds;
  late int _toSeconds;

  @override
  void initState() {
    super.initState();
    final playhead = widget.playheadMs;
    if (playhead == null) {
      _fromSeconds = 0;
      _toSeconds = _maxSeconds < 60 ? _maxSeconds : 60;
    } else {
      final at = (playhead ~/ 1000).clamp(0, _maxSeconds);
      _fromSeconds = at - 30 < 0 ? 0 : at - 30;
      _toSeconds = at + 30 > _maxSeconds ? _maxSeconds : at + 30;
      if (_toSeconds - _fromSeconds < 1) {
        _fromSeconds = _toSeconds - 1;
      }
    }
  }

  RideExportSection get _section =>
      RideExportSection(_fromSeconds * 1000, _toSeconds * 1000);

  String _label(String text, RideExportPlan plan) =>
      '$text (${plan.clips.length}, ${formatFileSize(plan.clipBytes)})';

  /// Moves the section's ends to [from] and [to] (whole seconds), keeping
  /// them in the ride and at least 1 s apart.
  void _setRange(int from, int to) {
    if (from < 0 || to > _maxSeconds || to - from < 1) {
      return;
    }
    setState(() {
      _fromSeconds = from;
      _toSeconds = to;
    });
  }

  /// The section's files that exist (clip sizes from the all-clips plan)
  /// and their estimated bytes.
  ({int files, int bytes}) _sectionSize() {
    final sizes = <String, int>{
      for (final item in widget.all.clips) item.sourcePath: item.bytes,
    };
    var files = 0;
    var bytes = 0;
    for (final part in rideExportSectionParts(_ride, _section)) {
      final size = sizes[part.path];
      if (size != null) {
        files++;
        bytes += rideExportPartBytes(part, size);
      }
    }
    return (files: files, bytes: bytes);
  }

  /// For example '05:12 to 06:40 (1 min 28 s), 2 files, about 310 MB'.
  String _sectionLabel(({int files, int bytes}) size) {
    final files = size.files == 1 ? '1 file' : '${size.files} files';
    return '${_rideTime(_fromSeconds)} to ${_rideTime(_toSeconds)} '
        '(${_lengthText(_toSeconds - _fromSeconds)}), $files, about '
        '${formatFileSize(size.bytes)}';
  }

  /// A row of the -1 s and +1 s buttons of one end of the section.
  Widget _nudges(String label, Key key, void Function(int delta) nudge) => Row(
    key: key,
    children: [
      Expanded(
        child: Text(
          label,
          style: MotoFonts.bodyStyle(16, weight: FontWeight.w600),
        ),
      ),
      TextButton(onPressed: () => nudge(-1), child: const Text('-1 s')),
      TextButton(onPressed: () => nudge(1), child: const Text('+1 s')),
    ],
  );

  Widget _buildSection(({int files, int bytes}) size) {
    final length = _maxSeconds * 1000;
    double at(int ms) => (ms / length).clamp(0.0, 1.0);
    final clips = rideExportSectionParts(_ride, RideExportSection(0, length));
    final locked = <String>{
      for (final path in _ride.lockedSegmentPaths)
        path_utils.normalizePath(path),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: MotoColors.text,
            inactiveTrackColor: MotoColors.hairlineStrong,
            thumbColor: MotoColors.text,
            overlayColor: MotoColors.text.withValues(alpha: 0.12),
          ),
          child: RangeSlider(
            values: RangeValues(_fromSeconds.toDouble(), _toSeconds.toDouble()),
            max: _maxSeconds.toDouble(),
            onChanged: (values) {
              final from = values.start.round();
              final to = values.end.round();
              if (to - from >= 1) {
                _setRange(from, to);
              }
            },
          ),
        ),
        _SectionMarks(
          ticks: <double>[
            for (final clip in clips)
              if (clip.rideStartMs > 0) at(clip.rideStartMs),
          ],
          locks: <({double x, String label})>[
            for (final clip in clips)
              if (locked.contains(path_utils.normalizePath(clip.path)))
                (
                  x: at(clip.rideStartMs + clip.clipLengthMs ~/ 2),
                  label:
                      'Locked clip at ${_rideTime(clip.rideStartMs ~/ 1000)}',
                ),
          ],
          incidents: <({double x, String label})>[
            for (final incident in _ride.incidents ?? const <RideIncident>[])
              if (incident.elapsedMs >= 0 && incident.elapsedMs <= length)
                (
                  x: at(incident.elapsedMs),
                  label: 'Incident at ${_rideTime(incident.elapsedMs ~/ 1000)}',
                ),
          ],
        ),
        _nudges(
          'Start',
          const ValueKey<String>('rideExportSectionStart'),
          (delta) => _setRange(_fromSeconds + delta, _toSeconds),
        ),
        _nudges(
          'End',
          const ValueKey<String>('rideExportSectionEnd'),
          (delta) => _setRange(_fromSeconds, _toSeconds + delta),
        ),
        Text(
          _sectionLabel(size),
          style: MotoFonts.condensedStyle(
            18,
            weight: FontWeight.w600,
            color: MotoColors.text,
            tabularFigures: true,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final share = widget.destination == RideExportDestination.share;
    final isSection = _clips == RideExportClips.section;
    final size = isSection ? _sectionSize() : null;
    final includeRideData = _includeRideData && !isSection;
    final hasSomething = switch (_clips) {
      RideExportClips.evidence =>
        widget.evidence.clips.isNotEmpty || includeRideData,
      RideExportClips.all => widget.all.clips.isNotEmpty || includeRideData,
      RideExportClips.section => size!.files > 0,
    };
    final notes = <({String text, IconData icon})>[
      (
        text:
            'Videos show other road users: share them only for your own '
            'records, the police or your insurer.',
        icon: Icons.groups_outlined,
      ),
      if (share)
        (
          text:
              'MotoCam cannot check a share. In messengers send as a '
              'document, not as video, or the video is re-encoded.',
          icon: Icons.send_outlined,
        )
      else
        (
          text:
              'The folder you pick is shared storage: other apps with media '
              'or storage access, and gallery backups, may see these files.',
          icon: Icons.folder_shared_outlined,
        ),
      if (includeRideData)
        (
          text:
              'All exports from this phone carry the same public key, so '
              'they can be linked to each other.',
          icon: Icons.key_outlined,
        ),
      (
        text: 'Keep MotoCam open until the export finishes.',
        icon: Icons.phone_android,
      ),
    ];
    final dim = MotoFonts.bodyStyle(14, height: 1.4, color: MotoColors.dim);
    RoundedRectangleBorder optionShape(bool selected) => RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(MotoRadii.sm),
      side: BorderSide(
        color: selected ? MotoColors.text : MotoColors.hairlineStrong,
        width: selected ? 2 : 1.5,
      ),
    );
    Widget option(RideExportClips value, String title, {bool enabled = true}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: RadioListTile<RideExportClips>(
            value: value,
            enabled: enabled,
            shape: optionShape(_clips == value),
            tileColor: _clips == value ? MotoColors.bg : null,
            contentPadding: const EdgeInsets.only(right: 12),
            title: Text(title),
          ),
        );
    return AlertDialog(
      scrollable: true,
      title: Text(share ? 'Share ride' : 'Export ride'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'CLIPS',
              style: MotoFonts.bodyStyle(
                13,
                letterSpacingEm: 0.08,
                color: MotoColors.dim,
              ),
            ),
          ),
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
                option(
                  RideExportClips.evidence,
                  _label('Locked and incident clips', widget.evidence),
                  enabled: widget.evidence.clips.isNotEmpty,
                ),
                option(RideExportClips.all, _label('All clips', widget.all)),
                if (_offersSection)
                  option(RideExportClips.section, 'A section of the ride'),
              ],
            ),
          ),
          if (isSection) ...[
            _buildSection(size!),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'A section is video only: it carries no ride data and no '
                'signature.',
                style: dim,
              ),
            ),
          ] else
            CheckboxListTile(
              value: _includeRideData,
              onChanged: widget.hasRideData
                  ? (value) => setState(() => _includeRideData = value ?? false)
                  : null,
              shape: optionShape(false),
              contentPadding: const EdgeInsets.only(left: 4, right: 12),
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Include ride data'),
              subtitle: const Text(
                'Route, speed every second and private file paths. Needed to '
                'check the signature. Leave it out to hand over video only.',
              ),
            ),
          const SizedBox(height: 8),
          _ExportNotes(
            expanded: _notesExpanded,
            onToggle: () => setState(() => _notesExpanded = !_notesExpanded),
            notes: notes,
          ),
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: MotoColors.text,
            minimumSize: const Size(0, MotoSize.minTarget),
            padding: const EdgeInsets.symmetric(horizontal: 20),
          ),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          style: TextButton.styleFrom(
            backgroundColor: MotoColors.text,
            foregroundColor: MotoColors.bg,
            disabledBackgroundColor: MotoColors.surfaceTop,
            disabledForegroundColor: MotoColors.muted,
            minimumSize: const Size(0, MotoSize.minTarget),
            padding: const EdgeInsets.symmetric(horizontal: 26),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(MotoRadii.sm),
            ),
          ),
          onPressed: hasSomething
              ? () => Navigator.of(context).pop(
                  RideExportChoice(
                    clips: _clips,
                    includeRideData: includeRideData,
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

/// The dialog's notes under a "Before you hand this over" header that
/// folds them away; open when the dialog opens, so no warning is hidden
/// unless the rider folds it.
class _ExportNotes extends StatelessWidget {
  const _ExportNotes({
    required this.expanded,
    required this.onToggle,
    required this.notes,
  });

  final bool expanded;
  final VoidCallback onToggle;
  final List<({String text, IconData icon})> notes;

  @override
  Widget build(BuildContext context) {
    // No LayoutBuilder or ExpansionTile: the dialog measures its content's
    // intrinsic width.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: expanded,
          child: InkWell(
            key: const ValueKey<String>('rideExportNotesHeader'),
            borderRadius: BorderRadius.circular(MotoRadii.sm),
            onTap: onToggle,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: MotoSize.minTarget),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      rideExportNotesTitle,
                      style: MotoFonts.bodyStyle(
                        16,
                        weight: FontWeight.w600,
                        color: MotoColors.text,
                      ),
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: MotoColors.dim,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (expanded)
          for (final note in notes)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(note.icon, size: 18, color: MotoColors.dim),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      note.text,
                      style: MotoFonts.bodyStyle(
                        14,
                        height: 1.4,
                        color: MotoColors.dim,
                      ),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

String _two(int value) => value.toString().padLeft(2, '0');

/// [seconds] of ride time as `MM:SS` (minutes not wrapped at 60).
String _rideTime(int seconds) => '${_two(seconds ~/ 60)}:${_two(seconds % 60)}';

/// [seconds] as '45 s', '1 min 28 s', '2 min' or '1 h 5 min 12 s'.
String _lengthText(int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final rest = seconds % 60;
  return <String>[
    if (hours > 0) '$hours h',
    if (minutes > 0) '$minutes min',
    if (rest > 0 || seconds == 0) '$rest s',
  ].join(' ');
}

/// Clip-boundary ticks and lock and incident marks under the section
/// slider; each `x` is a fraction of the slider's range (0 to 1).
class _SectionMarks extends StatelessWidget {
  const _SectionMarks({
    required this.ticks,
    required this.locks,
    required this.incidents,
  });

  final List<double> ticks;
  final List<({double x, String label})> locks;
  final List<({double x, String label})> incidents;

  /// The slider's track inset on each side (its thumb overlay radius).
  static const double _inset = 24;
  static const double _size = 12;

  /// The horizontal alignment of [x]: -1 start, 1 end.
  static double _align(double x) => 2 * x - 1;

  @override
  Widget build(BuildContext context) {
    // No LayoutBuilder: the dialog measures its content's intrinsic width.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _inset - _size / 2),
      child: SizedBox(
        height: 2 * _size + 8,
        child: Stack(
          children: [
            for (final x in ticks)
              Align(
                alignment: Alignment(_align(x), -1),
                child: SizedBox(
                  width: _size,
                  height: 6,
                  child: Center(
                    child: Container(width: 1, color: MotoColors.dim),
                  ),
                ),
              ),
            for (final lock in locks)
              Align(
                alignment: Alignment(_align(lock.x), 0),
                child: Icon(
                  Icons.lock,
                  size: _size,
                  color: MotoColors.lock,
                  semanticLabel: lock.label,
                ),
              ),
            for (final incident in incidents)
              Align(
                alignment: Alignment(_align(incident.x), 1),
                child: Icon(
                  Icons.warning_rounded,
                  size: _size,
                  color: MotoColors.amber,
                  semanticLabel: incident.label,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
