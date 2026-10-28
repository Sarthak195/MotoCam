import 'package:flutter/material.dart';

import '../../camera/providers/recordings_migration.dart';

/// One-line banner for the move of rides into private storage: progress
/// ('Moving 3 rides to private storage (2 of 3)') while a run moves files,
/// then the run's summary until the rider dismisses it. Shows nothing
/// otherwise.
class RecordingsMigrationBanner extends StatelessWidget {
  /// Creates the banner for [migration].
  const RecordingsMigrationBanner({super.key, required this.migration});

  /// The migration state to show.
  final RecordingsMigrationController migration;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: migration,
      builder: (context, _) {
        final banner = migration.bannerText;
        final notice = migration.notice;
        if (banner == null && notice == null) {
          return const SizedBox.shrink();
        }
        final progress = migration.progress;
        final theme = Theme.of(context);
        return Material(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      banner != null
                          ? Icons.drive_file_move_outline
                          : Icons.info_outline,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        banner ?? notice!,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (banner == null)
                      IconButton(
                        tooltip: 'Dismiss',
                        iconSize: 18,
                        visualDensity: VisualDensity.compact,
                        onPressed: migration.dismissNotice,
                        icon: const Icon(Icons.close),
                      )
                    else
                      const SizedBox(width: 8),
                  ],
                ),
                if (banner != null && progress != null && progress.total > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, right: 8),
                    child: LinearProgressIndicator(
                      value: progress.done / progress.total,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
