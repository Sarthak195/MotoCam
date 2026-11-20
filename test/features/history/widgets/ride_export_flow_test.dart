import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/utils/format_utils.dart';
import 'package:motocam/features/history/models/ride_record.dart';
import 'package:motocam/features/history/services/ride_export.dart';
import 'package:motocam/features/history/widgets/ride_export_flow.dart';

const String _roadUsers =
    'Videos show other road users: share them only for your own records, '
    'the police or your insurer.';
const String _sharedStorage =
    'The folder you pick is shared storage: other apps with media or '
    'storage access, and gallery backups, may see these files.';
const String _shareNote =
    'MotoCam cannot check a share. In messengers send as a document, not as '
    'video, or the video is re-encoded.';
const String _linkable =
    'All exports from this phone carry the same public key, so they can be '
    'linked to each other.';
const String _keepOpen = 'Keep MotoCam open until the export finishes.';

void main() {
  final ride = RideRecord(
    videoPath: '/r/c.mp4',
    segmentPaths: const <String>['/r/a.mp4', '/r/b.mp4', '/r/c.mp4'],
    lockedSegmentPaths: const <String>['/r/b.mp4'],
    createdAt: DateTime(2026, 11, 19),
    telemetryPath: '/r/ride_x.telemetry.json',
    rideSessionId: 'x',
    isSessionComplete: true,
    distanceKm: 0,
    maxSpeedKmh: 0,
    averageSpeedKmh: 0,
    segmentTimeline: const <RideSegmentTimelineEntry>[],
    samples: const [],
    integrity: const RideIntegrityReport.unknown(),
    quarantinedSegmentPaths: const <String>[],
  );
  final source = RideExportSource(ride: ride);

  RideExportItem clip(String name, int bytes) =>
      RideExportItem(sourcePath: '/r/$name', name: name, bytes: bytes);

  RideExportPlan plan(RideExportClips choice, List<RideExportItem> clips) =>
      RideExportPlan(
        source: source,
        clipChoice: choice,
        includeRideData: true,
        folderName: 'MotoCam ride x',
        clips: clips,
        rideData: null,
        notExported: const <RideExportOmission>[],
        unmappedIncidentsMs: const <int>[],
      );

  final evidence = plan(RideExportClips.evidence, <RideExportItem>[
    clip('b.mp4', 2000000),
  ]);
  final all = plan(RideExportClips.all, <RideExportItem>[
    clip('a.mp4', 1000000),
    clip('b.mp4', 2000000),
    clip('c.mp4', 3000000),
  ]);
  final noEvidence = plan(RideExportClips.evidence, const <RideExportItem>[]);

  /// Opens the dialog from a button and returns a getter for what it
  /// popped.
  Future<RideExportChoice? Function()> open(
    WidgetTester tester, {
    RideExportDestination destination = RideExportDestination.folder,
    RideExportPlan? evidencePlan,
    bool hasRideData = true,
  }) async {
    RideExportChoice? popped;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              popped = await showDialog<RideExportChoice>(
                context: context,
                builder: (_) => RideExportDialog(
                  destination: destination,
                  evidence: evidencePlan ?? evidence,
                  all: all,
                  hasRideData: hasRideData,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => popped;
  }

  RadioListTile<RideExportClips> radio(
    WidgetTester tester,
    RideExportClips value,
  ) => tester
      .widgetList<RadioListTile<RideExportClips>>(
        find.byType(RadioListTile<RideExportClips>),
      )
      .firstWhere((tile) => tile.value == value);

  CheckboxListTile checkbox(WidgetTester tester) =>
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));

  testWidgets('a folder export shows both clip choices with count and size, '
      'evidence first, and the folder notes', (tester) async {
    final result = await open(tester);

    expect(find.text('Export ride'), findsOneWidget);
    expect(
      find.text('Locked and incident clips (1, ${formatFileSize(2000000)})'),
      findsOneWidget,
    );
    expect(
      find.text('All clips (3, ${formatFileSize(6000000)})'),
      findsOneWidget,
    );
    expect(radio(tester, RideExportClips.evidence).enabled, isNot(false));
    expect(checkbox(tester).value, isTrue);
    expect(checkbox(tester).onChanged, isNotNull);
    expect(find.text(_roadUsers), findsOneWidget);
    expect(find.text(_sharedStorage), findsOneWidget);
    expect(find.text(_shareNote), findsNothing);
    expect(find.text(_linkable), findsOneWidget);
    expect(find.text(_keepOpen), findsOneWidget);

    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(result()?.clips, RideExportClips.evidence);
    expect(result()?.includeRideData, isTrue);
  });

  testWidgets('with no locked or incident clip, evidence is disabled and all '
      'clips is preselected', (tester) async {
    final result = await open(tester, evidencePlan: noEvidence);

    expect(radio(tester, RideExportClips.evidence).enabled, isFalse);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(result()?.clips, RideExportClips.all);
  });

  testWidgets('a ride without ride data has the checkbox off and disabled, '
      'and no linkability note', (tester) async {
    final result = await open(tester, hasRideData: false);

    expect(checkbox(tester).value, isFalse);
    expect(checkbox(tester).onChanged, isNull);
    expect(find.text(_linkable), findsNothing);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(result()?.includeRideData, isFalse);
  });

  testWidgets('leaving the ride data out drops the linkability note', (
    tester,
  ) async {
    final result = await open(tester);

    await tester.tap(find.text('Include ride data'));
    await tester.pumpAndSettle();
    expect(checkbox(tester).value, isFalse);
    expect(find.text(_linkable), findsNothing);

    await tester.tap(find.text('All clips (3, ${formatFileSize(6000000)})'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(result()?.clips, RideExportClips.all);
    expect(result()?.includeRideData, isFalse);
  });

  testWidgets('a share has its own title, button and note, without the '
      'shared-storage note', (tester) async {
    await open(tester, destination: RideExportDestination.share);

    expect(find.text('Share ride'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Share'), findsOneWidget);
    expect(find.text(_shareNote), findsOneWidget);
    expect(find.text(_sharedStorage), findsNothing);
    expect(find.text(_roadUsers), findsOneWidget);
    expect(find.text(_keepOpen), findsOneWidget);
  });

  group('a section', () {
    const sectionTitle = 'A section of the ride';
    const videoOnly =
        'A section is video only: it carries no ride data and no signature.';

    /// A ride of [segments] (in /r/) with a timeline of clips of 59.8 s
    /// every minute from 14:00 when [timed], [locked] clips and
    /// [incidents].
    RideRecord makeRide(
      List<String> segments, {
      bool timed = true,
      List<String> locked = const <String>[],
      List<int>? incidents,
    }) => RideRecord(
      videoPath: '/r/${segments.last}',
      segmentPaths: <String>[for (final s in segments) '/r/$s'],
      lockedSegmentPaths: <String>[for (final s in locked) '/r/$s'],
      createdAt: DateTime(2026, 11, 19, 14),
      telemetryPath: '/r/ride_y.telemetry.json',
      rideSessionId: 'y',
      isSessionComplete: true,
      distanceKm: 0,
      maxSpeedKmh: 0,
      averageSpeedKmh: 0,
      segmentTimeline: <RideSegmentTimelineEntry>[
        if (timed)
          for (var i = 0; i < segments.length; i++)
            RideSegmentTimelineEntry(
              path: '/r/${segments[i]}',
              startMs: i * 60000,
              endMs: i * 60000 + 59800,
            ),
      ],
      samples: const [],
      integrity: const RideIntegrityReport.unknown(),
      quarantinedSegmentPaths: const <String>[],
      incidents: incidents == null
          ? null
          : <RideIncident>[
              for (final t in incidents) RideIncident(elapsedMs: t),
            ],
    );

    RideExportPlan allOf(RideRecord record, List<RideExportItem> clips) =>
        RideExportPlan(
          source: RideExportSource(ride: record),
          clipChoice: RideExportClips.all,
          includeRideData: true,
          folderName: 'MotoCam ride y (all clips)',
          clips: clips,
          rideData: null,
          notExported: const <RideExportOmission>[],
          unmappedIncidentsMs: const <int>[],
        );

    // a 00:00 to 00:59.8, b 01:00 to 01:59.8, c 02:00 to 02:59.8.
    final timed = allOf(
      makeRide(
        <String>['a.mp4', 'b.mp4', 'c.mp4'],
        locked: <String>['b.mp4'],
        incidents: <int>[150000],
      ),
      <RideExportItem>[
        clip('a.mp4', 1000000),
        clip('b.mp4', 2000000),
        clip('c.mp4', 3000000),
      ],
    );

    /// The estimated size of [ms] of a 59.8 s clip of [bytes].
    int share(int bytes, int ms) => (bytes * ms / 59800).round();

    Future<RideExportChoice? Function()> openSection(
      WidgetTester tester, {
      RideExportPlan? allPlan,
      int? playheadMs,
      RideExportDestination destination = RideExportDestination.folder,
    }) async {
      RideExportChoice? popped;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                popped = await showDialog<RideExportChoice>(
                  context: context,
                  builder: (_) => RideExportDialog(
                    destination: destination,
                    evidence: evidence,
                    all: allPlan ?? timed,
                    hasRideData: true,
                    playheadMs: playheadMs,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return () => popped;
    }

    Future<void> pickSection(WidgetTester tester) async {
      await tester.tap(find.text(sectionTitle));
      await tester.pumpAndSettle();
    }

    Future<void> slide(WidgetTester tester, double from, double to) async {
      tester.widget<RangeSlider>(find.byType(RangeSlider)).onChanged!(
        RangeValues(from, to),
      );
      await tester.pumpAndSettle();
    }

    Future<void> nudge(WidgetTester tester, String end, String step) async {
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey<String>('rideExportSection$end')),
          matching: find.text(step),
        ),
      );
      await tester.pumpAndSettle();
    }

    RangeValues values(WidgetTester tester) =>
        tester.widget<RangeSlider>(find.byType(RangeSlider)).values;

    Future<void> export(WidgetTester tester) async {
      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
    }

    testWidgets('from Ride History it starts as the first minute, video '
        'only, without the ride data checkbox', (tester) async {
      final result = await openSection(tester);

      expect(find.byType(RangeSlider), findsNothing);
      expect(find.text(videoOnly), findsNothing);
      await pickSection(tester);
      final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
      expect(slider.values, const RangeValues(0, 60));
      expect(slider.min, 0);
      expect(slider.max, 180);
      expect(slider.divisions, isNull);
      expect(
        find.text(
          '00:00 to 01:00 (1 min), 1 file, about ${formatFileSize(1000000)}',
        ),
        findsOneWidget,
      );
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.text('Include ride data'), findsNothing);
      expect(find.text(videoOnly), findsOneWidget);
      expect(find.text(_linkable), findsNothing);
      expect(find.text(_sharedStorage), findsOneWidget);

      await export(tester);
      expect(result()?.clips, RideExportClips.section);
      expect(result()?.section, const RideExportSection(0, 60000));
      expect(result()?.includeRideData, isFalse);
    });

    testWidgets('the -1 s and +1 s buttons move each end and keep at least '
        '1 s', (tester) async {
      final result = await openSection(tester);
      await pickSection(tester);

      await nudge(tester, 'End', '+1 s');
      expect(values(tester), const RangeValues(0, 61));
      expect(
        find.text(
          '00:00 to 01:01 (1 min 1 s), 2 files, about '
          '${formatFileSize(1000000 + share(2000000, 1000))}',
        ),
        findsOneWidget,
      );
      await nudge(tester, 'Start', '+1 s');
      expect(
        find.text(
          '00:01 to 01:01 (1 min), 2 files, about '
          '${formatFileSize(share(1000000, 58800) + share(2000000, 1000))}',
        ),
        findsOneWidget,
      );
      await nudge(tester, 'Start', '-1 s');
      await nudge(tester, 'Start', '-1 s');
      expect(values(tester), const RangeValues(0, 61));

      await slide(tester, 88, 89);
      await nudge(tester, 'Start', '+1 s');
      await nudge(tester, 'End', '-1 s');
      await slide(tester, 89, 89);
      expect(values(tester), const RangeValues(88, 89));
      expect(
        find.text(
          '01:28 to 01:29 (1 s), 1 file, about '
          '${formatFileSize(share(2000000, 1000))}',
        ),
        findsOneWidget,
      );
      await nudge(tester, 'Start', '-1 s');
      await export(tester);
      expect(result()?.section, const RideExportSection(87000, 89000));
    });

    testWidgets('from Playback it starts 30 s either side of the playhead, '
        'within the ride', (tester) async {
      final result = await openSection(tester, playheadMs: 90500);
      await pickSection(tester);
      expect(values(tester), const RangeValues(60, 120));
      expect(
        find.text(
          '01:00 to 02:00 (1 min), 1 file, about ${formatFileSize(2000000)}',
        ),
        findsOneWidget,
      );
      await export(tester);
      expect(result()?.section, const RideExportSection(60000, 120000));

      await openSection(tester, playheadMs: 10000);
      await pickSection(tester);
      expect(values(tester), const RangeValues(0, 40));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await openSection(tester, playheadMs: 179000);
      await pickSection(tester);
      expect(values(tester), const RangeValues(149, 180));
      expect(
        find.text(
          '02:29 to 03:00 (31 s), 1 file, about '
          '${formatFileSize(share(3000000, 30800))}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a long range names hours in its length', (tester) async {
      await openSection(
        tester,
        allPlan: allOf(
          makeRide(<String>[for (var i = 0; i < 70; i++) 'c$i.mp4']),
          <RideExportItem>[clip('c0.mp4', 1000000)],
        ),
      );
      await pickSection(tester);
      await slide(tester, 0, 3725);
      expect(
        find.text(
          '00:00 to 62:05 (1 h 2 min 5 s), 1 file, about '
          '${formatFileSize(1000000)}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a missing clip counts for neither the files nor the size', (
      tester,
    ) async {
      await openSection(
        tester,
        allPlan: allOf(timed.source.ride, <RideExportItem>[
          clip('a.mp4', 1000000),
          clip('c.mp4', 3000000),
        ]),
      );
      await pickSection(tester);
      await slide(tester, 0, 180);
      expect(
        find.text(
          '00:00 to 03:00 (3 min), 2 files, about ${formatFileSize(4000000)}',
        ),
        findsOneWidget,
      );
      await slide(tester, 65, 70);
      expect(
        find.text('01:05 to 01:10 (5 s), 0 files, about ${formatFileSize(0)}'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Export'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('it shows lock and incident marks at their ride time', (
      tester,
    ) async {
      await openSection(tester);
      await pickSection(tester);
      expect(find.bySemanticsLabel('Locked clip at 01:00'), findsOneWidget);
      expect(find.bySemanticsLabel('Incident at 02:30'), findsOneWidget);
    });

    testWidgets('a share of a section says it is video only', (tester) async {
      await openSection(tester, destination: RideExportDestination.share);
      await pickSection(tester);
      expect(find.text(videoOnly), findsOneWidget);
      expect(find.text(_shareNote), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNothing);
    });

    testWidgets('a ride without a timeline has no section option', (
      tester,
    ) async {
      await openSection(
        tester,
        allPlan: allOf(
          makeRide(<String>['a.mp4', 'b.mp4'], timed: false),
          <RideExportItem>[clip('a.mp4', 1000000)],
        ),
      );
      expect(find.text(sectionTitle), findsNothing);
      expect(find.byType(RadioListTile<RideExportClips>), findsNWidgets(2));
    });

    testWidgets('a ride of one clip offers a section of it', (tester) async {
      await openSection(
        tester,
        allPlan: allOf(makeRide(<String>['a.mp4']), <RideExportItem>[
          clip('a.mp4', 1000000),
        ]),
      );
      await pickSection(tester);
      expect(values(tester), const RangeValues(0, 60));
    });
  });

  testWidgets('cancel pops nothing', (tester) async {
    final result = await open(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Export ride'), findsNothing);
    expect(result(), isNull);
  });
}
