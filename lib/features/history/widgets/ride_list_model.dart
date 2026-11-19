// lib/features/history/widgets/ride_list_model.dart
//
// The pure decisions behind the Ride History list of redesign A: filters,
// the integrity stamps of a row, the incomplete-ride row, the order of the
// list (Locked Clips first, month headers inside All Rides), the row's
// actions menu and its busy slot, and the row's texts. No widgets, no I/O,
// so each rule is unit tested on its own.

import 'package:intl/intl.dart';

import '../models/ride_record.dart';
import '../models/segment_verifier.dart';

/// The in-memory filter chips of Ride History. Several chips together
/// narrow the list: a ride is shown when it matches every chip that is on.
enum RideFilter {
  /// Rides with locked clips.
  locked,

  /// Rides with at least one detected incident.
  incidents,

  /// Rides recovered after the app stopped: video only (no ride file), or
  /// a ride file that was not closed with Stop.
  recovered,
}

/// Whether [ride] matches [filter].
bool rideMatchesFilter(RideRecord ride, RideFilter filter) => switch (filter) {
  RideFilter.locked => ride.isLocked,
  RideFilter.incidents => ride.incidents?.isNotEmpty ?? false,
  RideFilter.recovered => ride.telemetryPath == null || !ride.isSessionComplete,
};

/// Whether [ride] matches every filter in [filters] (all rides match an
/// empty set).
bool rideMatchesFilters(RideRecord ride, Set<RideFilter> filters) =>
    filters.every((filter) => rideMatchesFilter(ride, filter));

/// Whether [ride] is drawn as the amber "incomplete ride" row: it has a
/// ride file, but the app stopped before Stop closed it. A video-only ride
/// is not one: it has no ride file to be incomplete.
bool isIncompleteRideRow(RideRecord ride) =>
    ride.telemetryPath != null && !ride.isSessionComplete;

/// The kinds of stamp a ride row can carry.
enum RideStampKind {
  /// No ride file: the video was recovered on its own.
  videoOnly,

  /// The ride data or a checked video failed its integrity check.
  checkFailed,

  /// The GPS came from a mock-location provider.
  simulatedGps,

  /// Ride data unmodified and signed with this phone's key.
  signedHere,

  /// Ride data unmodified; signed by another key, an unknown signer, or
  /// not signed (an older envelope).
  unmodified,

  /// A ride file without an integrity envelope.
  unsigned,

  /// Every video with a recorded hash was checked and matched.
  videosVerified,

  /// Some segment paths were quarantined.
  quarantined,

  /// Some segments of the ride are missing.
  incomplete,

  /// The ride has locked clips.
  locked,

  /// The ride has detected incidents.
  incidents,
}

/// One stamp of a ride row: a short visible [label] and a full
/// [semanticsLabel].
class RideStamp {
  /// Creates a stamp.
  const RideStamp(this.kind, this.label, this.semanticsLabel);

  /// What the stamp says.
  final RideStampKind kind;

  /// Visible text.
  final String label;

  /// Accessibility text.
  final String semanticsLabel;

  @override
  bool operator ==(Object other) =>
      other is RideStamp &&
      other.kind == kind &&
      other.label == label &&
      other.semanticsLabel == semanticsLabel;

  @override
  int get hashCode => Object.hash(kind, label, semanticsLabel);

  @override
  String toString() => 'RideStamp($kind, $label)';
}

/// The facts the stamps are drawn from, as plain values.
class RideStampFacts {
  /// Creates the facts.
  const RideStampFacts({
    required this.hasTelemetry,
    required this.status,
    required this.signedBy,
    required this.mockLocation,
    required this.videoCheck,
    this.quarantinedCount = 0,
    this.missingCount = 0,
    this.segmentCount = 0,
    this.lockedCount = 0,
    this.incidentCount = 0,
  });

  /// The facts of [ride], with the [videoCheck] stored in the ride index.
  factory RideStampFacts.of(RideRecord ride, RideVideoCheck videoCheck) =>
      RideStampFacts(
        hasTelemetry: ride.telemetryPath != null,
        status: ride.integrity.status,
        signedBy: ride.integrity.signedBy,
        mockLocation: ride.mockLocationDetected,
        videoCheck: videoCheck,
        quarantinedCount: ride.quarantinedSegmentPaths.length,
        missingCount: ride.missingSegmentPaths.length,
        segmentCount: ride.segmentPaths.length,
        lockedCount: ride.lockedSegmentPaths.length,
        incidentCount: ride.incidents?.length ?? 0,
      );

  /// Whether the ride has a ride file.
  final bool hasTelemetry;

  /// The ride data check.
  final RideIntegrityStatus status;

  /// Who signed the ride data.
  final RideSignedBy signedBy;

  /// Whether the GPS came from a mock-location provider.
  final bool mockLocation;

  /// The video check stored in the ride index.
  final RideVideoCheck videoCheck;

  /// Quarantined segment paths.
  final int quarantinedCount;

  /// Missing segments.
  final int missingCount;

  /// All segments of the ride.
  final int segmentCount;

  /// Locked segments.
  final int lockedCount;

  /// Detected incidents.
  final int incidentCount;
}

String _plural(int count, String one, String many) =>
    count == 1 ? '1 $one' : '$count $many';

/// The stamps of a ride row, in order. Every honesty label of the old
/// badges survives:
///
/// * a failed data check or a failed video check is "Check failed", and
///   then no signed or unmodified stamp is shown;
/// * simulated GPS (data check not failed) always shows, and replaces the
///   signed, unmodified or unsigned stamp, so a mock-GPS ride never reads
///   as signed;
/// * otherwise "Signed on this phone" (this phone's key), "Unmodified"
///   (verified, any other signer or none) or "Unsigned" (a ride file
///   without an envelope);
/// * "Video only", "Videos verified", "Quarantined", "Incomplete" (missing
///   segments), the locked count and the incident count.
List<RideStamp> rideStampsFor(RideStampFacts facts) {
  final dataFailed = facts.status == RideIntegrityStatus.modified;
  final videoFailed = facts.videoCheck.failed > 0;
  final checkFailed = dataFailed || videoFailed;
  final simulated = facts.mockLocation && !dataFailed;
  return <RideStamp>[
    if (!facts.hasTelemetry)
      const RideStamp(
        RideStampKind.videoOnly,
        'Video only',
        'Video only: recovered without its ride data',
      ),
    if (checkFailed)
      RideStamp(
        RideStampKind.checkFailed,
        'Check failed',
        dataFailed
            ? 'Check failed: the ride data failed its integrity check'
            : 'Check failed: ${facts.videoCheck.failed} of '
                  '${facts.videoCheck.total} videos differ from the '
                  'recorded hash',
      ),
    if (simulated)
      const RideStamp(
        RideStampKind.simulatedGps,
        'Simulated GPS',
        'Simulated GPS: the location came from a mock location provider',
      ),
    if (!checkFailed && !simulated) ...[
      if (facts.status == RideIntegrityStatus.verified &&
          facts.signedBy == RideSignedBy.thisDevice)
        const RideStamp(
          RideStampKind.signedHere,
          'Signed on this phone',
          'Signed on this phone: ride data unmodified',
        )
      else if (facts.status == RideIntegrityStatus.verified)
        const RideStamp(
          RideStampKind.unmodified,
          'Unmodified',
          'Unmodified: ride data unchanged since recording',
        )
      else if (facts.hasTelemetry)
        const RideStamp(
          RideStampKind.unsigned,
          'Unsigned',
          'Unsigned: MotoCam cannot prove the files are unchanged',
        ),
    ],
    if (!checkFailed && facts.videoCheck.isVerified)
      const RideStamp(
        RideStampKind.videosVerified,
        'Videos verified',
        'Videos verified: unmodified since recording',
      ),
    if (facts.quarantinedCount > 0)
      RideStamp(
        RideStampKind.quarantined,
        'Quarantined ${facts.quarantinedCount}',
        'Quarantined: ${_plural(facts.quarantinedCount, 'path', 'paths')}',
      ),
    if (facts.missingCount > 0)
      RideStamp(
        RideStampKind.incomplete,
        'Incomplete',
        'Incomplete: ${facts.missingCount} of ${facts.segmentCount} clips '
            'missing',
      ),
    if (facts.lockedCount > 0)
      RideStamp(
        RideStampKind.locked,
        '${facts.lockedCount} locked',
        _plural(facts.lockedCount, 'locked clip', 'locked clips'),
      ),
    if (facts.incidentCount > 0)
      RideStamp(
        RideStampKind.incidents,
        _plural(facts.incidentCount, 'incident', 'incidents'),
        _plural(facts.incidentCount, 'incident', 'incidents'),
      ),
  ];
}

/// The stamps of [ride] with its stored [videoCheck].
List<RideStamp> rideStamps(RideRecord ride, RideVideoCheck videoCheck) =>
    rideStampsFor(RideStampFacts.of(ride, videoCheck));

/// One entry of the Ride History list.
sealed class RideListItem {
  const RideListItem();
}

/// A section title: "Locked Clips" or "All Rides".
class RideSectionHeader extends RideListItem {
  /// Creates a section title.
  const RideSectionHeader(this.title);

  /// The title.
  final String title;
}

/// A month header inside All Rides, for example "NOVEMBER".
class RideMonthHeader extends RideListItem {
  /// Creates a month header.
  const RideMonthHeader(this.label);

  /// The upper-case month, with the year when it is not [now]'s year.
  final String label;
}

/// A ride row.
class RideListRide extends RideListItem {
  /// Creates a ride row.
  const RideListRide(this.ride);

  /// The ride.
  final RideRecord ride;
}

/// The title of the locked section.
const String rideLockedSectionTitle = 'Locked Clips';

/// The title of the section of every other ride.
const String rideAllSectionTitle = 'All Rides';

/// The month header of [date]: "NOVEMBER", or "NOVEMBER 2025" in another
/// year than [now]'s.
String rideMonthLabel(DateTime date, DateTime now) {
  final month = DateFormat('MMMM').format(date).toUpperCase();
  return date.year == now.year ? month : '$month ${date.year}';
}

/// The list of [rides] (newest first, as loaded) under [filters]: the
/// Locked Clips section first, then All Rides with a header at each new
/// month. Without filters All Rides always has its title, as before; with
/// filters an empty section is left out. Empty when no ride matches.
List<RideListItem> rideListItems(
  List<RideRecord> rides, {
  Set<RideFilter> filters = const <RideFilter>{},
  required DateTime now,
}) {
  final shown = rides
      .where((ride) => rideMatchesFilters(ride, filters))
      .toList(growable: false);
  if (shown.isEmpty) {
    return const <RideListItem>[];
  }
  final locked = shown.where((ride) => ride.isLocked).toList();
  final others = shown.where((ride) => !ride.isLocked).toList();
  final items = <RideListItem>[];
  if (locked.isNotEmpty) {
    items
      ..add(const RideSectionHeader(rideLockedSectionTitle))
      ..addAll(locked.map(RideListRide.new));
  }
  if (others.isNotEmpty || filters.isEmpty) {
    items.add(const RideSectionHeader(rideAllSectionTitle));
    String? month;
    for (final ride in others) {
      final label = rideMonthLabel(ride.createdAt, now);
      if (label != month) {
        month = label;
        items.add(RideMonthHeader(label));
      }
      items.add(RideListRide(ride));
    }
  }
  return items;
}

/// The actions of a ride's menu.
enum RideMenuAction {
  /// Export the ride to a picked folder.
  exportFolder,

  /// Share the ride through the share sheet.
  share,

  /// Copy the ride's videos to the gallery.
  saveToGallery,

  /// Remove the gallery copies MotoCam made.
  removeGalleryCopies,

  /// Remove the lock marker.
  unlock,

  /// Delete the ride.
  delete,
}

/// One entry of a ride's menu.
class RideMenuEntry {
  /// Creates an entry.
  const RideMenuEntry(this.action, {this.enabled = true, this.reason});

  /// The action.
  final RideMenuAction action;

  /// Whether it can be chosen now.
  final bool enabled;

  /// Why it cannot (or, for Delete of a locked ride, what happens), shown
  /// under the label; `null` for a plain entry.
  final String? reason;
}

/// The "Share and export" group of a ride's menu (Android only).
const String rideMenuShareGroupTitle = 'SHARE AND EXPORT';

/// The entries of a ride's menu with the same guards as the old row
/// buttons:
///
/// * the Share and export group only on Android ([android]); "Remove
///   gallery copies" only when the ride has some;
/// * Unlock only for a locked ride, enabled when the lock state may change
///   ([canChangeLockState]) and no lock change, gallery job or export of
///   the ride runs;
/// * Delete for every ride, disabled only while a gallery job or export of
///   the ride runs (a locked ride's Delete explains it must be unlocked).
List<RideMenuEntry> rideMenuEntries({
  required bool android,
  required bool isLocked,
  required bool canChangeLockState,
  required bool isUpdatingLock,
  required bool galleryBusy,
  required bool exportBusy,
  required int galleryCopies,
}) {
  final busy = galleryBusy || exportBusy;
  final waitText = exportBusy
      ? 'Wait for the export to finish'
      : 'Wait for the gallery copies to finish';
  final canToggleLockState =
      canChangeLockState && !isUpdatingLock && !galleryBusy && !exportBusy;
  return <RideMenuEntry>[
    if (android) ...[
      const RideMenuEntry(RideMenuAction.exportFolder),
      const RideMenuEntry(RideMenuAction.share),
      const RideMenuEntry(RideMenuAction.saveToGallery),
      if (galleryCopies > 0)
        const RideMenuEntry(RideMenuAction.removeGalleryCopies),
    ],
    if (isLocked)
      RideMenuEntry(
        RideMenuAction.unlock,
        enabled: canToggleLockState,
        reason: canToggleLockState
            ? null
            : busy
            ? waitText
            : 'Integrity warning: lock state changes disabled',
      ),
    RideMenuEntry(
      RideMenuAction.delete,
      enabled: !busy,
      reason: busy
          ? waitText
          : isLocked && canChangeLockState
          ? 'Unlock the ride to delete it'
          : null,
    ),
  ];
}

/// What the row's trailing slot shows in place of the menu.
enum RideRowBusy {
  /// Nothing runs: the menu.
  none,

  /// The ride is being exported: a ring that stops the export.
  export,

  /// Gallery copies are being saved or removed: a ring.
  gallery,

  /// The videos are checked before unlocking: a ring.
  lockCheck,

  /// The ride is being deleted: a ring.
  deleting,
}

/// The trailing slot of a ride row. The export ring wins, because it
/// carries the stop; then the gallery job, the lock check and the delete.
RideRowBusy rideRowBusy({
  required bool exportBusy,
  required bool galleryBusy,
  required bool isUpdatingLock,
  required bool isDeleting,
}) {
  if (exportBusy) {
    return RideRowBusy.export;
  }
  if (galleryBusy) {
    return RideRowBusy.gallery;
  }
  if (isUpdatingLock) {
    return RideRowBusy.lockCheck;
  }
  if (isDeleting) {
    return RideRowBusy.deleting;
  }
  return RideRowBusy.none;
}

/// [duration] as "45 s", "41 min" or "1 h 52 min".
String rideShortDuration(Duration duration) {
  final safe = duration.isNegative ? Duration.zero : duration;
  if (safe.inMinutes == 0) {
    return '${safe.inSeconds} s';
  }
  final hours = safe.inHours;
  final minutes = safe.inMinutes.remainder(60);
  if (hours == 0) {
    return '$minutes min';
  }
  return minutes == 0 ? '$hours h' : '$hours h $minutes min';
}

/// [duration] in words: "45 seconds", "41 minutes", "1 hour 52 minutes".
String rideLongDuration(Duration duration) {
  final safe = duration.isNegative ? Duration.zero : duration;
  if (safe.inMinutes == 0) {
    return _plural(safe.inSeconds, 'second', 'seconds');
  }
  final hours = safe.inHours;
  final minutes = safe.inMinutes.remainder(60);
  return <String>[
    if (hours > 0) _plural(hours, 'hour', 'hours'),
    if (minutes > 0) _plural(minutes, 'minute', 'minutes'),
  ].join(' ');
}

/// The row's summary, for example "41 min, 1.7 GB, 6 clips": the duration,
/// the size of the segment files that exist (left out when unknown or
/// zero) and the clips ("4 of 6 clips" when some are missing).
String rideSummaryText(RideRecord ride, String Function(int bytes) size) {
  final count = ride.segmentPaths.length;
  final available = ride.availableSegmentCount;
  final bytes = ride.totalSegmentBytes;
  return <String>[
    rideShortDuration(ride.duration),
    if (bytes != null && bytes > 0) size(bytes),
    available == count
        ? _plural(count, 'clip', 'clips')
        : '$available of $count clips',
  ].join(', ');
}

/// The row's date: "13 Nov, 13:21", with the year when it is not [now]'s.
String rideDateLabel(DateTime date, DateTime now) {
  final day = date.year == now.year
      ? DateFormat('d MMM').format(date)
      : DateFormat('d MMM yyyy').format(date);
  return '$day, ${DateFormat('HH:mm').format(date)}';
}

/// The sentence of the incomplete-ride row, for example "Recording ended
/// without Stop at about 14:02. 41 minutes saved, 3 locked clips." The end
/// time is not stored: it is the start plus the saved duration, so it says
/// "about".
String incompleteRideText(RideRecord ride) {
  final end = ride.createdAt.add(ride.duration);
  final locked = ride.lockedSegmentPaths.length;
  return 'Recording ended without Stop at about '
      '${DateFormat('HH:mm').format(end)}. '
      '${rideLongDuration(ride.duration)} saved'
      '${locked > 0 ? ', ${_plural(locked, 'locked clip', 'locked clips')}' : ''}.';
}

/// The note of an incomplete ride without an integrity envelope (the
/// board's wording of the unknown state), or `null` when the ride has a
/// checked envelope (its stamps say how it went).
String? incompleteRideNote(RideRecord ride) =>
    ride.integrity.status == RideIntegrityStatus.unknown
    ? 'Unsigned: it was not closed with Stop, so MotoCam cannot prove the '
          'files are unchanged.'
    : null;
