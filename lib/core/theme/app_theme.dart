// lib/core/theme/app_theme.dart
//
// The app-wide dark theme of redesign A ("Instrument"). Every colour role is
// set explicitly from the tokens, so no seeded or default Material colour
// leaks into a screen. Component themes set colour, shape and type only;
// sizes, density and behaviour stay at the Material defaults.

import 'package:flutter/material.dart';

import 'font_licence.dart';
import 'tokens.dart';

/// The explicit dark colour scheme built from [MotoColors].
const ColorScheme motoColorScheme = ColorScheme.dark(
  primary: MotoColors.text,
  onPrimary: MotoColors.bg,
  primaryContainer: MotoColors.surfaceTop,
  onPrimaryContainer: MotoColors.text,
  secondary: MotoColors.dim,
  onSecondary: MotoColors.bg,
  secondaryContainer: MotoColors.surfaceHigh,
  onSecondaryContainer: MotoColors.text,
  tertiary: MotoColors.lock,
  onTertiary: MotoColors.bg,
  tertiaryContainer: MotoColors.surfaceHigh,
  onTertiaryContainer: MotoColors.lock,
  error: MotoColors.rec,
  onError: MotoColors.bg,
  errorContainer: MotoColors.surfaceHigh,
  onErrorContainer: MotoColors.rec,
  surface: MotoColors.bg,
  onSurface: MotoColors.text,
  onSurfaceVariant: MotoColors.dim,
  surfaceDim: MotoColors.bg,
  surfaceBright: MotoColors.surfaceTop,
  surfaceContainerLowest: MotoColors.bg,
  surfaceContainerLow: MotoColors.surface,
  surfaceContainer: MotoColors.surfaceRaised,
  surfaceContainerHigh: MotoColors.surfaceHigh,
  surfaceContainerHighest: MotoColors.surfaceTop,
  outline: MotoColors.disabled,
  outlineVariant: MotoColors.hairlineStrong,
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  inverseSurface: MotoColors.text,
  onInverseSurface: MotoColors.bg,
  inversePrimary: MotoColors.bg,
  surfaceTint: Color(0x00000000),
);

/// The text theme: Barlow Condensed for display, headline and large titles,
/// Barlow for everything else. Sizes follow the boards.
final TextTheme motoTextTheme = TextTheme(
  displayLarge: MotoFonts.condensedStyle(84, letterSpacingEm: 0.04),
  displayMedium: MotoFonts.condensedStyle(44, letterSpacingEm: 0.06),
  displaySmall: MotoFonts.condensedStyle(34, letterSpacingEm: 0.06),
  headlineLarge: MotoFonts.condensedStyle(32),
  headlineMedium: MotoFonts.condensedStyle(30),
  headlineSmall: MotoFonts.condensedStyle(26, weight: FontWeight.w600),
  titleLarge: MotoFonts.condensedStyle(22),
  titleMedium: MotoFonts.bodyStyle(17, weight: FontWeight.w600),
  titleSmall: MotoFonts.bodyStyle(16, weight: FontWeight.w600),
  bodyLarge: MotoFonts.bodyStyle(16, height: 1.4),
  bodyMedium: MotoFonts.bodyStyle(14, height: 1.4),
  bodySmall: MotoFonts.bodyStyle(13, height: 1.35),
  labelLarge: MotoFonts.bodyStyle(16, weight: FontWeight.w600),
  labelMedium: MotoFonts.bodyStyle(15, weight: FontWeight.w500),
  labelSmall: MotoFonts.bodyStyle(13, letterSpacingEm: 0.08),
).apply(bodyColor: MotoColors.text, displayColor: MotoColors.text);

/// Builds the app theme. Also registers the font licence, so the app root
/// needs only this one call.
ThemeData buildAppTheme() {
  registerFontLicence();
  const scheme = motoColorScheme;
  final text = motoTextTheme;
  const buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(MotoRadii.sm)),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    fontFamily: MotoFonts.body,
    textTheme: text,
    scaffoldBackgroundColor: MotoColors.bg,
    canvasColor: MotoColors.bg,
    dividerColor: MotoColors.hairline,
    dividerTheme: const DividerThemeData(color: MotoColors.hairline),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? MotoColors.text
              : MotoColors.surface,
        ),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return MotoColors.disabled;
          }
          return states.contains(WidgetState.selected)
              ? MotoColors.bg
              : MotoColors.dim;
        }),
        iconColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? MotoColors.bg
              : MotoColors.dim,
        ),
        side: const WidgetStatePropertyAll(
          BorderSide(color: MotoColors.hairlineStrong),
        ),
        shape: const WidgetStatePropertyAll(buttonShape),
        textStyle: WidgetStatePropertyAll(
          MotoFonts.condensedStyle(18, weight: FontWeight.w600),
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return MotoColors.disabled;
        }
        return states.contains(WidgetState.selected)
            ? MotoColors.bg
            : MotoColors.muted;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return MotoColors.surface;
        }
        return states.contains(WidgetState.selected)
            ? MotoColors.text
            : MotoColors.surfaceTop;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? MotoColors.text
            : MotoColors.hairlineStrong,
      ),
    ),
    listTileTheme: ListTileThemeData(
      textColor: MotoColors.text,
      iconColor: MotoColors.dim,
      titleTextStyle: text.titleMedium,
      subtitleTextStyle: text.bodyMedium?.copyWith(color: MotoColors.dim),
      leadingAndTrailingTextStyle: text.bodyMedium?.copyWith(
        color: MotoColors.dim,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: MotoColors.surfaceRaised,
      modalBackgroundColor: MotoColors.surfaceRaised,
      surfaceTintColor: Color(0x00000000),
      dragHandleColor: MotoColors.muted,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(MotoRadii.dialog),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: MotoColors.surfaceRaised,
      surfaceTintColor: const Color(0x00000000),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(MotoRadii.dialog)),
        side: BorderSide(color: MotoColors.hairlineStrong),
      ),
      titleTextStyle: MotoFonts.condensedStyle(30, color: MotoColors.text),
      contentTextStyle: text.bodyLarge,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: MotoColors.surfaceRaised,
      surfaceTintColor: const Color(0x00000000),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(MotoRadii.sm)),
        side: BorderSide(color: MotoColors.hairlineStrong),
      ),
      textStyle: text.bodyLarge,
      labelTextStyle: WidgetStatePropertyAll(text.bodyLarge),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: MotoColors.surfaceHigh,
      contentTextStyle: text.bodyLarge,
      actionTextColor: MotoColors.text,
      closeIconColor: MotoColors.dim,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: MotoColors.text,
        foregroundColor: MotoColors.bg,
        disabledBackgroundColor: MotoColors.surfaceTop,
        disabledForegroundColor: MotoColors.muted,
        shape: buttonShape,
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: MotoColors.text,
        disabledForegroundColor: MotoColors.muted,
        side: const BorderSide(color: MotoColors.disabled, width: 1.5),
        shape: buttonShape,
        textStyle: text.labelLarge,
      ),
    ),
  );
}
