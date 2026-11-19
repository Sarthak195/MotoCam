// The export dialog in the Instrument look: every note under the
// collapsible "Before you hand this over" section, the section option kept,
// no overflow on either phone surface, and the closing summary without the
// reserved "Open folder".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/theme/app_theme.dart';
import 'package:motocam/features/history/models/ride_record.dart';
import 'package:motocam/features/history/services/ride_export.dart';
import 'package:motocam/features/history/widgets/ride_export_flow.dart';

import '../../../support/load_fonts.dart';

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
const String _sectionTitle = 'A section of the ride';

void main() {
  setUpAll(loadBundledFonts);

  final ride = RideRecord(
    videoPath: '/r/c.mp4',
    segmentPaths: const <String>['/r/a.mp4', '/r/b.mp4', '/r/c.mp4'],
    lockedSegmentPaths: const <String>['/r/b.mp4'],
    createdAt: DateTime(2026, 11, 19, 14),
    telemetryPath: '/r/ride_x.telemetry.json',
    rideSessionId: 'x',
    isSessionComplete: true,
    distanceKm: 0,
    maxSpeedKmh: 0,
    averageSpeedKmh: 0,
    segmentTimeline: <RideSegmentTimelineEntry>[
      for (var i = 0; i < 3; i++)
        RideSegmentTimelineEntry(
          path: '/r/${'abc'[i]}.mp4',
          startMs: i * 60000,
          endMs: i * 60000 + 59800,
        ),
    ],
    samples: const [],
    integrity: const RideIntegrityReport.unknown(),
    quarantinedSegmentPaths: const <String>[],
    incidents: const <RideIncident>[RideIncident(elapsedMs: 150000)],
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

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double textScale = 1,
    RideExportDestination destination = RideExportDestination.folder,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: textScale,
          maxScaleFactor: textScale,
          child: child!,
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<RideExportChoice>(
              context: context,
              builder: (_) => RideExportDialog(
                destination: destination,
                evidence: evidence,
                all: all,
                hasRideData: true,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> toggleNotes(WidgetTester tester) async {
    final header = find.byKey(const ValueKey<String>('rideExportNotesHeader'));
    await tester.ensureVisible(header);
    await tester.pumpAndSettle();
    await tester.tap(header);
    await tester.pumpAndSettle();
  }

  testWidgets('every note sits under Before you hand this over, open when '
      'the dialog opens, and folds away and back', (tester) async {
    await open(tester);
    expect(find.text(rideExportNotesTitle), findsOneWidget);
    final title = tester.getTopLeft(find.text(rideExportNotesTitle)).dy;
    for (final note in <String>[_roadUsers, _sharedStorage, _linkable]) {
      expect(find.text(note), findsOneWidget, reason: note);
      expect(tester.getTopLeft(find.text(note)).dy, greaterThan(title));
    }
    expect(find.text(_keepOpen), findsOneWidget);

    await toggleNotes(tester);
    for (final note in <String>[
      _roadUsers,
      _sharedStorage,
      _linkable,
      _keepOpen,
    ]) {
      expect(find.text(note), findsNothing, reason: note);
    }
    expect(find.text(rideExportNotesTitle), findsOneWidget);

    await toggleNotes(tester);
    for (final note in <String>[
      _roadUsers,
      _sharedStorage,
      _linkable,
      _keepOpen,
    ]) {
      expect(find.text(note), findsOneWidget, reason: note);
    }
  });

  testWidgets('a share keeps its own note in the section', (tester) async {
    await open(tester, destination: RideExportDestination.share);
    expect(find.text(_shareNote), findsOneWidget);
    expect(find.text(_roadUsers), findsOneWidget);
    expect(find.text(_keepOpen), findsOneWidget);
  });

  testWidgets('the section option, its slider, nudges and video-only note '
      'are kept', (tester) async {
    await open(tester);
    expect(find.text('CLIPS'), findsOneWidget);
    expect(find.text(_sectionTitle), findsOneWidget);
    await tester.tap(find.text(_sectionTitle));
    await tester.pumpAndSettle();
    expect(find.byType(RangeSlider), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('rideExportSectionStart')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('rideExportSectionEnd')),
      findsOneWidget,
    );
    expect(
      find.text(
        'A section is video only: it carries no ride data and no signature.',
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Locked clip at 01:00'), findsOneWidget);
    expect(find.bySemanticsLabel('Incident at 02:30'), findsOneWidget);
    // Without ride data the linkability note goes; the others stay.
    expect(find.text(_linkable), findsNothing);
    expect(find.text(_roadUsers), findsOneWidget);
  });

  for (final size in const <Size>[Size(390, 844), Size(844, 390)]) {
    for (final scale in const <double>[1, 1.3]) {
      testWidgets('no overflow at ${size.width.toInt()}x'
          '${size.height.toInt()}, text x$scale', (tester) async {
        await open(tester, size: size, textScale: scale);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text(_sectionTitle));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // The actions stay reachable by scrolling the dialog.
        await tester.ensureVisible(find.text('Export'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  group('the closing summary', () {
    Future<void> show(WidgetTester tester, SnackBar bar) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    ScaffoldMessenger.of(context).showSnackBar(bar),
                child: const Text('show'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
    }

    testWidgets('a clean export has a check mark and no Open folder', (
      tester,
    ) async {
      const text =
          'Exported 4 files (1.6 GB) to "MotoCam ride 2026-11-09 08.14". '
          'All copies checked.';
      final bar = rideExportSummarySnackBar(text: text, success: true);
      expect(bar.duration, const Duration(seconds: 8));
      expect(bar.action, isNull);
      await show(tester, bar);
      expect(find.text(text), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text('Open folder'), findsNothing);
    });

    testWidgets('any other outcome keeps its text with an amber mark', (
      tester,
    ) async {
      const text =
          'Export stopped because a recording started. Run it '
          'again to continue.';
      await show(tester, rideExportSummarySnackBar(text: text, success: false));
      expect(find.text(text), findsOneWidget);
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
      expect(find.text('Open folder'), findsNothing);
    });
  });
}
