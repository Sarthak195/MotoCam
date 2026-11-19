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
      Expanded(child: Text(label)),
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
        RangeSlider(
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
        Text(_sectionLabel(size)),
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
    final notes = <String>[
      'Videos show other road users: share them only for your own records, '
          'the police or your insurer.',
      if (share)
        'MotoCam cannot check a share. In messengers send as a document, not '
            'as video, or the video is re-encoded.'
      else
        'The folder you pick is shared storage: other apps with media or '
            'storage access, and gallery backups, may see these files.',
      if (includeRideData)
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
                if (_offersSection)
                  RadioListTile<RideExportClips>(
                    value: RideExportClips.section,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('A section of the ride'),
                  ),
              ],
            ),
          ),
          if (isSection) ...[
            _buildSection(size!),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'A section is video only: it carries no ride data and no '
                'signature.',
              ),
            ),
          ] else
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
    final colors = Theme.of(context).colorScheme;
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
                    child: Container(width: 1, color: colors.onSurfaceVariant),
                  ),
                ),
              ),
            for (final lock in locks)
              Align(
                alignment: Alignment(_align(lock.x), 0),
                child: Icon(
                  Icons.lock,
                  size: _size,
                  color: colors.primary,
                  semanticLabel: lock.label,
                ),
              ),
            for (final incident in incidents)
              Align(
                alignment: Alignment(_align(incident.x), 1),
                child: Icon(
                  Icons.warning_amber,
                  size: _size,
                  color: colors.error,
                  semanticLabel: incident.label,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
