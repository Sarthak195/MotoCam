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

  testWidgets('cancel pops nothing', (tester) async {
    final result = await open(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Export ride'), findsNothing);
    expect(result(), isNull);
  });
}
