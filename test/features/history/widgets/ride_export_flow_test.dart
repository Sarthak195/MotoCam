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
    const wholeRideData =
        'The ride data covers the whole ride, including the route outside '
        'this section.';

    /// A ride of [segments] (in /r/) with a timeline of one-minute clips
    /// from 14:00 when [timed], [locked] clips and [incidents].
    RideRecord makeRide(
      List<String> segments, {
      bool timed = false,
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

    Future<RideExportChoice? Function()> openSection(
      WidgetTester tester, {
      RideExportPlan? allPlan,
      RideExportSection? initialSection,
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
                    destination: RideExportDestination.folder,
                    evidence: evidence,
                    all: allPlan ?? all,
                    hasRideData: true,
                    initialSection: initialSection,
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

    Future<void> slide(WidgetTester tester, double first, double last) async {
      tester.widget<RangeSlider>(find.byType(RangeSlider)).onChanged!(
        RangeValues(first, last),
      );
      await tester.pumpAndSettle();
    }

    Future<void> export(WidgetTester tester) async {
      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
    }

    testWidgets('it starts as the whole ride, with its count and size, and '
        'says the ride data covers the whole ride', (tester) async {
      final result = await openSection(tester);

      expect(find.byType(RangeSlider), findsNothing);
      await pickSection(tester);
      final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
      expect(slider.values, const RangeValues(1, 3));
      expect(slider.min, 1);
      expect(slider.max, 3);
      expect(slider.divisions, 2);
      expect(
        find.text('Clips 1 to 3 of 3, 3 clips, ${formatFileSize(6000000)}'),
        findsOneWidget,
      );
      expect(find.text(wholeRideData), findsOneWidget);

      await tester.tap(find.text('Include ride data'));
      await tester.pumpAndSettle();
      expect(find.text(wholeRideData), findsNothing);

      await export(tester);
      expect(result()?.clips, RideExportClips.section);
      expect(result()?.section, const RideExportSection(1, 3));
      expect(result()?.includeRideData, isFalse);
    });

    testWidgets('moving the handles updates the label and the choice', (
      tester,
    ) async {
      final result = await openSection(tester);
      await pickSection(tester);

      await slide(tester, 2, 3);
      expect(
        find.text('Clips 2 to 3 of 3, 2 clips, ${formatFileSize(5000000)}'),
        findsOneWidget,
      );
      await slide(tester, 2, 2);
      expect(
        find.text('Clip 2 of 3, 1 clip, ${formatFileSize(2000000)}'),
        findsOneWidget,
      );
      await export(tester);
      expect(result()?.section, const RideExportSection(2, 2));
    });

    testWidgets('from Playback it starts at the clip under the playhead', (
      tester,
    ) async {
      final result = await openSection(
        tester,
        initialSection: const RideExportSection(3, 3),
      );
      await pickSection(tester);

      expect(
        tester.widget<RangeSlider>(find.byType(RangeSlider)).values,
        const RangeValues(3, 3),
      );
      expect(
        find.text('Clip 3 of 3, 1 clip, ${formatFileSize(3000000)}'),
        findsOneWidget,
      );
      await export(tester);
      expect(result()?.section, const RideExportSection(3, 3));
    });

    testWidgets('a start outside the ride falls back to the whole ride', (
      tester,
    ) async {
      await openSection(tester, initialSection: const RideExportSection(2, 7));
      await pickSection(tester);
      expect(
        tester.widget<RangeSlider>(find.byType(RangeSlider)).values,
        const RangeValues(1, 3),
      );
    });

    testWidgets('a missing clip counts for neither the count nor the size', (
      tester,
    ) async {
      await openSection(
        tester,
        allPlan: allOf(ride, <RideExportItem>[
          clip('a.mp4', 1000000),
          clip('c.mp4', 3000000),
        ]),
      );
      await pickSection(tester);
      expect(
        find.text('Clips 1 to 3 of 3, 2 clips, ${formatFileSize(4000000)}'),
        findsOneWidget,
      );
      await slide(tester, 2, 2);
      expect(find.text('Clip 2 of 3, 0 clips, 0 B'), findsOneWidget);
    });

    testWidgets('with a timeline it shows ride times and lock and incident '
        'marks', (tester) async {
      final record = makeRide(
        <String>['a.mp4', 'b.mp4', 'c.mp4'],
        timed: true,
        locked: <String>['b.mp4'],
        incidents: <int>[150000],
      );
      await openSection(
        tester,
        allPlan: allOf(record, <RideExportItem>[
          clip('a.mp4', 1000000),
          clip('b.mp4', 2000000),
          clip('c.mp4', 3000000),
        ]),
      );
      await pickSection(tester);

      expect(
        find.text(
          'Clips 1 to 3 of 3 (14:00 to 14:02), 3 clips, '
          '${formatFileSize(6000000)}',
        ),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Locked clip 2'), findsOneWidget);
      expect(find.bySemanticsLabel('Incident in clip 3'), findsOneWidget);
      await slide(tester, 2, 3);
      expect(
        find.text(
          'Clips 2 to 3 of 3 (14:01 to 14:02), 2 clips, '
          '${formatFileSize(5000000)}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('without a timeline it shows no marks', (tester) async {
      final record = makeRide(
        <String>['a.mp4', 'b.mp4'],
        locked: <String>['b.mp4'],
        incidents: <int>[1000],
      );
      await openSection(
        tester,
        allPlan: allOf(record, <RideExportItem>[clip('a.mp4', 1000000)]),
      );
      await pickSection(tester);
      expect(find.byIcon(Icons.lock), findsNothing);
      expect(find.byIcon(Icons.warning_amber), findsNothing);
    });

    testWidgets('a ride of one clip has no section option', (tester) async {
      await openSection(
        tester,
        allPlan: allOf(makeRide(<String>['a.mp4']), <RideExportItem>[
          clip('a.mp4', 1000000),
        ]),
      );
      expect(find.text(sectionTitle), findsNothing);
      expect(find.byType(RadioListTile<RideExportClips>), findsNWidgets(2));
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
