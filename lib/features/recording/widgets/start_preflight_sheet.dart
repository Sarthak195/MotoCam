import 'package:flutter/material.dart';

import '../recording_screen_logic.dart';

/// Outcome of one start-preflight check.
enum StartPreflightStatus {
  /// The requirement is met.
  ok,

  /// Recommended but not required; recording can still start.
  warning,

  /// The requirement is not met.
  failed,
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

/// Bottom sheet that lists the start-preflight checks and pops `true` when
/// the rider chooses Start Recording (disabled while [hasBlockingIssue]) or
/// `false` on Cancel.
class StartPreflightSheet extends StatelessWidget {
  /// Checks to display, in order.
  final List<StartPreflightCheck> checks;

  /// Whether any blocking check failed.
  final bool hasBlockingIssue;

  /// Creates the checklist sheet.
  const StartPreflightSheet({
    super.key,
    required this.checks,
    required this.hasBlockingIssue,
  });

  IconData _preflightStatusIcon(StartPreflightStatus status) {
    switch (status) {
      case StartPreflightStatus.ok:
        return Icons.check_circle;
      case StartPreflightStatus.warning:
        return Icons.warning_amber_rounded;
      case StartPreflightStatus.failed:
        return Icons.cancel;
    }
  }

  Color _preflightStatusColor(StartPreflightStatus status) {
    switch (status) {
      case StartPreflightStatus.ok:
        return Colors.lightGreenAccent;
      case StartPreflightStatus.warning:
        return Colors.orangeAccent;
      case StartPreflightStatus.failed:
        return Colors.redAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ready To Record?',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              hasBlockingIssue
                  ? 'Fix blocking checks before recording.'
                  : 'Preflight checks look good. Start when ready.',
              style: TextStyle(
                color: hasBlockingIssue ? Colors.redAccent : Colors.white70,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 340),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: checks.length,
                separatorBuilder: (_, _) => Divider(
                  color: Colors.white.withValues(alpha: 0.08),
                  height: 1,
                ),
                itemBuilder: (context, index) {
                  final check = checks[index];
                  final color = _preflightStatusColor(check.status);
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    leading: Icon(
                      _preflightStatusIcon(check.status),
                      color: color,
                    ),
                    title: Text(
                      check.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      check.detail,
                      style: TextStyle(color: color.withValues(alpha: 0.95)),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.25),
                      ),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: hasBlockingIssue
                        ? null
                        : () => Navigator.of(context).pop(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: recordingStartButtonColor,
                      foregroundColor: recordingButtonLabelColor,
                      disabledBackgroundColor: Colors.grey.shade800,
                    ),
                    child: const Text('Start Recording'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
