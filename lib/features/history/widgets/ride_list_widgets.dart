// lib/features/history/widgets/ride_list_widgets.dart
//
// The widgets of the Ride History list of redesign A (board A-History): the
// filter chips, the section and month headers, the ride row with its
// stamps, the amber incomplete-ride row, the Ride actions menu and the
// progress ring. Each takes plain values and callbacks; the screen's State
// keeps every flow and guard.

import 'package:flutter/material.dart';

import '../../../core/build_flags.dart';
import '../../../core/theme/tokens.dart';
import 'ride_list_model.dart';

/// Board colours that are not tokens: the menu's fill and outline, and the
/// destructive Delete entry.
const Color _menuFill = Color(0xFF232723);
const Color _menuOutline = Color(0xFF454A44);
const Color _deleteColor = Color(0xFFFF7A62);

/// The actions of the Rides top bar: "Import" (Android: the import from
/// an older version, with that full name as its tooltip; there is no
/// restore yet, so the board's "or restore" is not shown) and the "Check a
/// received export" slot, left out of the tree while
/// [kCheckReceivedExport] is off.
class RideListTopBarActions extends StatelessWidget {
  /// Creates the actions.
  const RideListTopBarActions({
    super.key,
    required this.android,
    required this.onImport,
  });

  /// Whether the import is offered (Android only).
  final bool android;

  /// Starts the import from an older version.
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (android)
          Padding(
            padding: const EdgeInsets.only(right: MotoSize.gap),
            child: Tooltip(
              message: 'Import rides from an older version',
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, MotoSize.minTarget),
                  backgroundColor: MotoColors.surfaceHigh,
                  side: const BorderSide(color: MotoColors.hairlineStrong),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  textStyle: MotoFonts.bodyStyle(15, weight: FontWeight.w600),
                ),
                onPressed: onImport,
                icon: const Icon(Icons.download, size: 20),
                label: const Text('Import'),
              ),
            ),
          ),
        // No checker exists yet: the slot stays out of the tree until the
        // flag is on.
        if (kCheckReceivedExport)
          const IconButton(
            tooltip: 'Check a received export',
            onPressed: null,
            icon: Icon(Icons.fact_check_outlined),
          ),
      ],
    );
  }
}

/// The three in-memory filter chips (Locked, Incidents, Recovered).
class RideFilterBar extends StatelessWidget {
  /// Creates the bar.
  const RideFilterBar({
    super.key,
    required this.selected,
    required this.onToggle,
  });

  /// The chips that are on.
  final Set<RideFilter> selected;

  /// Turns a chip on or off.
  final ValueChanged<RideFilter> onToggle;

  @override
  Widget build(BuildContext context) {
    Widget chip(RideFilter filter, String label, Widget icon) => Expanded(
      child: _FilterChip(
        label: label,
        icon: icon,
        selected: selected.contains(filter),
        onTap: () => onToggle(filter),
      ),
    );
    return Semantics(
      container: true,
      label: 'Filters',
      child: Row(
        children: [
          chip(
            RideFilter.locked,
            'Locked',
            const Icon(Icons.lock_outline, size: 16, color: MotoColors.lock),
          ),
          const SizedBox(width: MotoSize.gap),
          chip(
            RideFilter.incidents,
            'Incidents',
            const Icon(
              Icons.warning_rounded,
              size: 16,
              color: MotoColors.amber,
            ),
          ),
          const SizedBox(width: MotoSize.gap),
          chip(RideFilter.recovered, 'Recovered', const Icon(Icons.restore)),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Widget icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? MotoColors.bg : MotoColors.text;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(MotoSize.minTarget / 2),
      side: BorderSide(
        color: selected ? MotoColors.text : MotoColors.hairlineStrong,
      ),
    );
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: '$label filter',
      child: Material(
        color: selected ? MotoColors.text : MotoColors.surface,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: MotoSize.minTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: ExcludeSemantics(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconTheme(
                      data: IconThemeData(size: 16, color: foreground),
                      child: icon,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: MotoFonts.bodyStyle(
                          15,
                          weight: FontWeight.w500,
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
      ),
    );
  }
}

/// A section title ("Locked Clips", "All Rides") or a month header.
class RideListHeader extends StatelessWidget {
  /// Creates a section title.
  const RideListHeader.section(this.text, {super.key}) : month = false;

  /// Creates a month header.
  const RideListHeader.month(this.text, {super.key}) : month = true;

  /// The text.
  final String text;

  /// Whether this is a month header (small capitals) rather than a
  /// section title.
  final bool month;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Text(
        text,
        style: month
            ? MotoFonts.bodyStyle(
                13,
                letterSpacingEm: 0.08,
                color: MotoColors.dim,
              )
            : MotoFonts.condensedStyle(22, color: MotoColors.text),
      ),
    );
  }
}

/// Colour and icon of a stamp.
({Color color, IconData icon}) _stampLook(RideStampKind kind) => switch (kind) {
  RideStampKind.signedHere => (
    color: MotoColors.text,
    icon: Icons.verified_user,
  ),
  RideStampKind.unmodified => (
    color: MotoColors.text,
    icon: Icons.shield_outlined,
  ),
  RideStampKind.unsigned => (
    color: MotoColors.dim,
    icon: Icons.shield_outlined,
  ),
  RideStampKind.checkFailed => (
    color: MotoColors.rec,
    icon: Icons.gpp_bad_outlined,
  ),
  RideStampKind.simulatedGps => (color: MotoColors.amber, icon: Icons.gps_off),
  RideStampKind.videoOnly => (
    color: MotoColors.dim,
    icon: Icons.videocam_outlined,
  ),
  RideStampKind.videosVerified => (
    color: MotoColors.text,
    icon: Icons.verified_outlined,
  ),
  RideStampKind.quarantined => (color: MotoColors.rec, icon: Icons.block),
  RideStampKind.incomplete => (
    color: MotoColors.amber,
    icon: Icons.broken_image_outlined,
  ),
  RideStampKind.locked => (color: MotoColors.lock, icon: Icons.lock_outline),
  RideStampKind.incidents => (
    color: MotoColors.amber,
    icon: Icons.warning_rounded,
  ),
};

/// The stamps of a ride, wrapped onto more lines when narrow.
class RideStampsView extends StatelessWidget {
  /// Creates the stamps.
  const RideStampsView({super.key, required this.stamps});

  /// The stamps, in order.
  final List<RideStamp> stamps;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: MotoSize.gapWide,
      runSpacing: 4,
      children: [
        for (final stamp in stamps)
          Semantics(
            label: stamp.semanticsLabel,
            child: ExcludeSemantics(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _stampLook(stamp.kind).icon,
                    size: 15,
                    color: _stampLook(stamp.kind).color,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      stamp.label,
                      style: MotoFonts.bodyStyle(
                        13,
                        weight: FontWeight.w500,
                        color: _stampLook(stamp.kind).color,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A ride row: the date and summary, the stamps, optional detail lines,
/// and the trailing slot (the actions menu or a progress ring). Tapping
/// the row opens the ride.
class RideRow extends StatelessWidget {
  /// Creates a row.
  const RideRow({
    super.key,
    required this.dateLabel,
    required this.summary,
    required this.stamps,
    required this.integrityText,
    required this.trailing,
    required this.onOpen,
    this.details = const <String>[],
  });

  /// "13 Nov, 13:21".
  final String dateLabel;

  /// "41 min, 1.7 GB, 6 clips".
  final String summary;

  /// The ride's stamps.
  final List<RideStamp> stamps;

  /// The full integrity sentence, shown on a long press of the stamps.
  final String integrityText;

  /// Short notes kept from the old card (video kept, gallery copies).
  final List<String> details;

  /// The actions menu or a progress ring.
  final Widget trailing;

  /// Opens the ride.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: MotoColors.surface,
      borderRadius: BorderRadius.circular(MotoRadii.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: _RideRowBody(
                    dateLabel: dateLabel,
                    summary: summary,
                    stamps: stamps,
                    integrityText: integrityText,
                    details: details,
                  ),
                ),
                const SizedBox(width: MotoSize.gap),
                trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RideRowBody extends StatelessWidget {
  const _RideRowBody({
    required this.dateLabel,
    required this.summary,
    required this.stamps,
    required this.integrityText,
    required this.details,
  });

  final String dateLabel;
  final String summary;
  final List<RideStamp> stamps;
  final String integrityText;
  final List<String> details;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 10,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            Text(
              dateLabel,
              style: MotoFonts.condensedStyle(
                22,
                color: MotoColors.text,
                tabularFigures: true,
              ),
            ),
            Text(
              summary,
              style: MotoFonts.condensedStyle(
                20,
                weight: FontWeight.w500,
                color: MotoColors.dim,
                tabularFigures: true,
              ),
            ),
          ],
        ),
        if (stamps.isNotEmpty) ...[
          const SizedBox(height: 4),
          Tooltip(
            message: integrityText,
            child: RideStampsView(stamps: stamps),
          ),
        ],
        for (final line in details)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              line,
              style: MotoFonts.bodyStyle(13, color: MotoColors.dim),
            ),
          ),
      ],
    );
  }
}

/// The amber row of an incomplete ride (the app stopped before Stop closed
/// it), in its place in the list: what was saved, the honesty note, the
/// stamps, Open and the actions menu. Keep and Recover last clip wait
/// behind [kRideKeep] and [kRecoverLastClip].
class IncompleteRideRow extends StatelessWidget {
  /// Creates the row.
  const IncompleteRideRow({
    super.key,
    required this.dateLabel,
    required this.text,
    required this.note,
    required this.stamps,
    required this.integrityText,
    required this.trailing,
    required this.onOpen,
    this.details = const <String>[],
  });

  /// "13 Nov, 13:21".
  final String dateLabel;

  /// Short notes kept from the old card (video kept, gallery copies).
  final List<String> details;

  /// "Recording ended without Stop at about 14:02. 41 minutes saved."
  final String text;

  /// The unsigned note, or `null` for a ride with a checked envelope.
  final String? note;

  /// The ride's stamps (without Unsigned when [note] says it).
  final List<RideStamp> stamps;

  /// The full integrity sentence, shown on a long press of the stamps.
  final String integrityText;

  /// The actions menu or a progress ring.
  final Widget trailing;

  /// Opens the ride.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Incomplete ride',
      child: Material(
        color: MotoColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MotoRadii.lg),
          side: const BorderSide(color: MotoColors.amber, width: 2),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.history_toggle_off,
                      size: 18,
                      color: MotoColors.amber,
                    ),
                    const SizedBox(width: MotoSize.gap),
                    Expanded(
                      child: Text(
                        'INCOMPLETE RIDE',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: MotoFonts.bodyStyle(
                          13,
                          weight: FontWeight.w600,
                          letterSpacingEm: 0.08,
                          color: MotoColors.amber,
                        ),
                      ),
                    ),
                    const SizedBox(width: MotoSize.gap),
                    Text(
                      dateLabel,
                      style: MotoFonts.bodyStyle(13, color: MotoColors.dim),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: MotoSize.gap),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  text,
                  style: MotoFonts.bodyStyle(
                    18,
                    weight: FontWeight.w500,
                    height: 1.3,
                    color: MotoColors.text,
                  ),
                ),
              ),
              if (note != null) ...[
                const SizedBox(height: MotoSize.gap),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Icon(
                          Icons.shield_outlined,
                          size: 16,
                          color: MotoColors.dim,
                        ),
                      ),
                      const SizedBox(width: MotoSize.gap),
                      Expanded(
                        child: Text(
                          note!,
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
              if (stamps.isNotEmpty) ...[
                const SizedBox(height: MotoSize.gap),
                Tooltip(
                  message: integrityText,
                  child: RideStampsView(stamps: stamps),
                ),
              ],
              for (final line in details)
                Padding(
                  padding: const EdgeInsets.only(top: 4, right: 8),
                  child: Text(
                    line,
                    style: MotoFonts.bodyStyle(13, color: MotoColors.dim),
                  ),
                ),
              const SizedBox(height: MotoSize.gapWide),
              Row(
                children: [
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, MotoSize.minTarget),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                    ),
                    onPressed: onOpen,
                    child: const Text('Open'),
                  ),
                  // Keep and Recover last clip have no engine yet: their
                  // slots stay out of the tree until the flags are on.
                  if (kRideKeep) ...[
                    const SizedBox(width: MotoSize.gap),
                    const OutlinedButton(onPressed: null, child: Text('Keep')),
                  ],
                  if (kRecoverLastClip) ...[
                    const SizedBox(width: MotoSize.gap),
                    const OutlinedButton(
                      onPressed: null,
                      child: Text('Recover last clip'),
                    ),
                  ],
                  const Spacer(),
                  trailing,
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Label and icon of a menu action.
({String label, IconData icon, Color color}) _menuLook(RideMenuAction action) =>
    switch (action) {
      RideMenuAction.exportFolder => (
        label: 'Export to folder',
        icon: Icons.drive_folder_upload_outlined,
        color: MotoColors.text,
      ),
      RideMenuAction.share => (
        label: 'Share',
        icon: Icons.share_outlined,
        color: MotoColors.text,
      ),
      RideMenuAction.saveToGallery => (
        label: 'Save to gallery',
        icon: Icons.photo_library_outlined,
        color: MotoColors.text,
      ),
      RideMenuAction.removeGalleryCopies => (
        label: 'Remove gallery copies',
        icon: Icons.hide_image_outlined,
        color: MotoColors.text,
      ),
      RideMenuAction.unlock => (
        label: 'Unlock',
        icon: Icons.lock_open,
        color: MotoColors.lock,
      ),
      RideMenuAction.delete => (
        label: 'Delete',
        icon: Icons.delete_outline,
        color: _deleteColor,
      ),
    };

/// The visible label of [action] in the Ride actions menu.
String rideMenuLabel(RideMenuAction action) => _menuLook(action).label;

const Set<RideMenuAction> _shareGroup = <RideMenuAction>{
  RideMenuAction.exportFolder,
  RideMenuAction.share,
  RideMenuAction.saveToGallery,
  RideMenuAction.removeGalleryCopies,
};

/// The Ride actions menu: the "Share and export" group (when present),
/// then Unlock and Delete.
class RideActionsMenu extends StatelessWidget {
  /// Creates the menu button.
  const RideActionsMenu({
    super.key,
    required this.entries,
    required this.onSelected,
  });

  /// The entries, from [rideMenuEntries].
  final List<RideMenuEntry> entries;

  /// Runs a chosen action.
  final ValueChanged<RideMenuAction> onSelected;

  PopupMenuItem<RideMenuAction> _item(RideMenuEntry entry) {
    final look = _menuLook(entry.action);
    final color = entry.enabled ? look.color : MotoColors.muted;
    return PopupMenuItem<RideMenuAction>(
      value: entry.action,
      enabled: entry.enabled,
      child: Row(
        children: [
          Icon(look.icon, size: 20, color: color),
          const SizedBox(width: MotoSize.gapWide),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  look.label,
                  style: MotoFonts.bodyStyle(
                    16,
                    weight: entry.action == RideMenuAction.delete
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: color,
                  ),
                ),
                if (entry.reason != null)
                  Text(
                    entry.reason!,
                    style: MotoFonts.bodyStyle(13, color: MotoColors.dim),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final group = entries.where((e) => _shareGroup.contains(e.action));
    final rest = entries.where((e) => !_shareGroup.contains(e.action));
    return PopupMenuButton<RideMenuAction>(
      tooltip: 'Ride actions',
      color: _menuFill,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MotoRadii.lg),
        side: const BorderSide(color: _menuOutline),
      ),
      icon: const Icon(Icons.more_vert, size: 22, color: MotoColors.dim),
      onSelected: onSelected,
      itemBuilder: (_) => <PopupMenuEntry<RideMenuAction>>[
        if (group.isNotEmpty) ...[
          PopupMenuItem<RideMenuAction>(
            enabled: false,
            height: 28,
            child: Text(
              rideMenuShareGroupTitle,
              style: MotoFonts.bodyStyle(
                12,
                letterSpacingEm: 0.08,
                color: MotoColors.dim,
              ),
            ),
          ),
          for (final entry in group) _item(entry),
          if (rest.isNotEmpty) const PopupMenuDivider(color: _menuOutline),
        ],
        for (final entry in rest) _item(entry),
      ],
    );
  }
}

/// A 48 dp progress ring in a ride row's trailing slot. With [onStop] it
/// is a button with a stop square in the middle (the running export).
class RideProgressRing extends StatelessWidget {
  /// Creates the ring.
  const RideProgressRing({
    super.key,
    required this.value,
    required this.tooltip,
    this.onStop,
  });

  /// Share done (0 to 1), or `null` while unknown.
  final double? value;

  /// What runs, for example "Stop export".
  final String tooltip;

  /// Stops the job; `null` for a ring that cannot stop it.
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final ring = SizedBox.square(
      dimension: 26,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.square(
            dimension: 26,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              value: value,
              color: MotoColors.text,
              backgroundColor: MotoColors.hairlineStrong,
            ),
          ),
          if (onStop != null)
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: MotoColors.text,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
    if (onStop != null) {
      return IconButton(
        tooltip: tooltip,
        onPressed: onStop,
        constraints: const BoxConstraints.tightFor(
          width: MotoSize.minTarget,
          height: MotoSize.minTarget,
        ),
        icon: ring,
      );
    }
    return Tooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: MotoSize.minTarget,
        child: Center(child: ring),
      ),
    );
  }
}
