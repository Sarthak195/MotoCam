import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/build_flags.dart';
import '../../../core/theme/tokens.dart';
import '../../camera/providers/camera_provider.dart';
import '../models/ride_record.dart';
import '../services/ride_export.dart';
import '../services/ride_integrity_text.dart';
import 'playback_position.dart';

/// The playback header: a back button, the ride's date ("13 Nov, 13:21")
/// and its summary ("41 min, 1.7 GB, 6 clips").
class PlaybackHeader extends StatelessWidget {
  /// Creates the header.
  const PlaybackHeader({
    super.key,
    required this.title,
    required this.onBack,
    this.subtitle,
    this.compact = false,
  });

  /// The ride's date.
  final String title;

  /// The ride's summary; left out when null.
  final String? subtitle;

  /// The rider pressed Back.
  final VoidCallback onBack;

  /// The landscape size (a 24 px title instead of 26).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: compact ? 48 : 56),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back to rides',
            onPressed: onBack,
            constraints: const BoxConstraints.tightFor(
              width: MotoSize.minTarget,
              height: MotoSize.minTarget,
            ),
            padding: EdgeInsets.zero,
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: MotoColors.text,
              size: 22,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MotoFonts.condensedStyle(
                      compact ? 24 : 26,
                      color: MotoColors.text,
                      height: 1.1,
                      tabularFigures: true,
                    ),
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: MotoFonts.bodyStyle(13, color: MotoColors.dim),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// How the playback strip reads a ride's integrity.
enum PlaybackIntegrityKind {
  /// Ride data unmodified and signed with this phone's key, and nothing
  /// else on the screen says otherwise.
  signedHere,

  /// Ride data unmodified (another signer, an unknown one, or none).
  unmodified,

  /// The ride data or a checked video failed its integrity check.
  checkFailed,

  /// The GPS came from a mock-location provider.
  simulatedGps,

  /// No integrity record, or the ride file could not be read again.
  notAvailable,

  /// No ride file: a video recovered on its own.
  videoOnly,
}

/// The playback strip's integrity badge: a short [label] and the full
/// [detail] (the sentence from `ride_integrity_text.dart`, plus what the
/// video check found), read out by TalkBack and shown on a tap.
@immutable
class PlaybackIntegrityBadge {
  /// Creates a badge.
  const PlaybackIntegrityBadge(this.kind, this.label, this.detail);

  /// What the badge says.
  final PlaybackIntegrityKind kind;

  /// Visible text.
  final String label;

  /// The full sentence.
  final String detail;

  @override
  bool operator ==(Object other) =>
      other is PlaybackIntegrityBadge &&
      other.kind == kind &&
      other.label == label &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(kind, label, detail);

  @override
  String toString() => 'PlaybackIntegrityBadge($kind, $label)';
}

/// The integrity badge of [ride] on the playback screen.
///
/// The reassuring shield ("Signed on this phone") is shown only when the
/// ride data is verified and signed here, its GPS was real, no video
/// failed the check ([failedVideoCount]) and the ride file could be read
/// again ([rideReadFailed] false). A failed check always wins, so the
/// strip never contradicts the timeline's failed-check ranges.
PlaybackIntegrityBadge playbackIntegrityBadge({
  required RideRecord ride,
  required int failedVideoCount,
  required bool rideReadFailed,
}) {
  final videoNote = failedVideoCount <= 0
      ? ''
      : failedVideoCount == 1
      ? ' 1 video could not be confirmed unmodified since recording.'
      : ' $failedVideoCount videos could not be confirmed unmodified since '
            'recording.';
  final line = rideIntegrityLine(ride);
  final detail = '${line.endsWith('.') ? line : '$line.'}$videoNote';
  if (ride.telemetryPath == null) {
    return PlaybackIntegrityBadge(
      PlaybackIntegrityKind.videoOnly,
      'Video only',
      'Video only: recovered without its ride data.$videoNote',
    );
  }
  final status = ride.integrity.status;
  if (status == RideIntegrityStatus.modified || failedVideoCount > 0) {
    return PlaybackIntegrityBadge(
      PlaybackIntegrityKind.checkFailed,
      'Check failed',
      detail,
    );
  }
  if (rideReadFailed) {
    return const PlaybackIntegrityBadge(
      PlaybackIntegrityKind.notAvailable,
      'Not checked',
      'The ride file could not be read again, so its videos were not '
          'checked.',
    );
  }
  if (ride.mockLocationDetected) {
    return PlaybackIntegrityBadge(
      PlaybackIntegrityKind.simulatedGps,
      'Simulated GPS',
      detail,
    );
  }
  if (status == RideIntegrityStatus.verified) {
    return ride.integrity.signedBy == RideSignedBy.thisDevice
        ? PlaybackIntegrityBadge(
            PlaybackIntegrityKind.signedHere,
            'Signed on this phone',
            detail,
          )
        : PlaybackIntegrityBadge(
            PlaybackIntegrityKind.unmodified,
            'Unmodified',
            detail,
          );
  }
  return PlaybackIntegrityBadge(
    PlaybackIntegrityKind.notAvailable,
    'Unsigned',
    detail,
  );
}

({IconData icon, Color color}) _badgeLook(PlaybackIntegrityKind kind) =>
    switch (kind) {
      PlaybackIntegrityKind.signedHere => (
        icon: Icons.verified_user,
        color: MotoColors.text,
      ),
      PlaybackIntegrityKind.unmodified => (
        icon: Icons.verified_user_outlined,
        color: MotoColors.text,
      ),
      PlaybackIntegrityKind.checkFailed => (
        icon: Icons.gpp_bad,
        color: MotoColors.rec,
      ),
      PlaybackIntegrityKind.simulatedGps => (
        icon: Icons.location_off,
        color: MotoColors.amber,
      ),
      PlaybackIntegrityKind.notAvailable => (
        icon: Icons.shield_outlined,
        color: MotoColors.dim,
      ),
      PlaybackIntegrityKind.videoOnly => (
        icon: Icons.videocam_outlined,
        color: MotoColors.dim,
      ),
    };

/// The integrity strip: the badge (a tap shows the full sentence) and,
/// when the ride has recorded video hashes, "Check videos again" (a
/// spinner while the check runs; disabled while [onCheck] is null).
class PlaybackIntegrityStrip extends StatelessWidget {
  /// Creates the strip.
  const PlaybackIntegrityStrip({
    super.key,
    required this.badge,
    required this.showCheck,
    required this.isChecking,
    required this.onCheck,
    this.stacked = false,
  });

  /// What the badge says.
  final PlaybackIntegrityBadge badge;

  /// Whether "Check videos again" is shown (the ride has video hashes).
  final bool showCheck;

  /// Whether a video check is running.
  final bool isChecking;

  /// Runs the check again; null disables the button.
  final VoidCallback? onCheck;

  /// The landscape layout: the button under the badge, full width.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final look = _badgeLook(badge.kind);
    final badgeView = Tooltip(
      message: badge.detail,
      triggerMode: TooltipTriggerMode.tap,
      showDuration: const Duration(seconds: 6),
      child: Semantics(
        label: '${badge.label}. ${badge.detail}',
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(look.icon, size: 22, color: look.color),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  badge.label,
                  style: MotoFonts.bodyStyle(
                    15,
                    weight: FontWeight.w600,
                    color: look.color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final check = OutlinedButton(
      onPressed: onCheck,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(MotoSize.minTarget, 44),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        foregroundColor: MotoColors.text,
        side: const BorderSide(color: MotoColors.disabled, width: 1.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MotoRadii.sm),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isChecking) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: MotoColors.text,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              isChecking ? 'Checking videos' : 'Check videos again',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MotoFonts.bodyStyle(15, weight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(alignment: Alignment.centerLeft, child: badgeView),
          if (showCheck) ...[const SizedBox(height: 6), check],
        ],
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: MotoSize.minTarget),
      child: Row(
        children: [
          Expanded(child: badgeView),
          if (showCheck) ...[const SizedBox(width: 10), Flexible(child: check)],
        ],
      ),
    );
  }
}

/// The ride actions: Export (to a folder) and Share, both through the
/// existing export flow with the playhead, or, while this ride is being
/// exported, a progress ring that stops the export. Unlock is reserved
/// behind [kPlaybackUnlock] (it stays in the Rides list menu).
class PlaybackRideActions extends StatelessWidget {
  /// Creates the actions.
  const PlaybackRideActions({
    super.key,
    required this.position,
    required this.exportProgress,
    required this.rideKey,
    required this.enabled,
    required this.onExport,
    required this.onStopExport,
    this.onUnlock,
    this.height = 56,
  });

  /// The playback position; read when an action is pressed.
  final ValueListenable<PlaybackPosition> position;

  /// The running ride export, if any.
  final ValueListenable<RideExportProgress?> exportProgress;

  /// The key the export progress names this ride by.
  final String rideKey;

  /// Whether Export and Share can be pressed (the ride is loaded and its
  /// file could be read).
  final bool enabled;

  /// Starts the export flow to [destination] with the playhead (ride time,
  /// in milliseconds) at the moment of the press.
  final void Function(RideExportDestination destination, int playheadMs)
  onExport;

  /// Stops the running export.
  final VoidCallback onStopExport;

  /// Unlocks the ride; shown only when [kPlaybackUnlock] is on.
  final VoidCallback? onUnlock;

  /// Height of the buttons (56 in portrait, 52 in landscape).
  final double height;

  void _export(RideExportDestination destination) =>
      onExport(destination, position.value.position.inMilliseconds);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RideExportProgress?>(
      valueListenable: exportProgress,
      builder: (context, export, _) {
        if (export != null && export.rideKey == rideKey) {
          return _StopExportButton(
            progress: export,
            height: height,
            onPressed: onStopExport,
          );
        }
        final unlock = onUnlock;
        return Row(
          children: [
            Expanded(
              flex: 23,
              child: _ActionButton(
                label: 'Export',
                semanticsLabel: 'Export to folder',
                icon: Icons.drive_folder_upload_outlined,
                filled: true,
                height: height,
                onPressed: enabled
                    ? () => _export(RideExportDestination.folder)
                    : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 20,
              child: _ActionButton(
                label: 'Share',
                semanticsLabel: 'Share',
                icon: Icons.share_outlined,
                height: height,
                onPressed: enabled
                    ? () => _export(RideExportDestination.share)
                    : null,
              ),
            ),
            if (kPlaybackUnlock && unlock != null) ...[
              const SizedBox(width: 8),
              Expanded(
                flex: 20,
                child: _ActionButton(
                  label: 'Unlock',
                  semanticsLabel: 'Unlock this clip',
                  icon: Icons.lock_open,
                  height: height,
                  accent: MotoColors.lock,
                  onPressed: unlock,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.semanticsLabel,
    required this.icon,
    required this.height,
    required this.onPressed,
    this.filled = false,
    this.accent = MotoColors.text,
  });

  final String label;
  final String semanticsLabel;
  final IconData icon;
  final double height;
  final VoidCallback? onPressed;
  final bool filled;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final foreground = filled
        ? (enabled ? MotoColors.bg : MotoColors.muted)
        : (enabled ? accent : MotoColors.disabled);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(MotoRadii.md),
      side: filled
          ? BorderSide.none
          : BorderSide(
              color: enabled
                  ? (accent == MotoColors.text ? MotoColors.disabled : accent)
                  : MotoColors.hairlineStrong,
              width: 1.5,
            ),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticsLabel,
      excludeSemantics: true,
      onTap: onPressed,
      child: Material(
        color: filled
            ? (enabled ? MotoColors.text : MotoColors.surfaceTop)
            : Colors.transparent,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: height),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 20, color: foreground),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MotoFonts.bodyStyle(
                        16,
                        weight: FontWeight.w600,
                        color: foreground,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StopExportButton extends StatelessWidget {
  const _StopExportButton({
    required this.progress,
    required this.height,
    required this.onPressed,
  });

  final RideExportProgress progress;
  final double height;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = progress.total > 0
        ? 'Exporting ${progress.done} of ${progress.total}, stop'
        : 'Exporting, stop';
    return Tooltip(
      message: 'Stop export',
      child: Semantics(
        button: true,
        label: 'Stop export. $label',
        excludeSemantics: true,
        onTap: onPressed,
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(MotoRadii.md),
            side: const BorderSide(color: MotoColors.disabled, width: 1.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: height),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        value: progress.fraction,
                        color: MotoColors.text,
                        backgroundColor: MotoColors.hairlineStrong,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: MotoFonts.bodyStyle(
                          15,
                          weight: FontWeight.w600,
                          color: MotoColors.text,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
