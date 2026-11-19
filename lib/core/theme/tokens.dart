// lib/core/theme/tokens.dart
//
// Design tokens of redesign A ("Instrument"): colours, radii, sizes and type,
// taken from the A-*.dc.html boards. Widgets read these instead of literal
// values so the look can change in one place.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Colours of the dark "Instrument" theme.
abstract final class MotoColors {
  /// Page background.
  static const Color bg = Color(0xFF0B0C0B);

  /// Primary text and the light fills (START, selected segment).
  static const Color text = Color(0xFFEEF0EA);

  /// Secondary text, units and icons.
  static const Color dim = Color(0xFFB4B9AF);

  /// Captions, section labels and the READY outline.
  static const Color muted = Color(0xFF8F958B);

  /// Disabled text and outlines of quiet buttons.
  static const Color disabled = Color(0xFF5C615A);

  /// Lowest raised surface: rows, trays, the camera frame.
  static const Color surface = Color(0xFF151715);

  /// Dialogs, sheets and cards.
  static const Color surfaceRaised = Color(0xFF1A1D1A);

  /// Secondary buttons (Rides, Settings) and selected list rows.
  static const Color surfaceHigh = Color(0xFF1E211E);

  /// Highest surface: the suggested segment and disabled fills.
  static const Color surfaceTop = Color(0xFF2A2E2A);

  /// Thin dividers between rows.
  static const Color hairline = Color(0xFF232723);

  /// Outlines of chips, buttons and dialogs.
  static const Color hairlineStrong = Color(0xFF343833);

  /// REC band fill and the STOP outline.
  static const Color rec = Color(0xFFFF5A3D);

  /// The record dot inside START.
  static const Color recDot = Color(0xFFD63A20);

  /// Advisory state: warm phone, low storage, incomplete ride.
  static const Color amber = Color(0xFFFFA51F);

  /// Stalled recording ("not writing").
  static const Color stalled = Color(0xFFFFD43B);

  /// LOCK button and the LOCKED band.
  static const Color lock = Color(0xFF7FB2FF);
}

/// Corner radii used on the boards.
abstract final class MotoRadii {
  /// Inner rows of a grouped list.
  static const double xs = 4;

  /// Segments inside a segmented tray.
  static const double segment = 9;

  /// Chips, trays, small buttons.
  static const double sm = 12;

  /// State band, list rows, secondary buttons.
  static const double md = 14;

  /// Camera preview and recovery card.
  static const double lg = 16;

  /// STOP button.
  static const double stop = 20;

  /// Dialogs and bottom sheets.
  static const double dialog = 22;

  /// START and LOCK.
  static const double xl = 28;
}

/// Spacing and fixed sizes.
abstract final class MotoSize {
  /// Page side gutter.
  static const double gutter = 16;

  /// Gap between items in a group.
  static const double gap = 8;

  /// Gap between groups.
  static const double gapWide = 12;

  /// Minimum tap target.
  static const double minTarget = 48;

  /// Height of an instrument row.
  static const double row = 64;

  /// Height of a segmented tray.
  static const double tray = 50;

  /// Height of the START button on the checklist.
  static const double start = 170;

  /// Height of a status chip.
  static const double chip = 52;
}

/// Font families and the shared number features.
abstract final class MotoFonts {
  /// Body text.
  static const String body = 'Barlow';

  /// Labels, numbers and titles.
  static const String condensed = 'Barlow Condensed';

  /// Tabular figures, so timers and speeds do not jitter. Both bundled
  /// families carry the OpenType `tnum` feature.
  static const List<FontFeature> tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  /// A condensed style at [size] and [weight] (700 by default), with
  /// letter spacing given in em as on the boards.
  static TextStyle condensedStyle(
    double size, {
    FontWeight weight = FontWeight.w700,
    double letterSpacingEm = 0,
    Color? color,
    double? height,
    bool tabularFigures = false,
  }) => TextStyle(
    fontFamily: condensed,
    fontSize: size,
    fontWeight: weight,
    letterSpacing: size * letterSpacingEm,
    color: color,
    height: height,
    fontFeatures: tabularFigures ? tabular : null,
  );

  /// A body (Barlow) style at [size] and [weight] (400 by default).
  static TextStyle bodyStyle(
    double size, {
    FontWeight weight = FontWeight.w400,
    double letterSpacingEm = 0,
    Color? color,
    double? height,
  }) => TextStyle(
    fontFamily: body,
    fontSize: size,
    fontWeight: weight,
    letterSpacing: size * letterSpacingEm,
    color: color,
    height: height,
  );
}

/// Fill colour of the START RECORDING button on today's recording screen,
/// the settings sheet and the preflight sheet (Material blue 700). White
/// text on it reaches 4.6:1 contrast. The redesign replaces it in phase R1.
const Color recordingStartButtonColor = Color(0xFF1976D2);

/// Fill colour of the STOP RECORDING button on today's recording screen
/// (Material red 700). White text on it reaches 4.98:1 contrast. The
/// redesign replaces it in phase R1.
const Color recordingStopButtonColor = Color(0xFFD32F2F);

/// Label colour used on [recordingStartButtonColor] and
/// [recordingStopButtonColor].
const Color recordingButtonLabelColor = Color(0xFFFFFFFF);

/// WCAG 2.x contrast ratio between two opaque colours (1.0 to 21.0). Only
/// tests use it, to check the token pairs.
@visibleForTesting
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}
