// lib/features/history/services/ride_export.dart
//
// Ride export (Android): copies a ride's clips, its ride JSON (byte for
// byte), manifest.json and MOTOCAM-EXPORT.txt into one folder of a picked
// Storage Access Framework tree, or hands them to the share sheet. The
// ride file is read once, in a background isolate, before planning
// ([loadRideExportSource]); [planRideExport] picks the clips;
// [RideExporter] runs the copy over a [RideExportNative] and returns a
// [RideExportResult] that [rideExportSummary] turns into the rider's
// message. The text files are built in ride_export_text.dart. Platform
// code stays behind [RideExportNative]; CameraProvider decides when an
// export may run.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/ride_file/ride_telemetry_codec.dart' as ride_codec;
import '../../../core/services/ride_export_channel.dart';
import '../../../core/utils/format_utils.dart';
import '../../../core/utils/integrity_utils.dart' as integrity_utils;
import '../../../core/utils/path_utils.dart' as path_utils;
import '../models/ride_index.dart';
import '../models/ride_record.dart';
import 'ride_export_text.dart';

export '../../../core/services/ride_export_channel.dart'
    show RideExportCancelled, RideExportFailure, RideExportNative;
export 'ride_export_text.dart';

/// Name of the manifest written into every export.
const String rideExportManifestName = 'manifest.json';

/// Name of the text file written last into every export; a folder without
/// it is incomplete.
const String rideExportReadmeName = 'MOTOCAM-EXPORT.txt';

/// Name of the directory under the cache directory that holds the staged
/// manifest and README (the FileProvider shares from it).
const String rideExportStagingDirectoryName = 'ride_export';

/// How long a share's staged files are kept for the receiving app.
const Duration rideExportStagingMaxAge = Duration(hours: 24);

/// Which clips an export holds.
enum RideExportClips {
  /// Locked clips plus the clips that hold an incident (and its lead-up).
  evidence,

  /// Every clip of the ride.
  all,

  /// A range of whole clips ([RideExportSection]).
  section,
}

/// A section of a ride: the clips [firstClip] to [lastClip] (inclusive,
/// 1-based clip numbers over the ride's `segmentPaths`, missing files
/// included).
@immutable
class RideExportSection {
  /// Creates a section.
  const RideExportSection(this.firstClip, this.lastClip);

  /// The first clip number.
  final int firstClip;

  /// The last clip number.
  final int lastClip;

  @override
  bool operator ==(Object other) =>
      other is RideExportSection &&
      other.firstClip == firstClip &&
      other.lastClip == lastClip;

  @override
  int get hashCode => Object.hash(firstClip, lastClip);

  @override
  String toString() => 'RideExportSection($firstClip, $lastClip)';
}

/// Where an export goes.
enum RideExportDestination {
  /// A folder of a picked tree.
  folder,

  /// The Android share sheet.
  share,
}

/// How a clip's source compares with the hash recorded when the ride was
/// saved.
enum RideExportRecorded {
  /// Equal.
  match,

  /// Different.
  differs,

  /// No hash was recorded for this clip, or the recorded value is not a
  /// SHA-256 (see [RideExportFileEntry.recordedInvalid]).
  none,
}

/// Whether [value] is a SHA-256 as MotoCam records it: exactly 64
/// lowercase hex characters.
bool isRecordedSha256(String value) => _recordedSha256.hasMatch(value);

final RegExp _recordedSha256 = RegExp(r'^[0-9a-f]{64}$');

/// Why a clip of the ride is not in the export.
enum RideExportOmissionReason {
  /// Not in the rider's choice: neither locked nor an incident clip, or
  /// outside the section.
  notSelected,

  /// The clip's file is no longer on the phone.
  missing,
}

/// How an export run ended.
enum RideExportOutcome {
  /// Every file was exported (or the share sheet opened).
  done,

  /// Stopped because a recording started; run again to continue.
  paused,

  /// Stopped by the rider.
  cancelled,

  /// A file failed; see [RideExportResult.failureCode].
  failed,
}

/// The MIME type of an exported file name: `video/mp4`, `application/json`,
/// `text/plain`, else `application/octet-stream`.
String rideExportMimeTypeFor(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.mp4')) {
    return 'video/mp4';
  }
  if (lower.endsWith('.json')) {
    return 'application/json';
  }
  if (lower.endsWith('.txt')) {
    return 'text/plain';
  }
  return 'application/octet-stream';
}

/// The ride as an export sees it: the record built from the ride file read
/// once at the start, the hash of those bytes and the envelope facts the
/// text files need.
@immutable
class RideExportSource {
  /// Creates a source. Prefer [loadRideExportSource].
  const RideExportSource({
    required this.ride,
    this.rideDataSha256,
    this.rideDataBytes,
    this.envelopeVersion,
    this.signatureAlg,
    this.signatureKeyId,
  });

  /// The ride (sample-less), with the screen's signer context applied.
  final RideRecord ride;

  /// SHA-256 of the ride file's bytes when it was read (H0), or `null`
  /// for a ride without a ride file.
  final String? rideDataSha256;

  /// Size of the ride file when it was read, or `null` without one.
  final int? rideDataBytes;

  /// `envelopeVersion` of the file's integrity envelope (1 when absent
  /// from the envelope), or `null` when the file has no envelope.
  final int? envelopeVersion;

  /// `integrity.signature.alg`, only when the signature facts are valid.
  final String? signatureAlg;

  /// `integrity.signature.keyId`, only when the signature facts are valid.
  final String? signatureKeyId;

  /// Whether the ride has a ride file (a video-only recovery has none).
  bool get hasRideData => ride.telemetryPath != null && rideDataSha256 != null;
}

/// Reads the ride file of [ride] in a background isolate and returns the
/// export source: the bytes are hashed (H0), the record is built from the
/// file with `loadSamples: false` and [ride]'s signer context, and the
/// file is hashed again, which must give H0. A ride without a ride file
/// gives a source with no ride data.
///
/// Throws [RideExportFailure] `SOURCE_UNREADABLE` when the file cannot be
/// read or decoded, and `SOURCE_CHANGED` when it changed while it was
/// read; both carry the rider's sentence as the message.
Future<RideExportSource> loadRideExportSource(RideRecord ride) async {
  final path = ride.telemetryPath;
  if (path == null) {
    return RideExportSource(ride: ride);
  }
  return _loadRideExportSourceInBackground(path, ride.integrity.signerContext);
}

/// Top level so the isolate closure captures only [path] and [context].
Future<RideExportSource> _loadRideExportSourceInBackground(
  String path,
  RideSignerContext? context,
) => Isolate.run(() => _readRideExportSource(path, context));

Future<RideExportSource> _readRideExportSource(
  String path,
  RideSignerContext? context,
) async {
  const unreadable = RideExportFailure(
    'SOURCE_UNREADABLE',
    'The ride file could not be read.',
  );
  final file = File(path);
  final List<int> bytes;
  try {
    bytes = await file.readAsBytes();
  } on FileSystemException {
    throw unreadable;
  }
  final h0 = sha256.convert(bytes).toString();
  final record = await RideRecord.fromTelemetryFile(file, loadSamples: false);
  if (record == null) {
    throw unreadable;
  }
  if (await integrity_utils.hashFileSha256(path) != h0) {
    throw const RideExportFailure(
      'SOURCE_CHANGED',
      'The ride file changed; try again.',
    );
  }
  final ride = record.withSignerContext(context);

  Object? json;
  try {
    json = jsonDecode(utf8.decode(bytes));
  } catch (_) {
    json = null;
  }
  final envelope = json is Map ? json['integrity'] : null;
  int? envelopeVersion;
  String? alg;
  String? keyId;
  if (envelope is Map) {
    envelopeVersion = ride_codec.integrityEnvelopeVersionOf(envelope);
    final signature = envelope['signature'];
    if (ride.integrity.signature?.valid == true && signature is Map) {
      final rawAlg = signature['alg'];
      final rawKeyId = signature['keyId'];
      alg = rawAlg is String ? rawAlg : null;
      keyId = rawKeyId is String ? rawKeyId : null;
    }
  }
  return RideExportSource(
    ride: ride,
    rideDataSha256: h0,
    rideDataBytes: bytes.length,
    envelopeVersion: envelopeVersion,
    signatureAlg: alg,
    signatureKeyId: keyId,
  );
}

/// The folder name of an export: `MotoCam ride <id> (<scope>)`, where
/// `<id>` is the ride's `rideSessionId` (a legacy ride's video base name)
/// with every character outside `[A-Za-z0-9_-]` replaced by `_`, and
/// `<scope>` one of `locked clips`, `all clips` and, for a [section] (which
/// a section choice requires), `clips <first> to <last>`, each followed by
/// `, video only` when the ride data is left out. A re-run of the same
/// choice gives the same name.
String rideExportFolderName(
  RideRecord ride, {
  required RideExportClips clips,
  required bool includeRideData,
  RideExportSection? section,
}) {
  final sessionId = ride.rideSessionId?.trim() ?? '';
  final String raw;
  if (sessionId.isNotEmpty) {
    raw = sessionId;
  } else {
    final name = ride.fileName;
    final dot = name.lastIndexOf('.');
    raw = dot > 0 ? name.substring(0, dot) : name;
  }
  // The same rule as rideTelemetryFileNameFor.
  final id = raw.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  final scope = switch (clips) {
    RideExportClips.evidence => 'locked clips',
    RideExportClips.all => 'all clips',
    RideExportClips.section =>
      'clips ${_sectionOf(clips, section).firstClip} to ${section!.lastClip}',
  };
  final suffix = includeRideData ? '' : ', video only';
  return 'MotoCam ride $id ($scope$suffix)';
}

/// The locked and incident clips of a ride.
@immutable
class RideEvidenceSelection {
  /// Creates a selection.
  const RideEvidenceSelection({
    required this.paths,
    required this.unmappedIncidentsMs,
  });

  /// Selected entries of `segmentPaths`, in recording order.
  final List<String> paths;

  /// `elapsedMs` of each incident that lies in no kept clip.
  final List<int> unmappedIncidentsMs;
}

/// How long after a clip's end an incident still belongs to it.
const int _incidentAfterEndMs = 1000;

/// An incident this soon after its clip's start also takes the previous
/// clip (the lead-up).
const int _incidentLeadUpMs = 10000;

/// Where an incident at [ms] lies: [clip] is the normalised path of its
/// clip and [leadUp] that of the clip before it when the incident is early
/// in its clip; [clip] is `null` when the incident lies in no clip.
typedef _MappedIncident = ({int ms, String? clip, String? leadUp});

/// Maps each incident of [ride] at `t` to the timeline entry E (sorted by
/// start) with `E.startMs <= t`, `t` before the next entry's start (or E
/// last) and `t <= E.endMs + 1000`, and to the entry before E when
/// `t - E.startMs < 10000` (the lead-up). Only trusted segments
/// (`segmentPaths`) are mapped. Empty without a timeline or incidents.
List<_MappedIncident> _mapIncidents(RideRecord ride) {
  final incidents = ride.incidents;
  final timeline = <RideSegmentTimelineEntry>[...ride.segmentTimeline]
    ..sort((a, b) => a.startMs.compareTo(b.startMs));
  if (incidents == null || timeline.isEmpty) {
    return const <_MappedIncident>[];
  }
  final trusted = <String>{
    for (final path in ride.segmentPaths) path_utils.normalizePath(path),
  };
  final mapped = <_MappedIncident>[];
  for (final incident in incidents) {
    final t = incident.elapsedMs;
    var index = -1;
    for (var i = 0; i < timeline.length; i++) {
      if (timeline[i].startMs <= t) {
        index = i;
      } else {
        break;
      }
    }
    final entry = index < 0 ? null : timeline[index];
    final key = entry == null ? null : path_utils.normalizePath(entry.path);
    if (entry == null ||
        t > entry.endMs + _incidentAfterEndMs ||
        !trusted.contains(key)) {
      mapped.add((ms: t, clip: null, leadUp: null));
      continue;
    }
    String? leadUp;
    if (index > 0 && t - entry.startMs < _incidentLeadUpMs) {
      final previous = path_utils.normalizePath(timeline[index - 1].path);
      if (trusted.contains(previous)) {
        leadUp = previous;
      }
    }
    mapped.add((ms: t, clip: key, leadUp: leadUp));
  }
  return mapped;
}

/// The locked clips of [ride] plus, for each incident, its clip and its
/// lead-up clip ([_mapIncidents]). An incident that fits no entry is
/// listed in [RideEvidenceSelection.unmappedIncidentsMs]. Without a
/// timeline (or incidents) only the locked clips are selected. Only trusted
/// segments (`segmentPaths`) are ever selected.
RideEvidenceSelection selectEvidenceClips(RideRecord ride) {
  final trusted = <String>{
    for (final path in ride.segmentPaths) path_utils.normalizePath(path),
  };
  final selected = <String>{};
  for (final path in ride.lockedSegmentPaths) {
    final key = path_utils.normalizePath(path);
    if (trusted.contains(key)) {
      selected.add(key);
    }
  }

  final unmapped = <int>[];
  for (final incident in _mapIncidents(ride)) {
    final clip = incident.clip;
    if (clip == null) {
      unmapped.add(incident.ms);
      continue;
    }
    selected.add(clip);
    final leadUp = incident.leadUp;
    if (leadUp != null) {
      selected.add(leadUp);
    }
  }

  return RideEvidenceSelection(
    paths: <String>[
      for (final path in ride.segmentPaths)
        if (selected.contains(path_utils.normalizePath(path))) path,
    ],
    unmappedIncidentsMs: List<int>.unmodifiable(unmapped),
  );
}

/// The clip number (1-based, over `segmentPaths`) of the clip that holds
/// each incident of [ride] that lies in a clip, in incident order. Empty
/// without a timeline.
List<int> rideIncidentClipNumbers(RideRecord ride) {
  final numbers = <String, int>{
    for (var i = 0; i < ride.segmentPaths.length; i++)
      path_utils.normalizePath(ride.segmentPaths[i]): i + 1,
  };
  return <int>[
    for (final incident in _mapIncidents(ride)) ?numbers[incident.clip],
  ];
}

/// The clip number (1-based) of [path] in [ride]'s `segmentPaths`, or
/// `null` when it is not one of them.
int? rideClipNumberOf(RideRecord ride, String path) {
  final key = path_utils.normalizePath(path);
  for (var i = 0; i < ride.segmentPaths.length; i++) {
    if (path_utils.normalizePath(ride.segmentPaths[i]) == key) {
      return i + 1;
    }
  }
  return null;
}

/// The ride time [section] of [ride] covers, in ms from the ride start:
/// from the start of its first clip to the end of its last clip in the
/// ride's `segmentTimeline`; `null` when either clip has no timeline entry.
({int fromMs, int toMs})? rideExportSectionSpan(
  RideRecord ride,
  RideExportSection section,
) {
  RideSegmentTimelineEntry? entryOf(int clip) {
    if (clip < 1 || clip > ride.segmentPaths.length) {
      return null;
    }
    final key = path_utils.normalizePath(ride.segmentPaths[clip - 1]);
    for (final entry in ride.segmentTimeline) {
      if (path_utils.normalizePath(entry.path) == key) {
        return entry;
      }
    }
    return null;
  }

  final first = entryOf(section.firstClip);
  final last = entryOf(section.lastClip);
  if (first == null || last == null) {
    return null;
  }
  return (fromMs: first.startMs, toMs: last.endMs);
}

/// The local clock time [ms] after [ride]'s start, as `HH:mm`.
String rideExportClockText(RideRecord ride, int ms) {
  final time = ride.createdAt.add(Duration(milliseconds: ms));
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}';
}

/// The [section] a section choice requires.
RideExportSection _sectionOf(
  RideExportClips clips,
  RideExportSection? section,
) {
  if (section == null) {
    throw ArgumentError.value(clips, 'clips', 'a section needs its clips');
  }
  return section;
}

/// One file to export.
@immutable
class RideExportItem {
  /// Creates an item.
  const RideExportItem({
    required this.sourcePath,
    required this.name,
    required this.bytes,
    this.recordedSha256,
    this.recordedInvalid = false,
    this.locked = false,
  });

  /// The private file.
  final String sourcePath;

  /// The name in the export (the file name of [sourcePath]).
  final String name;

  /// Size when planned.
  final int bytes;

  /// The hash recorded when the ride was saved (clips only), or `null`
  /// (also when the recorded value is not a SHA-256).
  final String? recordedSha256;

  /// Whether a value was recorded that is not a SHA-256.
  final bool recordedInvalid;

  /// Whether the clip is locked.
  final bool locked;
}

/// A clip of the ride that is not in the export.
@immutable
class RideExportOmission {
  /// Creates an omission.
  const RideExportOmission({
    required this.name,
    required this.reason,
    this.recordedSha256,
    this.recordedInvalid = false,
  });

  /// The clip's file name.
  final String name;

  /// Why it is not exported.
  final RideExportOmissionReason reason;

  /// The hash recorded when the ride was saved, or `null` (also when the
  /// recorded value is not a SHA-256).
  final String? recordedSha256;

  /// Whether a value was recorded that is not a SHA-256.
  final bool recordedInvalid;
}

/// What an export copies, in order: [clips], then [rideData], then the
/// manifest and the README.
@immutable
class RideExportPlan {
  /// Creates a plan. Prefer [planRideExport].
  const RideExportPlan({
    required this.source,
    required this.clipChoice,
    required this.includeRideData,
    required this.folderName,
    required this.clips,
    required this.rideData,
    required this.notExported,
    required this.unmappedIncidentsMs,
    this.section,
  });

  /// The ride as read at the start.
  final RideExportSource source;

  /// The rider's clip choice.
  final RideExportClips clipChoice;

  /// The clips of a [RideExportClips.section] choice, else `null`.
  final RideExportSection? section;

  /// Whether the ride file is exported ([rideData] is set).
  final bool includeRideData;

  /// The export folder name ([rideExportFolderName]).
  final String folderName;

  /// The clips to export, in recording order (existing files only).
  final List<RideExportItem> clips;

  /// The ride file, or `null` when not included.
  final RideExportItem? rideData;

  /// Clips of the ride that are not exported, in recording order.
  final List<RideExportOmission> notExported;

  /// `elapsedMs` of incidents in no kept clip.
  final List<int> unmappedIncidentsMs;

  /// Bytes of [clips].
  int get clipBytes => clips.fold(0, (sum, item) => sum + item.bytes);

  /// Bytes of [clips] and [rideData] (the text files are small).
  int get totalBytes => clipBytes + (rideData?.bytes ?? 0);

  /// Every name the export folder may hold.
  List<String> get expectedNames => <String>[
    for (final item in clips) item.name,
    if (rideData != null) rideData!.name,
    rideExportManifestName,
    rideExportReadmeName,
  ];
}

/// Plans the export of [source] with the rider's [clips] choice. Clips are
/// the ride's trusted segments; a clip whose file is gone ([stat] gives
/// `null`) is listed as missing and never copied. The ride file is
/// included only when [includeRideData] and the ride has one. A recorded
/// hash that is not a SHA-256 ([isRecordedSha256]) is kept as absent and
/// flagged `recordedInvalid`.
///
/// A [RideExportClips.section] choice requires [section], a clip range
/// within the ride (else [ArgumentError]); clips outside it are not
/// selected, and an incident whose clip is outside it is listed as in no
/// kept clip. [section] is ignored for the other choices.
Future<RideExportPlan> planRideExport(
  RideExportSource source, {
  required RideExportClips clips,
  required bool includeRideData,
  RideExportSection? section,
  RideFileStatSource stat = statRideFile,
}) async {
  final ride = source.ride;
  final withData = includeRideData && source.hasRideData;
  final selection = selectEvidenceClips(ride);
  final range = clips == RideExportClips.section
      ? _sectionOf(clips, section)
      : null;
  if (range != null &&
      (range.firstClip < 1 ||
          range.firstClip > range.lastClip ||
          range.lastClip > ride.segmentPaths.length)) {
    throw ArgumentError.value(range, 'section', 'not a clip range');
  }
  final evidence = selection.paths.toSet();
  bool isChosen(int number, String path) => switch (clips) {
    RideExportClips.all => true,
    RideExportClips.evidence => evidence.contains(path),
    RideExportClips.section =>
      number >= range!.firstClip && number <= range.lastClip,
  };
  var unmappedIncidentsMs = selection.unmappedIncidentsMs;
  if (range != null) {
    final kept = <String>{
      for (var i = range.firstClip - 1; i < range.lastClip; i++)
        path_utils.normalizePath(ride.segmentPaths[i]),
    };
    unmappedIncidentsMs = List<int>.unmodifiable(<int>[
      for (final incident in _mapIncidents(ride))
        if (!kept.contains(incident.clip)) incident.ms,
    ]);
  }
  final locked = <String>{
    for (final path in ride.lockedSegmentPaths) path_utils.normalizePath(path),
  };

  final items = <RideExportItem>[];
  final omissions = <RideExportOmission>[];
  for (var index = 0; index < ride.segmentPaths.length; index++) {
    final path = ride.segmentPaths[index];
    final name = path_utils.fileNameFromPath(path);
    final raw = ride.expectedSegmentHashes[path];
    final recorded = raw != null && isRecordedSha256(raw) ? raw : null;
    final recordedInvalid = raw != null && recorded == null;
    if (!isChosen(index + 1, path)) {
      omissions.add(
        RideExportOmission(
          name: name,
          reason: RideExportOmissionReason.notSelected,
          recordedSha256: recorded,
          recordedInvalid: recordedInvalid,
        ),
      );
      continue;
    }
    final stamp = await stat(path);
    if (stamp == null) {
      omissions.add(
        RideExportOmission(
          name: name,
          reason: RideExportOmissionReason.missing,
          recordedSha256: recorded,
          recordedInvalid: recordedInvalid,
        ),
      );
      continue;
    }
    items.add(
      RideExportItem(
        sourcePath: path,
        name: name,
        bytes: stamp.size,
        recordedSha256: recorded,
        recordedInvalid: recordedInvalid,
        locked: locked.contains(path_utils.normalizePath(path)),
      ),
    );
  }

  final telemetryPath = ride.telemetryPath;
  return RideExportPlan(
    source: source,
    clipChoice: clips,
    section: range,
    includeRideData: withData,
    folderName: rideExportFolderName(
      ride,
      clips: clips,
      includeRideData: withData,
      section: range,
    ),
    clips: List<RideExportItem>.unmodifiable(items),
    rideData: withData && telemetryPath != null
        ? RideExportItem(
            sourcePath: telemetryPath,
            name: path_utils.fileNameFromPath(telemetryPath),
            bytes: source.rideDataBytes ?? 0,
          )
        : null,
    notExported: List<RideExportOmission>.unmodifiable(omissions),
    unmappedIncidentsMs: unmappedIncidentsMs,
  );
}

/// A clip or the ride file as exported.
@immutable
class RideExportFileEntry {
  /// Creates an entry.
  const RideExportFileEntry({
    required this.name,
    required this.bytes,
    required this.sha256,
    this.recordedSha256,
    this.recordedInvalid = false,
    this.locked = false,
  });

  /// The file name.
  final String name;

  /// Bytes exported.
  final int bytes;

  /// SHA-256: of the copy for a folder (equal to the source), of the source
  /// for a share.
  final String sha256;

  /// The hash recorded when the ride was saved (clips only), or `null`
  /// (also when the recorded value is not a SHA-256).
  final String? recordedSha256;

  /// Whether a value was recorded that is not a SHA-256.
  final bool recordedInvalid;

  /// Whether the clip is locked.
  final bool locked;

  /// How the exported bytes compare with [recordedSha256].
  RideExportRecorded get recorded {
    final recorded = recordedSha256;
    if (recorded == null) {
      return RideExportRecorded.none;
    }
    return recorded.toLowerCase() == sha256.toLowerCase()
        ? RideExportRecorded.match
        : RideExportRecorded.differs;
  }
}

/// The result of one export run.
@immutable
class RideExportResult {
  /// Creates a result.
  const RideExportResult({
    required this.outcome,
    required this.destination,
    required this.folderName,
    this.clips = const <RideExportFileEntry>[],
    this.rideData,
    this.fileCount = 0,
    this.bytes = 0,
    this.skipped = 0,
    this.failedCount = 0,
    this.allSynced = true,
    this.failureCode,
    this.failureName,
  });

  /// How the run ended.
  final RideExportOutcome outcome;

  /// Folder or share.
  final RideExportDestination destination;

  /// The export folder name (for a share, its subject).
  final String folderName;

  /// Clips exported (or hashed for a share), in order.
  final List<RideExportFileEntry> clips;

  /// The ride file as exported, or `null`.
  final RideExportFileEntry? rideData;

  /// Files now in the folder from this export (including skipped ones and
  /// the text files), or files handed to the share sheet.
  final int fileCount;

  /// Bytes of those files.
  final int bytes;

  /// Files that were already in the folder.
  final int skipped;

  /// Files that failed.
  final int failedCount;

  /// Whether every copy was synced to the storage device.
  final bool allSynced;

  /// The code of the first failure (a native code, or `RIDE_DATA_CHANGED`
  /// when the ride file changed during the export, or `FAILED`).
  final String? failureCode;

  /// The file that failed first, if any.
  final String? failureName;

  /// Exported clips that differ from their recorded hash.
  int get sourceDiffers =>
      clips.where((c) => c.recorded == RideExportRecorded.differs).length;

  /// Exported clips without a recorded hash.
  int get noRecordedHash =>
      clips.where((c) => c.recorded == RideExportRecorded.none).length;
}

/// Thrown inside a run when it must stop (pause or cancel).
class _Stopped implements Exception {
  const _Stopped();
}

/// Collects a run's progress and builds its result.
class _Run {
  _Run(this.plan, this.destination, this.total, this.onProgress);

  final RideExportPlan plan;
  final RideExportDestination destination;
  final int total;
  final void Function(int done, int total)? onProgress;

  final List<RideExportFileEntry> clips = <RideExportFileEntry>[];
  RideExportFileEntry? rideData;
  int done = 0;
  int fileCount = 0;
  int bytes = 0;
  int skipped = 0;
  int failedCount = 0;
  bool allSynced = true;
  String? failureCode;
  String? failureName;

  void step() {
    done++;
    onProgress?.call(done, total);
  }

  void counted(int fileBytes, {bool wasSkipped = false, bool synced = true}) {
    fileCount++;
    bytes += fileBytes;
    if (wasSkipped) {
      skipped++;
    }
    allSynced = allSynced && synced;
  }

  void fail(String code, String? name) {
    failedCount++;
    failureCode ??= code;
    failureName ??= name;
  }

  RideExportResult result(RideExportOutcome outcome) => RideExportResult(
    outcome: outcome,
    destination: destination,
    folderName: plan.folderName,
    clips: List<RideExportFileEntry>.unmodifiable(clips),
    rideData: rideData,
    fileCount: fileCount,
    bytes: bytes,
    skipped: skipped,
    failedCount: failedCount,
    allSynced: allSynced,
    failureCode: failureCode,
    failureName: failureName,
  );
}

/// Runs one export of a [RideExportPlan] over [native].
///
/// Folder ([exportToFolder]): prepares the folder, copies the clips, then
/// (only when every clip copied and matched its copy) the ride file, whose
/// streamed hash must equal the hash read at the start, then
/// manifest.json and MOTOCAM-EXPORT.txt (staged under [cacheDirectory]).
/// Share ([share]): hashes each file, stages the text files under
/// `<cacheDirectory>/ride_export/<folder name>-<epoch ms>/` and opens the
/// share sheet.
///
/// [shouldPause] is checked before each file and, while a native call
/// runs, every [pollInterval]; the call is then cancelled and the run
/// returns [RideExportOutcome.paused]. [cancel] stops the run the same way
/// with [RideExportOutcome.cancelled]. One exporter runs one export.
class RideExporter {
  /// Creates an exporter. [cacheDirectory] must be the app's cache
  /// directory (path_provider's `getTemporaryDirectory`), which the
  /// FileProvider shares `ride_export/` from.
  RideExporter({
    required this.native,
    required this.cacheDirectory,
    bool Function()? shouldPause,
    DateTime Function()? now,
    this.pollInterval = const Duration(milliseconds: 200),
  }) : shouldPause = shouldPause ?? _never,
       now = now ?? DateTime.now;

  static bool _never() => false;

  /// The native operations.
  final RideExportNative native;

  /// The app's cache directory.
  final String cacheDirectory;

  /// Whether the run must pause now (a recording is starting or running).
  final bool Function() shouldPause;

  /// The clock (export time and staging folder names).
  final DateTime Function() now;

  /// How often [shouldPause] and [cancel] are checked during a native call.
  final Duration pollInterval;

  bool _cancelRequested = false;

  /// Stops the run at once (the native call in flight is cancelled); the
  /// run returns [RideExportOutcome.cancelled].
  Future<void> cancel() async {
    _cancelRequested = true;
    await native.cancel();
  }

  String get _sep => Platform.pathSeparator;

  bool get _mustStop => _cancelRequested || shouldPause();

  RideExportOutcome get _stoppedOutcome =>
      _cancelRequested ? RideExportOutcome.cancelled : RideExportOutcome.paused;

  /// Throws [_Stopped] when the run must stop. Called right before each
  /// native call: native resets its cancel flag when a call starts, so a
  /// cancel sent before that call would be lost.
  void _checkStop() {
    if (_mustStop) {
      throw const _Stopped();
    }
  }

  /// Runs [call] after a stop check, cancelling it natively when the run
  /// must stop. Throws [_Stopped] then.
  Future<T> _native<T>(Future<T> Function() call) async {
    _checkStop();
    var stopping = false;
    final poll = Timer.periodic(pollInterval, (_) {
      if (!stopping && _mustStop) {
        stopping = true;
        unawaited(native.cancel());
      }
    });
    try {
      return await call();
    } on RideExportCancelled {
      throw const _Stopped();
    } finally {
      poll.cancel();
    }
  }

  /// Exports [plan] into the folder `plan.folderName` of the picked tree
  /// [treeUri]. [onProgress] gets the files done and the total after each
  /// file.
  Future<RideExportResult> exportToFolder(
    RideExportPlan plan, {
    required String treeUri,
    void Function(int done, int total)? onProgress,
  }) async {
    final data = plan.rideData;
    final run = _Run(
      plan,
      RideExportDestination.folder,
      plan.clips.length + (data == null ? 0 : 1) + 2,
      onProgress,
    );
    Directory? staging;
    String? current = plan.folderName;
    try {
      _checkStop();
      final folderUri = await native.prepareFolder(
        treeUri: treeUri,
        name: plan.folderName,
        expectedNames: plan.expectedNames,
      );

      for (final item in plan.clips) {
        try {
          final copied = await _native(
            () => native.exportFile(
              folderUri: folderUri,
              sourcePath: item.sourcePath,
              name: item.name,
              mimeType: rideExportMimeTypeFor(item.name),
            ),
          );
          run.clips.add(
            RideExportFileEntry(
              name: item.name,
              bytes: copied.bytes,
              sha256: copied.copySha256,
              recordedSha256: item.recordedSha256,
              recordedInvalid: item.recordedInvalid,
              locked: item.locked,
            ),
          );
          run.counted(
            copied.bytes,
            wasSkipped: copied.skipped,
            synced: copied.synced,
          );
        } on RideExportFailure catch (e) {
          run.fail(e.code, item.name);
        }
        run.step();
      }
      if (run.failedCount > 0) {
        return run.result(RideExportOutcome.failed);
      }

      if (data != null) {
        current = data.name;
        final copied = await _native(
          () => integrity_utils.runExclusiveForPath(data.sourcePath, () {
            // The lock may have waited; a stop sent meanwhile counts.
            _checkStop();
            return native.exportFile(
              folderUri: folderUri,
              sourcePath: data.sourcePath,
              name: data.name,
              mimeType: rideExportMimeTypeFor(data.name),
            );
          }),
        );
        if (copied.sourceSha256 != plan.source.rideDataSha256) {
          run.fail('RIDE_DATA_CHANGED', data.name);
          return run.result(RideExportOutcome.failed);
        }
        run.rideData = RideExportFileEntry(
          name: data.name,
          bytes: copied.bytes,
          sha256: copied.copySha256,
        );
        run.counted(
          copied.bytes,
          wasSkipped: copied.skipped,
          synced: copied.synced,
        );
        run.step();
      }

      staging = await _stage(plan, run, RideExportDestination.folder);
      for (final name in <String>[
        rideExportManifestName,
        rideExportReadmeName,
      ]) {
        current = name;
        final copied = await _native(
          () => native.exportFile(
            folderUri: folderUri,
            sourcePath: '${staging!.path}$_sep$name',
            name: name,
            mimeType: rideExportMimeTypeFor(name),
          ),
        );
        run.counted(
          copied.bytes,
          wasSkipped: copied.skipped,
          synced: copied.synced,
        );
        run.step();
      }
      return run.result(RideExportOutcome.done);
    } on _Stopped {
      return run.result(_stoppedOutcome);
    } on RideExportFailure catch (e) {
      run.fail(e.code, current);
      return run.result(RideExportOutcome.failed);
    } catch (e) {
      debugPrint('Ride export failed: $e');
      run.fail('FAILED', current);
      return run.result(RideExportOutcome.failed);
    } finally {
      if (staging != null) {
        await _deleteQuietly(staging);
      }
    }
  }

  /// Hashes the files of [plan], stages the manifest and README, and opens
  /// the share sheet with every file. Staging folders older than
  /// [rideExportStagingMaxAge] are deleted first. [onProgress] gets the
  /// files hashed and the total.
  Future<RideExportResult> share(
    RideExportPlan plan, {
    void Function(int done, int total)? onProgress,
  }) async {
    final data = plan.rideData;
    final run = _Run(
      plan,
      RideExportDestination.share,
      plan.clips.length + (data == null ? 0 : 1),
      onProgress,
    );
    Directory? staging;
    var shared = false;
    String? current;
    try {
      await _deleteOldStaging();
      for (final item in plan.clips) {
        current = item.name;
        final hashed = await _native(() => native.hashFile(item.sourcePath));
        run.clips.add(
          RideExportFileEntry(
            name: item.name,
            bytes: hashed.bytes,
            sha256: hashed.sha256,
            recordedSha256: item.recordedSha256,
            recordedInvalid: item.recordedInvalid,
            locked: item.locked,
          ),
        );
        run.counted(hashed.bytes);
        run.step();
      }
      if (data != null) {
        current = data.name;
        final hashed = await _native(
          () => integrity_utils.runExclusiveForPath(data.sourcePath, () {
            // The lock may have waited; a stop sent meanwhile counts.
            _checkStop();
            return native.hashFile(data.sourcePath);
          }),
        );
        if (hashed.sha256 != plan.source.rideDataSha256) {
          run.fail('RIDE_DATA_CHANGED', data.name);
          return run.result(RideExportOutcome.failed);
        }
        run.rideData = RideExportFileEntry(
          name: data.name,
          bytes: hashed.bytes,
          sha256: hashed.sha256,
        );
        run.counted(hashed.bytes);
        run.step();
      }

      current = null;
      staging = await _stage(plan, run, RideExportDestination.share);
      final paths = <String>[
        for (final item in plan.clips) item.sourcePath,
        if (data != null) data.sourcePath,
        '${staging.path}$_sep$rideExportManifestName',
        '${staging.path}$_sep$rideExportReadmeName',
      ];
      for (final path in paths.skip(paths.length - 2)) {
        run.counted(await File(path).length());
      }
      _checkStop();
      final opened = await native.shareFiles(
        paths: paths,
        mimeTypes: <String>[
          for (final path in paths)
            rideExportMimeTypeFor(path_utils.fileNameFromPath(path)),
        ],
        subject: plan.folderName,
      );
      if (!opened) {
        run.fail('NO_TARGET', null);
        return run.result(RideExportOutcome.failed);
      }
      shared = true;
      return run.result(RideExportOutcome.done);
    } on _Stopped {
      return run.result(_stoppedOutcome);
    } on RideExportFailure catch (e) {
      run.fail(e.code, current);
      return run.result(RideExportOutcome.failed);
    } catch (e) {
      debugPrint('Ride share failed: $e');
      run.fail('FAILED', current);
      return run.result(RideExportOutcome.failed);
    } finally {
      if (staging != null && !shared) {
        await _deleteQuietly(staging);
      }
    }
  }

  /// Writes the manifest and README of [run] into a new staging folder and
  /// returns it.
  Future<Directory> _stage(
    RideExportPlan plan,
    _Run run,
    RideExportDestination destination,
  ) async {
    final exportedAt = now();
    final directory = Directory(
      '$cacheDirectory$_sep$rideExportStagingDirectoryName$_sep'
      '${plan.folderName}-${exportedAt.millisecondsSinceEpoch}',
    );
    await directory.create(recursive: true);
    final manifest = buildExportManifest(
      plan,
      clips: run.clips,
      rideData: run.rideData,
      destination: destination,
      exportedAt: exportedAt,
    );
    await File('${directory.path}$_sep$rideExportManifestName').writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
      flush: true,
    );
    await File('${directory.path}$_sep$rideExportReadmeName').writeAsString(
      buildExportReadme(
        plan,
        clips: run.clips,
        rideData: run.rideData,
        destination: destination,
        exportedAt: exportedAt,
      ),
      flush: true,
    );
    return directory;
  }

  /// Deletes staging folders older than [rideExportStagingMaxAge].
  Future<void> _deleteOldStaging() async {
    final root = Directory(
      '$cacheDirectory$_sep$rideExportStagingDirectoryName',
    );
    final cutoff = now().subtract(rideExportStagingMaxAge);
    try {
      if (!await root.exists()) {
        return;
      }
      await for (final entity in root.list(followLinks: false)) {
        if (entity is Directory &&
            (await entity.stat()).modified.isBefore(cutoff)) {
          await _deleteQuietly(entity);
        }
      }
    } catch (_) {
      // Tried again at the next share.
    }
  }

  Future<void> _deleteQuietly(Directory directory) async {
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // The cache is cleared by the system or the next share.
    }
  }
}

/// The rider's sentence for a failure [code] ([name]: the file concerned;
/// [count]: files that failed to copy). Also used for the failures
/// [loadRideExportSource] and the folder picker throw.
String rideExportFailureText(
  String code, {
  String? name,
  int count = 1,
  RideExportDestination destination = RideExportDestination.folder,
}) {
  final share = destination == RideExportDestination.share;
  switch (code) {
    case 'FOLDER_NOT_EMPTY':
      return 'This folder holds other files; pick another folder.';
    case 'NOT_WRITABLE':
      return 'This folder cannot be written; pick another.';
    case 'EXISTS_DIFFERENT':
      return 'A different file named ${name ?? 'like this'} is already in '
          'the folder.';
    case 'NAME_CONFLICT':
      return 'The folder app would not keep the name '
          '"${name ?? 'of the export'}"; pick another folder.';
    case 'RIDE_DATA_CHANGED':
      return share
          ? 'The ride file changed while preparing the share; run Share '
                'again.'
          : 'The ride file changed during export; run Export again.';
    case 'SOURCE_CHANGED':
      return 'The ride file changed; try again.';
    case 'SOURCE_UNREADABLE':
      return 'The ride file could not be read.';
    case 'NOT_SHAREABLE':
      return 'This ride is still in an old storage folder and cannot be '
          'shared; export it to a folder instead.';
    case 'NO_TARGET':
      return 'No app on this phone can receive these files.';
    case 'UNAVAILABLE':
      return 'Export is available on Android only.';
    case 'BUSY':
      return 'The folder picker is already open.';
    case 'NO_PICKER':
      return 'This phone has no folder picker.';
    case 'WRITE_FAILED':
    case 'COPY_MISMATCH':
    case 'SOURCE_NOT_FOUND':
    case 'FAILED':
      if (!share) {
        final files = count == 1 ? '1 file' : '$count files';
        return 'Could not copy $files (the folder may be full or was '
            'removed). Run Export again: files already exported are '
            'skipped.';
      }
  }
  return share
      ? 'Could not prepare the share ($code).'
      : 'Could not export the ride ($code).';
}

/// The rider's message at the end of an export (shown for 8 s).
String rideExportSummary(RideExportResult result) {
  final share = result.destination == RideExportDestination.share;
  switch (result.outcome) {
    case RideExportOutcome.paused:
      return share
          ? 'Share stopped because a recording started. Run it again.'
          : 'Export stopped because a recording started. Run it again to '
                'continue.';
    case RideExportOutcome.cancelled:
      return share
          ? 'Share stopped.'
          : 'Export stopped. Run it again to continue: files already '
                'exported are skipped.';
    case RideExportOutcome.failed:
      return rideExportFailureText(
        result.failureCode ?? 'FAILED',
        name: result.failureName,
        count: result.failedCount,
        destination: result.destination,
      );
    case RideExportOutcome.done:
      break;
  }
  final files = result.fileCount == 1 ? '1 file' : '${result.fileCount} files';
  final buffer = StringBuffer();
  if (share) {
    buffer.write(
      'Opened the share sheet with $files. Check that the receiving app got '
      'all of them.',
    );
  } else {
    buffer.write(
      'Exported $files (${formatFileSize(result.bytes)}) to '
      '"${result.folderName}". ',
    );
    buffer.write(
      result.allSynced
          ? 'All copies checked.'
          : 'Copied and checked; the storage app may still be saving them.',
    );
  }
  final differs = result.sourceDiffers;
  if (differs > 0) {
    buffer.write(
      differs == 1
          ? ' 1 clip differs from the hash recorded when the ride was saved; '
                'this is noted in $rideExportReadmeName.'
          : ' $differs clips differ from the hash recorded when the ride was '
                'saved; this is noted in $rideExportReadmeName.',
    );
  }
  return buffer.toString();
}
