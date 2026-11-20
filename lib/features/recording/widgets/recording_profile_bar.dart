// lib/features/recording/widgets/recording_profile_bar.dart

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/services/device_status_service.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/ui/dashed_outline.dart';
import '../recording_screen_logic.dart';
import 'recording_view_state.dart';

/// The row of instrument chips under the state band: phone temperature,
/// storage left, the applied recording profile and, while recording, the
/// Blackout button.
///
/// Temperature and storage listen to their own polled values, so a poll
/// rebuilds only its chip. The orientation chip (kOrientationChip) waits for
/// the landscape engine and is left out.
class RecordingProfileBar extends StatelessWidget {
  /// Creates the chip row.
  const RecordingProfileBar({
    super.key,
    required this.view,
    required this.deviceStatus,
    required this.freeStorageBytes,
    required this.onBlackout,
  });

  /// What the screen shows.
  final RecordingViewState view;

  /// Battery and thermal status, polled every 15 s.
  final ValueListenable<DeviceStatusSnapshot> deviceStatus;

  /// Free bytes for recordings, polled every 15 s; null when unknown.
  final ValueListenable<int?> freeStorageBytes;

  /// Toggles Blackout.
  final VoidCallback onBlackout;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MotoSize.chip,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ValueListenableBuilder<DeviceStatusSnapshot>(
            valueListenable: deviceStatus,
            builder: (context, status, _) => ThermalChip(
              level: thermalLevelFor(
                thermalStatus: status.thermalStatus,
                batteryTemperatureC: status.batteryTemperatureC,
              ),
            ),
          ),
          const SizedBox(width: MotoSize.gap),
          ValueListenableBuilder<int?>(
            valueListenable: freeStorageBytes,
            builder: (context, freeBytes, _) => StorageChip(
              hours: storageHoursLeft(
                freeBytes: freeBytes,
                bitrateMbps: view.shownBitrateMbps,
              ),
              bitrateMbps: view.shownBitrateMbps,
            ),
          ),
          const SizedBox(width: MotoSize.gap),
          Expanded(child: AppliedChip(view: view)),
          // Blackout exists only while recording; idle it is left out.
          if (view.isRecording) ...[
            const SizedBox(width: MotoSize.gap),
            _BlackoutButton(
              active: view.isBlackoutMode,
              onPressed: view.blackoutEnabled ? onBlackout : null,
            ),
          ],
        ],
      ),
    );
  }
}

/// Outline and fill of a chip by state.
BoxDecoration _chipDecoration({bool warning = false, bool amber = false}) {
  return BoxDecoration(
    color: warning ? MotoColors.amber : null,
    borderRadius: BorderRadius.circular(MotoRadii.sm),
    border: warning
        ? null
        : Border.all(
            color: amber ? MotoColors.amber : MotoColors.hairlineStrong,
            width: 2,
          ),
  );
}

/// The phone temperature chip: a thermometer and three level bars, outlined
/// amber when warm and filled amber when hot.
class ThermalChip extends StatelessWidget {
  /// Creates the chip.
  const ThermalChip({super.key, required this.level});

  /// The level to show.
  final ThermalLevel level;

  @override
  Widget build(BuildContext context) {
    final hot = level == ThermalLevel.hot;
    final warm = level == ThermalLevel.warm;
    final foreground = hot ? MotoColors.bg : MotoColors.dim;
    final filledBars = switch (level) {
      ThermalLevel.unknown => 0,
      ThermalLevel.normal => 1,
      ThermalLevel.warm => 2,
      ThermalLevel.hot => 3,
    };
    final word = switch (level) {
      ThermalLevel.unknown => 'unknown',
      ThermalLevel.normal => 'normal',
      ThermalLevel.warm => 'warm',
      ThermalLevel.hot => 'hot',
    };
    return Semantics(
      container: true,
      label: 'Phone temperature $word',
      excludeSemantics: true,
      child: Container(
        width: 64,
        decoration: _chipDecoration(warning: hot, amber: warm),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.thermostat_rounded, size: 22, color: foreground),
              const SizedBox(width: 4),
              SizedBox(
                width: 12,
                height: 24,
                child: CustomPaint(
                  painter: _LevelBarsPainter(
                    filled: filledBars,
                    fill: foreground,
                    empty: hot ? MotoColors.bg : MotoColors.disabled,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LevelBarsPainter extends CustomPainter {
  const _LevelBarsPainter({
    required this.filled,
    required this.fill,
    required this.empty,
  });

  final int filled;
  final Color fill;
  final Color empty;

  @override
  void paint(Canvas canvas, Size size) {
    // Three bars from the bottom up, as on the boards (12 x 24 box).
    final scale = size.height / 24;
    for (var i = 0; i < 3; i++) {
      final top = (17 - i * 7.25) * scale;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          2.75 * scale,
          top + 0.25 * scale,
          6.5 * scale,
          4.5 * scale,
        ),
        Radius.circular(scale),
      );
      if (i < filled) {
        canvas.drawRRect(rect, Paint()..color = fill);
      } else {
        canvas.drawRRect(
          rect,
          Paint()
            ..color = empty
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 * scale,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_LevelBarsPainter old) =>
      old.filled != filled || old.fill != fill || old.empty != empty;
}

/// The storage chip: "up to 6.2 h" of video at the applied bitrate (never
/// below the camera's 20 Mbps estimate floor), filled amber under an hour.
class StorageChip extends StatelessWidget {
  /// Creates the chip.
  const StorageChip({
    super.key,
    required this.hours,
    required this.bitrateMbps,
  });

  /// Hours left, or null when the free space is unknown.
  final double? hours;

  /// Bitrate the estimate is for, in Mbps.
  final int bitrateMbps;

  @override
  Widget build(BuildContext context) {
    final hours = this.hours;
    final low = hours != null && hours < storageLowHours;
    final foreground = low ? MotoColors.bg : MotoColors.text;
    final secondary = low ? MotoColors.bg : MotoColors.dim;
    final value = hours == null ? '--' : storageHoursLabel(hours);
    final rate = math.max(bitrateMbps, storageEstimateMinBitrateMbps);
    final label = hours == null
        ? 'Storage: unknown'
        : '${low ? 'Storage low' : 'Storage'}: up to $value hours left at '
              '$rate megabits per second';
    return Semantics(
      container: true,
      label: label,
      excludeSemantics: true,
      child: Container(
        width: 108,
        decoration: _chipDecoration(warning: low),
        padding: const EdgeInsets.symmetric(horizontal: MotoSize.gap),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.sd_storage_outlined, size: 22, color: secondary),
              const SizedBox(width: 6),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'up to',
                    style: MotoFonts.bodyStyle(
                      12,
                      color: low ? MotoColors.bg : MotoColors.muted,
                      height: 1.1,
                    ),
                  ),
                  Text.rich(
                    TextSpan(
                      text: value,
                      children: [
                        TextSpan(
                          text: ' h',
                          style: MotoFonts.condensedStyle(
                            18,
                            weight: FontWeight.w600,
                            color: secondary,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    style: MotoFonts.condensedStyle(
                      28,
                      color: foreground,
                      height: 1,
                      tabularFigures: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The recording profile: "1080p30 / 20 Mbps" under a caption while idle,
/// the two parts stacked while recording. The caption reads APPLIED only
/// when the values are the camera's (otherwise NEXT START or SET, also shown
/// while recording). A dashed
/// amber outline marks a resolution or frame rate the camera chose instead
/// of the one asked; the bitrate cannot differ today, so it has no "asked"
/// variant.
class AppliedChip extends StatelessWidget {
  /// Creates the chip.
  const AppliedChip({super.key, required this.view});

  /// What the screen shows.
  final RecordingViewState view;

  @override
  Widget build(BuildContext context) {
    final profile = view.appliedProfileLabel;
    final bitrate = '${view.shownBitrateMbps} Mbps';
    final differs = view.profileDiffers;
    final label =
        '${view.profileSemanticsTitle}: $profile at ${view.shownBitrateMbps} '
        'megabits per second'
        '${differs ? '; ${view.requestedProfileLabel} was asked' : ''}';
    final strong = MotoFonts.condensedStyle(
      20,
      weight: FontWeight.w600,
      color: MotoColors.text,
      height: 1.1,
      tabularFigures: true,
    );

    final caption = Text(
      view.profileCaption,
      maxLines: 1,
      style: MotoFonts.bodyStyle(
        12,
        letterSpacingEm: 0.08,
        color: MotoColors.muted,
        height: 1.1,
      ),
    );

    final Widget content;
    if (view.isRecording) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!view.showApplied) caption,
          Text(profile, maxLines: 1, style: strong),
          Text(
            bitrate,
            maxLines: 1,
            style: MotoFonts.condensedStyle(
              16,
              weight: FontWeight.w500,
              color: MotoColors.dim,
              height: 1.05,
              tabularFigures: true,
            ),
          ),
        ],
      );
    } else {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          caption,
          Text.rich(
            TextSpan(
              text: '$profile ',
              children: [
                TextSpan(
                  text: '/',
                  style: strong.copyWith(color: MotoColors.muted),
                ),
                TextSpan(text: ' $bitrate'),
              ],
            ),
            maxLines: 1,
            style: strong,
          ),
        ],
      );
    }

    final Widget box = Container(
      decoration: differs
          ? BoxDecoration(borderRadius: BorderRadius.circular(MotoRadii.sm))
          : _chipDecoration(),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.centerLeft,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: content,
      ),
    );
    return Semantics(
      container: true,
      label: label,
      excludeSemantics: true,
      child: differs
          ? DashedOutline(
              color: MotoColors.amber,
              radius: MotoRadii.sm,
              strokeWidth: 2,
              child: box,
            )
          : box,
    );
  }
}

/// The Blackout button of the chip row. The tooltip is for tests and long
/// presses only; the phone harness reads the semantics label.
class _BlackoutButton extends StatelessWidget {
  const _BlackoutButton({required this.active, required this.onPressed});

  final bool active;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final label = active ? 'Exit blackout' : 'Enter blackout';
    final enabled = onPressed != null;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        button: true,
        enabled: enabled,
        label: label,
        onTap: onPressed,
        excludeSemantics: true,
        child: SizedBox(
          width: 56,
          child: Material(
            color: MotoColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(MotoRadii.sm),
              side: const BorderSide(color: MotoColors.hairlineStrong),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: Center(
                child: Icon(
                  active ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                  size: 24,
                  color: enabled ? MotoColors.dim : MotoColors.disabled,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
