// lib/features/recording/widgets/start_preflight_sheet.dart
//
// The START checklist (board A-Checklist): the check model, the rule that
// decides whether it opens, and the full-screen "Ready to record?" page.

import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/ui/kit.dart';
import '../start_preflight_evaluator.dart';

/// Outcome of one start-preflight check.
enum StartPreflightStatus {
  /// The requirement is met.
  ok,

  /// Recommended but not required; recording can still start.
  warning,

  /// The requirement is not met.
  failed,
}

/// The checklist group a check is shown under.
enum StartPreflightGroup {
  /// Camera, microphone and location permissions.
  permissions,

  /// The camera preview and encoder.
  camera,

  /// Writing to the recordings directory.
  storage,

  /// The system location services.
  gps,

  /// Battery saver exemption and battery level.
  battery,

  /// The foreground notification permission.
  notifications,

  /// Automatic crash locking (motion sensor).
  crashDetection,

  /// Phone temperature: drawn as a chip, never as a row.
  heat,

  /// A check without a group; listed under its own title.
  other,
}

/// What a checklist Fix button does. The recording screen maps each kind to
/// its existing handler.
enum StartPreflightFix {
  /// Open the app's system settings page (permissions, notifications).
  appSettings,

  /// Open the system location settings.
  locationServices,

  /// Initialize the camera again.
  retryCamera,

  /// Ask the system to exempt MotoCam from battery optimisation (only on
  /// the rider's tap).
  batteryExemption,
}

/// One row of the start-preflight checklist.
class StartPreflightCheck {
  /// Creates a check row.
  const StartPreflightCheck({
    required this.title,
    required this.detail,
    required this.status,
    required this.isBlocking,
    this.opensSheet = true,
    this.group = StartPreflightGroup.other,
    this.fix,
    this.measurement,
  });

  /// Short name of the check.
  final String title;

  /// Explanation of the current state.
  final String detail;

  /// Result of the check.
  final StartPreflightStatus status;

  /// Whether a [StartPreflightStatus.failed] result prevents recording.
  final bool isBlocking;

  /// Whether a result other than [StartPreflightStatus.ok] opens the sheet
  /// on its own. When `false`, the row is only listed if the sheet opens
  /// for another check.
  final bool opensSheet;

  /// The checklist group the check is shown under.
  final StartPreflightGroup group;

  /// What the Fix button does when the check is not OK; null when the
  /// rider cannot fix it from the checklist.
  final StartPreflightFix? fix;

  /// Short reading for a chip, for example "43.0 C".
  final String? measurement;
}

/// Whether START must show the checklist sheet: a blocking check failed, or
/// a check that is not OK opens the sheet on its own
/// ([StartPreflightCheck.opensSheet]).
bool startPreflightNeedsSheet(Iterable<StartPreflightCheck> checks) {
  return checks.any(
    (check) =>
        (check.isBlocking && check.status == StartPreflightStatus.failed) ||
        (check.opensSheet && check.status != StartPreflightStatus.ok),
  );
}

/// Runs the fix for one checklist row and completes when the rider is back.
typedef StartPreflightFixHandler = Future<void> Function(StartPreflightFix fix);

/// Evaluates the checklist again (after a fix).
typedef StartPreflightRecheck = Future<List<StartPreflightCheck>> Function();

/// Pushes the checklist as a full-screen page and completes with `true`
/// only when the rider tapped START while no blocking check was failing.
///
/// [onFix] runs a row's fix; when it completes, [onRecheck] (if given)
/// replaces the rows, so a fixed blocking item enables START. Without
/// [onFix] no Fix button is drawn. Close, the system back gesture and a
/// blocked START all complete with `false`.
Future<bool> showStartPreflightPage(
  BuildContext context, {
  required List<StartPreflightCheck> checks,
  StartPreflightFixHandler? onFix,
  StartPreflightRecheck? onRecheck,
}) async {
  final proceed = await Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (_) => StartPreflightSheet(
        checks: checks,
        onFix: onFix,
        onRecheck: onRecheck,
      ),
    ),
  );
  return proceed ?? false;
}

/// The "Ready to record?" checklist (board A-Checklist). Pops `true` when
/// the rider taps START (disabled while a blocking check fails) or `false`
/// on Close.
///
/// It fills the screen whether pushed as a page
/// ([showStartPreflightPage]) or shown in a scroll-controlled bottom sheet.
class StartPreflightSheet extends StatefulWidget {
  /// Creates the checklist.
  const StartPreflightSheet({
    super.key,
    required this.checks,
    this.hasBlockingIssue,
    this.onFix,
    this.onRecheck,
  });

  /// Checks to display, in evaluator order.
  final List<StartPreflightCheck> checks;

  /// Kept for the old call site. START follows the current checks instead
  /// ([StartPreflightEvaluator.hasBlockingIssue]), so a fixed item enables
  /// it.
  final bool? hasBlockingIssue;

  /// Runs a row's fix; null draws no Fix buttons.
  final StartPreflightFixHandler? onFix;

  /// Evaluates the checks again after a fix; null keeps the rows as given.
  final StartPreflightRecheck? onRecheck;

  @override
  State<StartPreflightSheet> createState() => _StartPreflightSheetState();
}

class _StartPreflightSheetState extends State<StartPreflightSheet> {
  late List<StartPreflightCheck> _checks;
  bool _fixing = false;

  @override
  void initState() {
    super.initState();
    _checks = widget.checks;
  }

  Future<void> _runFix(StartPreflightFix fix) async {
    final onFix = widget.onFix;
    if (onFix == null || _fixing) {
      return;
    }
    setState(() => _fixing = true);
    try {
      await onFix(fix);
      final recheck = widget.onRecheck;
      if (recheck != null && mounted) {
        final fresh = await recheck();
        if (mounted) {
          _checks = fresh;
        }
      }
    } catch (error) {
      debugPrint('Checklist fix $fix failed: $error');
    } finally {
      if (mounted) {
        setState(() => _fixing = false);
      }
    }
  }

  void _start() {
    if (_fixing || StartPreflightEvaluator.hasBlockingIssue(_checks)) {
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final layout = StartPreflightEvaluator.layout(_checks);
    final blocked = StartPreflightEvaluator.hasBlockingIssue(_checks);
    final heat = layout.heat;

    return Material(
      color: MotoColors.bg,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(MotoSize.gutter),
                  sliver: SliverFillRemaining(
                    hasScrollBody: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Header(
                          onClose: () => Navigator.of(context).pop(false),
                        ),
                        const SizedBox(height: MotoSize.gapWide),
                        if (heat != null) ...[
                          _HeatChip(check: heat),
                          const SizedBox(height: MotoSize.gapWide),
                        ],
                        for (final row in layout.rows) ...[
                          _ChecklistRow(
                            row: row,
                            onFix: widget.onFix == null || row.fix == null
                                ? null
                                : _fixing
                                ? null
                                : () => _runFix(row.fix!),
                            showFix: widget.onFix != null && row.fix != null,
                          ),
                          const SizedBox(height: MotoSize.gap),
                        ],
                        const SizedBox(height: 4),
                        const _ChecklistNote(),
                        const SizedBox(height: MotoSize.gapWide),
                        const Spacer(),
                        _ChecklistStartButton(
                          enabled: !blocked && !_fixing,
                          caption: _startCaption(layout, blocked),
                          onPressed: _start,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _startCaption(StartPreflightLayout layout, bool blocked) {
    if (_fixing) {
      return 'Checking again...';
    }
    if (blocked) {
      final names = <String>[];
      for (final row in layout.rows) {
        if (row.isBlocking && !names.contains(row.title)) {
          names.add(row.title);
        }
      }
      return 'Blocked. Fix ${_joinNames(names)} to start.';
    }
    final open = layout.rows
        .where((row) => row.status != StartPreflightStatus.ok)
        .length;
    if (open == 0) {
      return 'All checks OK.';
    }
    return open == 1
        ? '1 item open. Recording still works.'
        : '$open items open. Recording still works.';
  }

  static String _joinNames(List<String> names) {
    if (names.isEmpty) {
      return 'the blocking items';
    }
    if (names.length == 1) {
      return names.single;
    }
    return '${names.sublist(0, names.length - 1).join(', ')} and '
        '${names.last}';
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              // The phone harness looks for "Ready To Record".
              label: 'Ready To Record?',
              child: ExcludeSemantics(
                child: Text(
                  'Ready to record?',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MotoFonts.condensedStyle(32, color: MotoColors.text),
                ),
              ),
            ),
          ),
          const SizedBox(width: MotoSize.gap),
          Semantics(
            button: true,
            label: 'Close',
            excludeSemantics: true,
            onTap: onClose,
            child: Material(
              color: MotoColors.surfaceHigh,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(MotoRadii.sm)),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onClose,
                child: const SizedBox.square(
                  dimension: MotoSize.minTarget,
                  child: Icon(
                    Icons.close_rounded,
                    size: 22,
                    color: MotoColors.text,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeatChip extends StatelessWidget {
  const _HeatChip({required this.check});

  final StartPreflightCheck check;

  @override
  Widget build(BuildContext context) {
    final hot = check.status != StartPreflightStatus.ok;
    final reading = check.measurement ?? check.detail;
    return Row(
      children: [
        StatusChip(
          variant: hot ? StatusChipVariant.amber : StatusChipVariant.neutral,
          semanticsLabel:
              'Phone temperature ${hot ? 'warm' : 'normal'}, $reading',
          icon: Icons.thermostat_rounded,
          value: reading,
        ),
        const SizedBox(width: MotoSize.gapWide),
        Expanded(
          child: Text(
            hot
                ? 'Warm. Shown as a chip while you ride. It does not block '
                      'START.'
                : 'Phone temperature is normal. It does not block START.',
            style: MotoFonts.bodyStyle(14, color: MotoColors.dim, height: 1.35),
          ),
        ),
      ],
    );
  }
}

class _ChecklistRow extends StatelessWidget {
  const _ChecklistRow({
    required this.row,
    required this.onFix,
    required this.showFix,
  });

  final StartPreflightRow row;
  final VoidCallback? onFix;
  final bool showFix;

  @override
  Widget build(BuildContext context) {
    final ok = row.status == StartPreflightStatus.ok;
    final Widget leading;
    final String statusLabel;
    if (ok) {
      leading = const Icon(Icons.check_circle_rounded, color: MotoColors.text);
      statusLabel = 'OK';
    } else if (row.isBlocking) {
      leading = const Icon(Icons.block_rounded, color: MotoColors.rec);
      statusLabel = 'Blocks START';
    } else {
      leading = const Icon(Icons.warning_rounded, color: MotoColors.amber);
      statusLabel = 'Needs attention';
    }

    final Widget trailing;
    if (!ok && showFix) {
      trailing = _FixButton(title: row.title, onPressed: onFix);
    } else {
      trailing = SizedBox(
        width: 76,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            ok ? 'OK' : (row.isBlocking ? 'Blocked' : 'Note'),
            textAlign: TextAlign.center,
            style: MotoFonts.bodyStyle(
              15,
              color: ok ? MotoColors.dim : MotoColors.text,
              weight: ok ? FontWeight.w400 : FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return Semantics(
      container: true,
      label: '${row.title}, $statusLabel',
      child: InstrumentRow(
        title: row.title,
        subtitle: row.detail,
        attention: !ok,
        leading: SizedBox.square(
          dimension: 26,
          child: FittedBox(child: ExcludeSemantics(child: leading)),
        ),
        trailing: trailing,
      ),
    );
  }
}

class _FixButton extends StatelessWidget {
  const _FixButton({required this.title, required this.onPressed});

  final String title;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: 'Fix $title',
      excludeSemantics: true,
      onTap: onPressed,
      child: SizedBox(
        width: 76,
        height: MotoSize.minTarget,
        child: Material(
          color: enabled ? MotoColors.text : MotoColors.surfaceTop,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(MotoRadii.sm)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Center(
              child: Text(
                'Fix',
                style: MotoFonts.bodyStyle(
                  16,
                  weight: FontWeight.w600,
                  color: enabled ? MotoColors.bg : MotoColors.dim,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChecklistNote extends StatelessWidget {
  const _ChecklistNote();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: MotoColors.surface,
        borderRadius: BorderRadius.circular(MotoRadii.md),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: MotoColors.dim,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'This check opens by itself only for things you can fix now. '
                'Warnings you cannot act on, like heat, are shown here but '
                'do not open it.',
                style: MotoFonts.bodyStyle(
                  14,
                  color: MotoColors.dim,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The checklist's 170 dp START: the ring-and-dot mark and START over a
/// caption. Disabled while a blocking item is open, drawn grey with the
/// caption naming what blocks it.
class _ChecklistStartButton extends StatelessWidget {
  const _ChecklistStartButton({
    required this.enabled,
    required this.caption,
    required this.onPressed,
  });

  final bool enabled;
  final String caption;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final fill = enabled ? MotoColors.text : MotoColors.surfaceTop;
    final foreground = enabled ? MotoColors.bg : MotoColors.dim;
    final captionColor = enabled ? const Color(0xFF3A3E39) : MotoColors.text;
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      // The phone harness taps the checklist's "Start Recording".
      label: 'Start Recording',
      hint: caption,
      onTap: enabled ? onPressed : null,
      excludeSemantics: true,
      child: SizedBox(
        height: MotoSize.start,
        child: Material(
          color: fill,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(MotoRadii.xl),
            side: enabled
                ? BorderSide.none
                : const BorderSide(
                    color: MotoColors.hairlineStrong,
                    width: 2,
                    strokeAlign: BorderSide.strokeAlignInside,
                  ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? onPressed : null,
            highlightColor: foreground.withValues(alpha: 0.14),
            splashColor: foreground.withValues(alpha: 0.18),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          MotoGlyph(
                            shape: enabled
                                ? MotoGlyphShape.startMark
                                : MotoGlyphShape.ring,
                            size: 60,
                            color: foreground,
                            accent: enabled ? MotoColors.recDot : foreground,
                          ),
                          const SizedBox(width: 18),
                          Text(
                            'START',
                            style: MotoFonts.condensedStyle(
                              72,
                              letterSpacingEm: 0.04,
                              color: foreground,
                              height: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: MotoFonts.bodyStyle(
                      15,
                      weight: FontWeight.w500,
                      color: captionColor,
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
