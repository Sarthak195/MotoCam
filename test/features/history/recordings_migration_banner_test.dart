import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/features/camera/providers/recordings_migration.dart';
import 'package:motocam/features/history/widgets/recordings_migration_banner.dart';

void main() {
  testWidgets('shows nothing, then the summary until dismissed', (
    tester,
  ) async {
    final sep = Platform.pathSeparator;
    final base = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('motocam_banner_'),
    ))!;
    addTearDown(() => base.delete(recursive: true));
    final legacy = '${base.path}${sep}legacy${sep}MotoCam Recordings';
    await tester.runAsync(() async {
      await Directory(legacy).create(recursive: true);
      await File('$legacy${sep}lone.mp4').writeAsString('video');
    });

    final controller = RecordingsMigrationController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RecordingsMigrationBanner(migration: controller)),
      ),
    );
    expect(find.byType(Text), findsNothing);

    await tester.runAsync(() async {
      controller.start(
        RecordingsMigrator(
          recordingsRoot: '${base.path}${sep}support${sep}MotoCam Recordings',
          legacyRoots: <String>[legacy],
          workDirectory: '${base.path}${sep}support${sep}ride_migration',
          freeBytes: (_) async => null,
          reserveBytes: 0,
        ),
      );
      await controller.whenIdle();
    });
    await tester.pump();

    expect(find.text('Moved 1 ride to private storage.'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(find.byType(Text), findsNothing);
  });
}
