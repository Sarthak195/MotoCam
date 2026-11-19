import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/core/theme/app_theme.dart';
import 'package:motocam/core/theme/tokens.dart';
import 'package:motocam/features/recording/recording_screen_logic.dart'
    as logic;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('token contrast (WCAG AA, 4.5:1 for text)', () {
    const surfaces = {
      'bg': MotoColors.bg,
      'surface': MotoColors.surface,
      'surfaceRaised': MotoColors.surfaceRaised,
      'surfaceHigh': MotoColors.surfaceHigh,
    };

    for (final surface in surfaces.entries) {
      test('text, dim and muted on ${surface.key}', () {
        for (final fg in [MotoColors.text, MotoColors.dim, MotoColors.muted]) {
          expect(
            contrastRatio(fg, surface.value),
            greaterThanOrEqualTo(4.5),
            reason: '$fg on ${surface.key}',
          );
        }
      });
    }

    test('dim text on the highest surface (selected segment area)', () {
      expect(
        contrastRatio(MotoColors.dim, MotoColors.surfaceTop),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrastRatio(MotoColors.text, MotoColors.surfaceTop),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('dark labels on the filled accents (REC, amber, stalled, LOCK, '
        'START)', () {
      for (final fill in [
        MotoColors.rec,
        MotoColors.amber,
        MotoColors.stalled,
        MotoColors.lock,
        MotoColors.text,
      ]) {
        expect(
          contrastRatio(MotoColors.bg, fill),
          greaterThanOrEqualTo(4.5),
          reason: 'bg on $fill',
        );
      }
    });

    test('accent text on bg (LOCKED outline label, amber notes, errors)', () {
      for (final fg in [MotoColors.lock, MotoColors.amber, MotoColors.rec]) {
        expect(contrastRatio(fg, MotoColors.bg), greaterThanOrEqualTo(4.5));
      }
    });

    test('outlines reach 3:1 against bg (non-text)', () {
      for (final line in [MotoColors.muted, MotoColors.rec, MotoColors.lock]) {
        expect(contrastRatio(line, MotoColors.bg), greaterThanOrEqualTo(3));
      }
    });
  });

  group('recording button colours, now on the tokens', () {
    test('the recording screen keeps today\'s values until R1', () {
      expect(recordingStartButtonColor, const Color(0xFF1976D2));
      expect(recordingStopButtonColor, const Color(0xFFD32F2F));
      expect(recordingButtonLabelColor, const Color(0xFFFFFFFF));
    });

    test('the logic file re-exports the same constants', () {
      expect(logic.recordingStartButtonColor, recordingStartButtonColor);
      expect(logic.recordingStopButtonColor, recordingStopButtonColor);
      expect(logic.recordingButtonLabelColor, recordingButtonLabelColor);
    });

    test('START/STOP button labels reach WCAG AA contrast (4.5:1)', () {
      expect(
        contrastRatio(recordingButtonLabelColor, recordingStartButtonColor),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrastRatio(recordingButtonLabelColor, recordingStopButtonColor),
        greaterThanOrEqualTo(4.5),
      );
    });
  });

  group('app theme', () {
    test('is dark and uses the token colours, not a seed', () {
      final theme = buildAppTheme();
      expect(theme.brightness, Brightness.dark);
      expect(theme.colorScheme, motoColorScheme);
      expect(theme.colorScheme.primary, MotoColors.text);
      expect(theme.colorScheme.surface, MotoColors.bg);
      expect(theme.colorScheme.surfaceContainerHighest, MotoColors.surfaceTop);
      expect(theme.scaffoldBackgroundColor, MotoColors.bg);
      expect(theme.textTheme.bodyLarge?.fontFamily, MotoFonts.body);
      expect(theme.textTheme.headlineMedium?.fontFamily, MotoFonts.condensed);
    });

    test(
      'building it registers the font licence (the app startup path)',
      () async {
        buildAppTheme();
        final packages = await LicenseRegistry.licenses
            .expand((entry) => entry.packages)
            .toList();
        expect(packages, containsAll(<String>['Barlow', 'Barlow Condensed']));
      },
    );

    test('sets every component theme the plan names', () {
      final theme = buildAppTheme();
      expect(theme.segmentedButtonTheme.style, isNotNull);
      expect(theme.switchTheme.trackColor, isNotNull);
      expect(theme.listTileTheme.textColor, MotoColors.text);
      expect(theme.bottomSheetTheme.backgroundColor, MotoColors.surfaceRaised);
      expect(theme.dialogTheme.backgroundColor, MotoColors.surfaceRaised);
      expect(theme.popupMenuTheme.color, MotoColors.surfaceRaised);
      expect(theme.snackBarTheme.backgroundColor, MotoColors.surfaceHigh);
      expect(theme.filledButtonTheme.style, isNotNull);
      expect(theme.outlinedButtonTheme.style, isNotNull);
    });
  });
}
