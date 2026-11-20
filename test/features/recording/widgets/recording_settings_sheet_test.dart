import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motocam/core/diagnostics/diagnostics.dart';
import 'package:motocam/core/providers/app_settings_provider.dart';
import 'package:motocam/features/camera/providers/camera_provider.dart';
import 'package:motocam/features/recording/widgets/recording_settings_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the About and licences entry opens the licence page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = AppSettingsProvider();
    await settings.load();
    final camera = CameraProvider();
    addTearDown(camera.dispose);

    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettingsProvider>.value(value: settings),
          ChangeNotifierProvider<CameraProvider>.value(value: camera),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: RecordingSettingsSheet(
              initialFpsOptions: <int>[30],
              initialCameraOptions: [],
              initialUnsupportedPresets: {},
            ),
          ),
        ),
      ),
    );

    final entry = find.text('About and licences');
    await tester.scrollUntilVisible(
      entry,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('MotoCam'), findsWidgets);
  });

  group('diagnostic log entries', () {
    Future<void> pumpSheet(
      WidgetTester tester, {
      required Future<DiagnosticShareResult> Function() share,
      required Future<bool> Function() clear,
    }) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final settings = AppSettingsProvider();
      await settings.load();
      final camera = CameraProvider();
      addTearDown(camera.dispose);
      await tester.binding.setSurfaceSize(const Size(900, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppSettingsProvider>.value(value: settings),
            ChangeNotifierProvider<CameraProvider>.value(value: camera),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: RecordingSettingsSheet(
                initialFpsOptions: const <int>[30],
                initialCameraOptions: const [],
                initialUnsupportedPresets: const {},
                onShareDiagnosticLog: share,
                onClearDiagnosticLog: clear,
              ),
            ),
          ),
        ),
      );
    }

    Future<void> tapEntry(WidgetTester tester, String label) async {
      final entry = find.text(label);
      await tester.scrollUntilVisible(
        entry,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(entry);
      await tester.pumpAndSettle();
    }

    testWidgets('share asks first, says there is no location, then '
        'shares', (tester) async {
      var shares = 0;
      await pumpSheet(
        tester,
        share: () async {
          shares++;
          return DiagnosticShareResult.shared;
        },
        clear: () async => true,
      );
      await tapEntry(tester, 'Share diagnostic log');
      expect(find.text(diagnosticShareConfirmText), findsOneWidget);
      expect(diagnosticShareConfirmText, contains('no location'));

      await tester.tap(find.text('CANCEL'));
      await tester.pumpAndSettle();
      expect(shares, 0);

      await tapEntry(tester, 'Share diagnostic log');
      await tester.tap(find.text('SHARE'));
      await tester.pumpAndSettle();
      expect(shares, 1);
    });

    testWidgets('an empty log is reported', (tester) async {
      await pumpSheet(
        tester,
        share: () async => DiagnosticShareResult.empty,
        clear: () async => true,
      );
      await tapEntry(tester, 'Share diagnostic log');
      await tester.tap(find.text('SHARE'));
      await tester.pump();
      expect(find.text('The diagnostic log is empty.'), findsOneWidget);
    });

    testWidgets('clear asks first and reports the result', (tester) async {
      var clears = 0;
      await pumpSheet(
        tester,
        share: () async => DiagnosticShareResult.shared,
        clear: () async {
          clears++;
          return true;
        },
      );
      await tapEntry(tester, 'Clear diagnostic log');
      expect(find.text('Clear diagnostic log?'), findsOneWidget);
      await tester.tap(find.text('CLEAR'));
      await tester.pump();
      expect(clears, 1);
      expect(find.text('Diagnostic log cleared.'), findsOneWidget);
    });
  });
}
