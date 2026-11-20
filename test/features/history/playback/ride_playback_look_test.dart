import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/theme/app_theme.dart';
import 'package:motocam/core/theme/tokens.dart';
import 'package:motocam/features/camera/providers/camera_provider.dart';
import 'package:motocam/features/history/models/ride_record.dart';
import 'package:motocam/features/history/services/ride_export.dart';
import 'package:motocam/features/history/services/ride_integrity_text.dart';
import 'package:motocam/features/history/widgets/playback_legend.dart';
import 'package:motocam/features/history/widgets/playback_position.dart';
import 'package:motocam/features/history/widgets/playback_ride_panel.dart';
import 'package:motocam/features/history/widgets/playback_seekbar_track_shape.dart';
import 'package:motocam/features/history/widgets/playback_timeline.dart';
import 'package:motocam/features/history/widgets/ride_playback_body.dart';
import 'package:motocam/features/telemetry/models/telemetry_data.dart';

import '../../../core/ui/kit_harness.dart' show expectTextContrast;
import '../../../support/load_fonts.dart';
import '../widgets/ride_list_fixtures.dart';

const Map<String, Size> _surfaces = {
  'portrait 390x844': Size(390, 844),
  'landscape 844x390': Size(844, 390),
};

const String _rideKey = '/r/ride_x.telemetry.json';

/// Every kind of range and marker at once: the worst case for the legend.
const PlaybackTimelineMarks _allMarks = PlaybackTimelineMarks(
  noVideoRanges: [PlaybackRange(startMs: 0, endMs: 20000)],
  missingRanges: [PlaybackRange(startMs: 60000, endMs: 120000)],
  failedCheckRanges: [PlaybackRange(startMs: 180000, endMs: 240000)],
  incidentMarkerMs: [300000],
  lockMarkerMs: [90000, 400000],
  clipEdgeMs: [120000, 240000, 360000, 480000],
);

List<TelemetryData> _samples(int count) => [
  for (var i = 0; i < count; i++)
    TelemetryData(
      latitude: 28.6 + i * 0.0001,
      longitude: 77.2 + i * 0.0001,
      speed: i % 90,
      bearing: 0,
      accelerationG: 0,
      elapsedMs: i * 1000,
      distanceKm: i / 1000,
      timestamp: DateTime.utc(2026, 1, 1).add(Duration(seconds: i)),
    ),
];

class _Harness {
  _Harness({bool exporting = false, this.actionsEnabled = true})
    : progress = ValueNotifier<RideExportProgress?>(
        exporting
            ? const RideExportProgress(
                rideKey: _rideKey,
                done: 2,
                total: 4,
                destination: RideExportDestination.folder,
              )
            : null,
      );

  final List<TelemetryData> samples = _samples(600);
  final ValueNotifier<PlaybackPosition> position =
      ValueNotifier<PlaybackPosition>(PlaybackPosition.zero);
  final ValueNotifier<bool> fullscreen = ValueNotifier<bool>(false);
  final ValueNotifier<bool> showBody = ValueNotifier<bool>(true);
  final ValueNotifier<RideExportProgress?> progress;
  final bool actionsEnabled;
  final List<String> calls = <String>[];

  Duration get total => Duration(milliseconds: samples.last.elapsedMs);

  Widget build({double textScale = 1}) {
    return MaterialApp(
      theme: buildAppTheme(),
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: showBody,
            builder: (context, show, _) => !show
                ? const SizedBox.shrink()
                : ValueListenableBuilder<bool>(
                    valueListenable: fullscreen,
                    builder: (context, isFullscreen, _) => RidePlaybackBody(
                      video: const SizedBox.expand(
                        key: ValueKey('video'),
                        child: ColoredBox(color: Colors.black),
                      ),
                      samples: samples,
                      maxSpeed: 89,
                      sampleAt: (p) =>
                          samples[p.inSeconds.clamp(0, samples.length - 1)],
                      position: position,
                      totalDuration: total,
                      marks: _allMarks,
                      isFullscreen: isFullscreen,
                      showRouteMap: true,
                      segmentNumber: 2,
                      segmentCount: 12,
                      header: (context, landscape) => PlaybackHeader(
                        title: '13 Nov 2025, 13:21',
                        subtitle: '1 h 52 min, 4.8 GB, 10 of 12 clips',
                        compact: landscape,
                        onBack: () => calls.add('back'),
                      ),
                      integrity: (context, landscape) => PlaybackIntegrityStrip(
                        badge: playbackIntegrityBadgeFor(
                          hasTelemetry: true,
                          status: RideIntegrityStatus.verified,
                          signedBy: RideSignedBy.thisDevice,
                          mockLocation: true,
                          failedVideoCount: 0,
                          rideReadFailed: false,
                          integrityLine: 'Integrity: ride data unmodified',
                        ),
                        showCheck: true,
                        isChecking: true,
                        onCheck: () => calls.add('check'),
                        stacked: landscape,
                      ),
                      actions: (context, landscape) => PlaybackRideActions(
                        position: position,
                        exportProgress: progress,
                        rideKey: _rideKey,
                        enabled: actionsEnabled,
                        height: landscape ? 52 : 56,
                        onExport: (destination, playheadMs) =>
                            calls.add('export ${destination.name} $playheadMs'),
                        onStopExport: () => calls.add('stop'),
                        onUnlock: () => calls.add('unlock'),
                      ),
                      tripReport: (context, landscape) =>
                          const Text('Trip report'),
                      onToggleFullscreen: () =>
                          fullscreen.value = !fullscreen.value,
                      onToggleRouteMap: () {},
                      onSeek: (_) {},
                      onSeekBy: (_) {},
                      onTogglePlay: () {},
                      onScrubStart: () {},
                      onScrubUpdate: (_) {},
                      onGraphScrubEnd: (_) {},
                      onSeekbarScrubEnd: (_, _) {},
                      mapBuilder: (context, samples, height, sample) =>
                          SizedBox(height: height, child: const Text('map')),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  void dispose() {
    position.dispose();
    fullscreen.dispose();
    showBody.dispose();
    progress.dispose();
  }
}

Future<_Harness> _pump(
  WidgetTester tester,
  Size size, {
  double textScale = 1,
  bool exporting = false,
  bool actionsEnabled = true,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final harness = _Harness(
    exporting: exporting,
    actionsEnabled: actionsEnabled,
  );
  addTearDown(harness.dispose);
  await tester.pumpWidget(harness.build(textScale: textScale));
  await tester.pump();
  return harness;
}

void main() {
  setUpAll(loadBundledFonts);

  group('layout', () {
    for (final entry in _surfaces.entries) {
      for (final scale in <double>[1, 1.3]) {
        for (final exporting in <bool>[false, true]) {
          testWidgets('no overflow at ${entry.key}, text x$scale'
              '${exporting ? ', while exporting' : ''}', (tester) async {
            await _pump(
              tester,
              entry.value,
              textScale: scale,
              exporting: exporting,
            );
            expect(tester.takeException(), isNull);
            // Scroll every pane to its end so each part is laid out.
            for (final scrollable
                in find.byType(SingleChildScrollView).evaluate().toList()) {
              await tester.drag(
                find.byWidget(scrollable.widget),
                const Offset(0, -1500),
              );
              await tester.pump();
            }
            expect(tester.takeException(), isNull);
          });
        }
      }
    }

    testWidgets('portrait stacks the header, the video and the actions', (
      tester,
    ) async {
      await _pump(tester, const Size(390, 844));
      final title = tester.getCenter(find.text('13 Nov 2025, 13:21'));
      final video = tester.getCenter(find.byKey(const ValueKey('video')));
      final export = tester.getCenter(find.text('Export'));
      expect(title.dy, lessThan(video.dy));
      expect(video.dy, lessThan(export.dy));
      // The actions are pinned under the scrolling pane, not inside it.
      expect(
        find.ancestor(
          of: find.text('Export'),
          matching: find.byType(SingleChildScrollView),
        ),
        findsNothing,
      );
      expect(find.text('Clip 2 of 12'), findsOneWidget);
    });

    testWidgets('landscape puts the video left and a scrolling pane right', (
      tester,
    ) async {
      await _pump(tester, const Size(844, 390));
      final video = tester.getRect(find.byKey(const ValueKey('video')));
      final title = tester.getRect(find.text('13 Nov 2025, 13:21'));
      expect(video.right, lessThan(title.left));
      expect(video.width, greaterThan(844 * 0.5));
      for (final text in [
        '13 Nov 2025, 13:21',
        'Simulated GPS',
        'Speed, km/h',
        'Export',
      ]) {
        expect(
          find.ancestor(
            of: find.text(text),
            matching: find.byType(SingleChildScrollView),
          ),
          findsOneWidget,
          reason: '$text is in the right pane',
        );
      }
      // The video, the timeline and the legend stay put on the left.
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('video')),
          matching: find.byType(Scrollable),
        ),
        findsNothing,
      );
      expect(
        find.ancestor(
          of: find.byType(PlaybackLegend),
          matching: find.byType(Scrollable),
        ),
        findsNothing,
      );
      expect(find.byType(Slider), findsOneWidget);
      expect(tester.getCenter(find.byType(Slider)).dx, lessThan(title.left));

      final pane = tester.state<ScrollableState>(
        find
            .ancestor(
              of: find.text('Export'),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(pane.position.maxScrollExtent, greaterThan(0));
    });
  });

  group('timeline and legend', () {
    testWidgets('the legend names every kind of range and marker', (
      tester,
    ) async {
      await _pump(tester, const Size(390, 844));
      for (final label in [
        'Incident',
        'Locked',
        'Clip edge',
        'No video',
        'Missing segment',
        'Failed integrity check',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    for (final entry in _surfaces.entries) {
      testWidgets('the timeline draws every range, marker and clip edge at '
          '${entry.key}', (tester) async {
        await _pump(tester, entry.value);
        final slider = tester.renderObject(find.byType(Slider));
        expect(
          slider,
          paints
            ..rect(color: noVideoColor.withValues(alpha: 0.86))
            ..rect(color: missingFootageColor.withValues(alpha: 0.86))
            ..rect(color: failedCheckColor.withValues(alpha: 0.86))
            ..line(color: MotoColors.bg)
            ..line(color: clipEdgeColor)
            ..path(color: lockMarkerColor)
            ..path(color: lockMarkerColor)
            ..path(color: incidentMarkerColor),
        );
      });
    }
  });

  group('ride actions', () {
    testWidgets('Export and Share pass the playhead at the press', (
      tester,
    ) async {
      final harness = await _pump(tester, const Size(390, 844));
      harness.position.value = const PlaybackPosition(
        position: Duration(milliseconds: 123456),
      );
      await tester.pump();
      await tester.tap(find.text('Export'));
      harness.position.value = const PlaybackPosition(
        position: Duration(milliseconds: 200500),
        isPlaying: true,
      );
      await tester.pump();
      await tester.tap(find.text('Share'));
      expect(harness.calls, ['export folder 123456', 'export share 200500']);
      expect(find.bySemanticsLabel('Export to folder'), findsOneWidget);
    });

    testWidgets('disabled actions start nothing', (tester) async {
      final harness = await _pump(
        tester,
        const Size(390, 844),
        actionsEnabled: false,
      );
      await tester.tap(find.text('Export'));
      await tester.tap(find.text('Share'));
      expect(harness.calls, isEmpty);
    });

    testWidgets('an export of this ride shows a ring that stops it', (
      tester,
    ) async {
      final harness = await _pump(
        tester,
        const Size(390, 844),
        exporting: true,
      );
      expect(find.text('Export'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      await tester.tap(find.byTooltip('Stop export'));
      expect(harness.calls, ['stop']);

      // Another ride's export leaves the actions alone.
      harness.progress.value = const RideExportProgress(
        rideKey: '/r/other.telemetry.json',
        done: 1,
        total: 3,
        destination: RideExportDestination.share,
      );
      await tester.pump();
      expect(find.text('Export'), findsOneWidget);
    });

    testWidgets('hidden flags leave nothing: no Unlock, no Trip report', (
      tester,
    ) async {
      for (final size in _surfaces.values) {
        await _pump(tester, size);
        expect(find.text('Unlock'), findsNothing);
        expect(find.bySemanticsLabel('Unlock this clip'), findsNothing);
        expect(find.text('Trip report'), findsNothing);
      }
    });
  });

  group('integrity strip', () {
    PlaybackIntegrityBadge badge({
      bool hasTelemetry = true,
      RideIntegrityStatus status = RideIntegrityStatus.verified,
      RideSignedBy signedBy = RideSignedBy.thisDevice,
      bool mock = false,
      int failed = 0,
      bool readFailed = false,
    }) => playbackIntegrityBadgeFor(
      hasTelemetry: hasTelemetry,
      status: status,
      signedBy: signedBy,
      mockLocation: mock,
      failedVideoCount: failed,
      rideReadFailed: readFailed,
      integrityLine: 'Integrity: line',
    );

    test('the shield only when nothing says otherwise', () {
      expect(badge().kind, PlaybackIntegrityKind.signedHere);
      expect(badge().label, 'Signed on this phone');
      expect(badge().detail, 'Integrity: line.');
      expect(
        badge(signedBy: RideSignedBy.otherKey).kind,
        PlaybackIntegrityKind.unmodified,
      );
      expect(badge(mock: true).kind, PlaybackIntegrityKind.simulatedGps);
      expect(badge(readFailed: true).kind, PlaybackIntegrityKind.notAvailable);
      expect(badge(status: RideIntegrityStatus.unknown).label, 'Unsigned');
      expect(badge(hasTelemetry: false).kind, PlaybackIntegrityKind.videoOnly);
    });

    test('a ride badge carries the shared integrity sentence', () {
      final ride = listRide(mock: true);
      final result = playbackIntegrityBadge(
        ride: ride,
        failedVideoCount: 0,
        rideReadFailed: false,
      );
      expect(result.kind, PlaybackIntegrityKind.simulatedGps);
      expect(result.detail, startsWith(rideIntegrityLine(ride)));
    });

    test('a failed check always wins and says how many videos', () {
      final failed = badge(failed: 2, mock: true);
      expect(failed.kind, PlaybackIntegrityKind.checkFailed);
      expect(failed.label, 'Check failed');
      expect(failed.detail, contains('2 videos could not be confirmed'));
      expect(
        badge(status: RideIntegrityStatus.modified).kind,
        PlaybackIntegrityKind.checkFailed,
      );
      expect(
        badge(hasTelemetry: false, failed: 1).kind,
        PlaybackIntegrityKind.checkFailed,
      );
    });

    Future<void> pumpStrip(
      WidgetTester tester, {
      required bool showCheck,
      required bool isChecking,
      VoidCallback? onCheck,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: PlaybackIntegrityStrip(
              badge: badge(),
              showCheck: showCheck,
              isChecking: isChecking,
              onCheck: onCheck,
            ),
          ),
        ),
      );
    }

    testWidgets('Check videos again: shown with hashes, spinner, disabled', (
      tester,
    ) async {
      var checks = 0;
      await pumpStrip(
        tester,
        showCheck: true,
        isChecking: false,
        onCheck: () => checks++,
      );
      await tester.tap(find.text('Check videos again'));
      expect(checks, 1);
      expect(
        find.bySemanticsLabel(RegExp('^Signed on this phone')),
        findsOneWidget,
      );

      await pumpStrip(tester, showCheck: true, isChecking: true);
      expect(find.text('Checking videos'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );

      await pumpStrip(tester, showCheck: false, isChecking: false);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.text('Signed on this phone'), findsOneWidget);
    });
  });

  group('accessibility', () {
    for (final entry in _surfaces.entries) {
      testWidgets('tap targets and text contrast at ${entry.key}', (
        tester,
      ) async {
        await _pump(tester, entry.value);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        expectTextContrast(tester);
      });
    }

    testWidgets('the play button reads as a button', (tester) async {
      await _pump(tester, const Size(390, 844));
      final handle = tester.ensureSemantics();
      expect(
        tester.getSemantics(find.byIcon(Icons.play_arrow_rounded)),
        isSemantics(isButton: true, hasTapAction: true, tooltip: 'Play'),
      );
      handle.dispose();
    });
  });

  group('fullscreen', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method.startsWith('SystemChrome.setEnabledSystemUI')) {
              calls.add(call);
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    bool isImmersive(MethodCall call) =>
        call.method == 'SystemChrome.setEnabledSystemUIMode' &&
        call.arguments == SystemUiMode.immersiveSticky.toString();

    bool isRestore(MethodCall call) =>
        call.method == 'SystemChrome.setEnabledSystemUIOverlays' &&
        listEquals(call.arguments as List<Object?>, [
          for (final overlay in SystemUiOverlay.values) overlay.toString(),
        ]);

    testWidgets('entering hides the bars and the chrome, exiting restores', (
      tester,
    ) async {
      final harness = await _pump(tester, const Size(390, 844));
      expect(calls, isEmpty);

      await tester.tap(find.byTooltip('Fullscreen'));
      await tester.pump();
      expect(calls, hasLength(1));
      expect(isImmersive(calls.single), isTrue);
      expect(find.byType(Slider), findsNothing);
      expect(find.text('Export'), findsNothing);
      expect(find.text('13 Nov 2025, 13:21'), findsNothing);
      expect(find.text('Tap video to show controls'), findsOneWidget);
      expect(find.byKey(const ValueKey('video')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('video'))),
        const Size(390, 844),
      );

      await tester.tap(find.byTooltip('Exit fullscreen'));
      await tester.pump();
      expect(calls, hasLength(2));
      expect(isRestore(calls.last), isTrue);
      expect(find.byType(Slider), findsOneWidget);
      expect(harness.fullscreen.value, isFalse);
    });

    testWidgets('leaving the screen in fullscreen restores the bars', (
      tester,
    ) async {
      final harness = await _pump(tester, const Size(844, 390));
      harness.fullscreen.value = true;
      await tester.pump();
      expect(isImmersive(calls.single), isTrue);

      harness.showBody.value = false;
      await tester.pump();
      expect(calls, hasLength(2));
      expect(isRestore(calls.last), isTrue);
    });

    testWidgets('leaving the screen outside fullscreen changes nothing', (
      tester,
    ) async {
      final harness = await _pump(tester, const Size(390, 844));
      harness.showBody.value = false;
      await tester.pump();
      expect(calls, isEmpty);
    });
  });
}
