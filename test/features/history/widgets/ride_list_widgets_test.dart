import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/theme/app_theme.dart';
import 'package:motocam/core/theme/tokens.dart';
import 'package:motocam/core/utils/format_utils.dart';
import 'package:motocam/features/history/models/ride_record.dart';
import 'package:motocam/features/history/models/segment_verifier.dart';
import 'package:motocam/features/history/services/ride_integrity_text.dart';
import 'package:motocam/features/history/widgets/ride_list_model.dart';
import 'package:motocam/features/history/widgets/ride_list_widgets.dart';

import '../../../support/load_fonts.dart';
import 'ride_list_fixtures.dart';

const Map<String, Size> _surfaces = {
  'portrait 390x844': Size(390, 844),
  'landscape 844x390': Size(844, 390),
};

void main() {
  setUpAll(loadBundledFonts);

  final now = DateTime(2026, 11, 19);

  /// The worst case: every stamp a ride can carry at once.
  final busyRide = listRide(
    clips: 12,
    locked: 3,
    missing: 2,
    quarantined: 2,
    incidents: 4,
    minutes: 112,
    bytes: 4800000000,
    mock: true,
  );
  final incomplete = listRide(complete: false, locked: 3, incidents: 1);
  final videoOnly = listRide(telemetryPath: null, clips: 1);
  final plain = listRide(createdAt: DateTime(2026, 10, 2, 7, 5));

  Widget row(
    RideRecord ride, {
    Widget? trailing,
    VoidCallback? onOpen,
    List<RideMenuEntry>? entries,
    ValueChanged<RideMenuAction>? onSelected,
  }) {
    final stamps = rideStamps(ride, RideVideoCheck.none);
    final menu =
        trailing ??
        RideActionsMenu(
          entries:
              entries ??
              rideMenuEntries(
                android: true,
                isLocked: ride.isLocked,
                canChangeLockState: true,
                isUpdatingLock: false,
                galleryBusy: false,
                exportBusy: false,
                galleryCopies: 1,
              ),
          onSelected: onSelected ?? (_) {},
        );
    if (isIncompleteRideRow(ride)) {
      return IncompleteRideRow(
        dateLabel: rideDateLabel(ride.createdAt, now),
        text: incompleteRideText(ride),
        note: incompleteRideNote(ride),
        stamps: stamps.where((s) => s.kind != RideStampKind.unsigned).toList(),
        integrityText: rideIntegrityLine(ride),
        details: const <String>['Video: 00:30:00 of 00:41:00 kept'],
        trailing: menu,
        onOpen: onOpen ?? () {},
      );
    }
    return RideRow(
      dateLabel: rideDateLabel(ride.createdAt, now),
      summary: rideSummaryText(ride, formatFileSize),
      stamps: stamps,
      integrityText: rideIntegrityLine(ride),
      details: const <String>[
        'Video: 00:40:00 of 00:41:00 kept',
        'Gallery copies: 2 (readable by other apps)',
      ],
      trailing: menu,
      onOpen: onOpen ?? () {},
    );
  }

  /// Pumps the Rides screen's layout: the app bar, the filter chips and
  /// the list, built from the same widgets as the screen.
  Future<void> pumpList(
    WidgetTester tester,
    Size size, {
    double textScale = 1,
    Set<RideFilter> filters = const <RideFilter>{},
    ValueChanged<RideFilter>? onToggle,
    List<RideRecord>? rides,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final items = rideListItems(
      rides ?? <RideRecord>[incomplete, busyRide, videoOnly, plain],
      filters: filters,
      now: now,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: MediaQuery.withClampedTextScaling(
          minScaleFactor: textScale,
          maxScaleFactor: textScale,
          child: Scaffold(
            appBar: AppBar(
              title: Text(
                'Rides',
                style: MotoFonts.condensedStyle(30, color: MotoColors.text),
              ),
              actions: [RideListTopBarActions(android: true, onImport: () {})],
            ),
            body: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: RideFilterBar(
                    selected: filters,
                    onToggle: onToggle ?? (_) {},
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final item in items)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: switch (item) {
                            RideListRide(:final ride) => row(ride),
                            RideSectionHeader(:final title) =>
                              RideListHeader.section(title),
                            RideMonthHeader(:final label) =>
                              RideListHeader.month(label),
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final entry in _surfaces.entries) {
    for (final scale in <double>[1, 1.3]) {
      testWidgets('the list has no overflow at ${entry.key}, text x$scale', (
        tester,
      ) async {
        await pumpList(tester, entry.value, textScale: scale);
        expect(tester.takeException(), isNull);
        // Scroll through every row so each one is laid out.
        await tester.drag(find.byType(ListView), const Offset(0, -2000));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('rows and chips meet the tap-target guideline', (tester) async {
    await pumpList(tester, const Size(390, 844));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  });

  testWidgets('the list shows Locked Clips first and month headers in All '
      'Rides', (tester) async {
    await pumpList(tester, const Size(390, 844));
    final locked = tester.getTopLeft(find.text('Locked Clips'));
    final all = tester.getTopLeft(find.text('All Rides'));
    expect(locked.dy, lessThan(all.dy));
    expect(find.text('NOVEMBER'), findsOneWidget);
    expect(find.text('OCTOBER'), findsOneWidget);
  });

  testWidgets('every honesty stamp is drawn with its accessibility label', (
    tester,
  ) async {
    await pumpList(tester, const Size(390, 844));
    for (final label in <String>[
      'Simulated GPS',
      'Quarantined 2',
      'Incomplete',
      '3 locked',
      '4 incidents',
      'Video only',
    ]) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(
      find.bySemanticsLabel(
        RegExp(
          'Simulated GPS: the location came from a mock location provider',
        ),
      ),
      findsWidgets,
    );
    expect(find.text('Signed on this phone'), findsNothing);
  });

  testWidgets('the incomplete ride is an amber row with Open only', (
    tester,
  ) async {
    var opened = 0;
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: row(incomplete, onOpen: () => opened++)),
      ),
    );
    expect(find.text('INCOMPLETE RIDE'), findsOneWidget);
    expect(
      find.text(
        'Recording ended without Stop at about 14:02. 41 minutes saved, 3 '
        'locked clips.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Unsigned: it was not closed with Stop, so MotoCam cannot prove the '
        'files are unchanged.',
      ),
      findsOneWidget,
    );
    // The video kept line is not lost on the amber row.
    expect(find.text('Video: 00:30:00 of 00:41:00 kept'), findsOneWidget);
    // The note says it, so no Unsigned stamp repeats it.
    expect(find.text('Unsigned'), findsNothing);
    expect(find.text('Keep'), findsNothing);
    expect(find.text('Recover last clip'), findsNothing);
    final border =
        (tester
                    .widget<Material>(
                      find
                          .ancestor(
                            of: find.text('INCOMPLETE RIDE'),
                            matching: find.byType(Material),
                          )
                          .first,
                    )
                    .shape!
                as RoundedRectangleBorder)
            .side;
    expect(border.color, MotoColors.amber);
    await tester.tap(find.text('Open'));
    expect(opened, 1);
  });

  testWidgets('the top bar offers Import (Android) with its full name, and '
      'no Check slot', (tester) async {
    var imports = 0;
    Future<void> pumpBar(bool android) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            appBar: AppBar(
              title: const Text('Rides'),
              actions: [
                RideListTopBarActions(
                  android: android,
                  onImport: () => imports++,
                ),
              ],
            ),
          ),
        ),
      );
    }

    await pumpBar(true);
    expect(find.text('Import'), findsOneWidget);
    expect(
      find.byTooltip('Import rides from an older version'),
      findsOneWidget,
    );
    expect(find.textContaining('restore'), findsNothing);
    expect(find.byTooltip('Check a received export'), findsNothing);
    await tester.tap(find.text('Import'));
    expect(imports, 1);

    await pumpBar(false);
    expect(find.text('Import'), findsNothing);
  });

  testWidgets('a filter chip toggles and reports its state', (tester) async {
    final toggled = <RideFilter>[];
    await pumpList(
      tester,
      const Size(390, 844),
      filters: const <RideFilter>{RideFilter.locked},
      onToggle: toggled.add,
    );
    await tester.tap(find.text('Incidents'));
    expect(toggled, <RideFilter>[RideFilter.incidents]);
    final locked = tester
        .getSemantics(find.bySemanticsLabel('Locked filter'))
        .getSemanticsData();
    final incidents = tester
        .getSemantics(find.bySemanticsLabel('Incidents filter'))
        .getSemanticsData();
    expect(locked.flagsCollection.isButton, true);
    expect(locked.flagsCollection.isSelected, Tristate.isTrue);
    expect(incidents.flagsCollection.isSelected, Tristate.isFalse);
    expect(locked.hasAction(SemanticsAction.tap), true);
    // Only the locked ride is listed under the Locked chip.
    expect(find.text('All Rides'), findsNothing);
  });

  group('the Ride actions menu', () {
    Future<void> openMenu(
      WidgetTester tester, {
      required RideRecord ride,
      required List<RideMenuEntry> entries,
      ValueChanged<RideMenuAction>? onSelected,
    }) async {
      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: row(ride, entries: entries, onSelected: onSelected),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Ride actions'));
      await tester.pumpAndSettle();
    }

    testWidgets('groups Share and export, then Unlock and Delete', (
      tester,
    ) async {
      final chosen = <RideMenuAction>[];
      await openMenu(
        tester,
        ride: busyRide,
        entries: rideMenuEntries(
          android: true,
          isLocked: true,
          canChangeLockState: true,
          isUpdatingLock: false,
          galleryBusy: false,
          exportBusy: false,
          galleryCopies: 2,
        ),
        onSelected: chosen.add,
      );
      final labels = <String>[
        rideMenuShareGroupTitle,
        'Export to folder',
        'Share',
        'Save to gallery',
        'Remove gallery copies',
        'Unlock',
        'Delete',
      ];
      var last = -1.0;
      for (final label in labels) {
        expect(find.text(label), findsOneWidget, reason: label);
        final y = tester.getTopLeft(find.text(label)).dy;
        expect(y, greaterThan(last), reason: label);
        last = y;
      }
      expect(find.text('Trip report'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(chosen, <RideMenuAction>[RideMenuAction.delete]);
    });

    testWidgets('a disabled Unlock shows why and cannot be chosen', (
      tester,
    ) async {
      final chosen = <RideMenuAction>[];
      await openMenu(
        tester,
        ride: busyRide,
        entries: rideMenuEntries(
          android: false,
          isLocked: true,
          canChangeLockState: false,
          isUpdatingLock: false,
          galleryBusy: false,
          exportBusy: false,
          galleryCopies: 0,
        ),
        onSelected: chosen.add,
      );
      expect(find.text(rideMenuShareGroupTitle), findsNothing);
      expect(
        find.text('Integrity warning: lock state changes disabled'),
        findsOneWidget,
      );
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(chosen, isEmpty);
    });
  });

  testWidgets('the export ring stops the export; other rings only show '
      'progress', (tester) async {
    var stops = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Column(
            children: [
              RideProgressRing(
                value: 0.5,
                tooltip: 'Stop export',
                onStop: () => stops++,
              ),
              const RideProgressRing(
                value: null,
                tooltip: 'Checking the videos before unlocking',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Stop export'));
    expect(stops, 1);
    expect(
      find.byTooltip('Checking the videos before unlocking'),
      findsOneWidget,
    );
    expect(find.byType(IconButton), findsOneWidget);
  });
}
