// lib/features/recording/widgets/recording_details_panel.dart

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/services/device_status_service.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/ui/thumb_button.dart';
import '../../telemetry/providers/telemetry_provider.dart';
import '../recording_screen_logic.dart';
import 'recording_view_state.dart';

/// The status details the screen shows while parked: the warnings, battery,
/// distance and temperature readings, the rest of the recording profile
/// and, while recording, Settings (they apply to the next START) and
/// Pop-out.
///
/// The landscape layout leaves Pop-out out ([showPopOut]), because its
/// rail carries it.
///
/// Distance keeps its own [Selector] and the polled readings their own
/// listeners, so a tick never rebuilds the screen.
class RecordingDetailsPanel extends StatelessWidget {
  /// Creates the panel.
  const RecordingDetailsPanel({
    super.key,
    required this.view,
    required this.deviceStatus,
    required this.freeStorageBytes,
    required this.onSettings,
    required this.onPop,
    this.showPopOut = true,
  });

  /// What the screen shows.
  final RecordingViewState view;

  /// Battery and thermal status, polled every 15 s.
  final ValueListenable<DeviceStatusSnapshot> deviceStatus;

  /// Free bytes for recordings, polled every 15 s; null when unknown.
  final ValueListenable<int?> freeStorageBytes;

  /// Opens the recording settings.
  final VoidCallback onSettings;

  /// Leaves the screen into Picture-in-Picture.
  final VoidCallback onPop;

  /// Whether the recording actions include Pop-out next to Settings.
  final bool showPopOut;

  @override
  Widget build(BuildContext context) {
    final presetWarning = view.presetWarning;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Status details',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: MotoColors.surface,
          borderRadius: BorderRadius.circular(MotoRadii.sm),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<DeviceStatusSnapshot>(
              valueListenable: deviceStatus,
              builder: (context, status, _) {
                final level = thermalLevelFor(
                  thermalStatus: status.thermalStatus,
                  batteryTemperatureC: status.batteryTemperatureC,
                );
                if (level != ThermalLevel.hot && level != ThermalLevel.warm) {
                  return const SizedBox.shrink();
                }
                final temp = status.batteryTemperatureC;
                return _DetailLine(
                  lead: level == ThermalLevel.hot
                      ? 'Phone hot.'
                      : 'Phone warm.',
                  text: temp == null
                      ? null
                      : 'Battery at ${temp.toStringAsFixed(1)} C.',
                );
              },
            ),
            ValueListenableBuilder<int?>(
              valueListenable: freeStorageBytes,
              builder: (context, freeBytes, _) {
                final hours = storageHoursLeft(
                  freeBytes: freeBytes,
                  bitrateMbps: view.shownBitrateMbps,
                );
                if (hours == null || hours >= storageLowHours) {
                  return const SizedBox.shrink();
                }
                final rate = math.max(
                  view.shownBitrateMbps,
                  storageEstimateMinBitrateMbps,
                );
                return _DetailLine(
                  lead: 'Storage low.',
                  text:
                      'Up to ${storageHoursLabel(hours)} h left at $rate Mbps.',
                );
              },
            ),
            if (view.profileDiffers)
              _DetailLine(
                lead: '${view.appliedProfileLabel} applied,',
                text: '${view.requestedProfileLabel} asked.',
              ),
            if (view.isApplyingSettings)
              const _DetailLine(
                text:
                    'Applying settings... camera controls are temporarily '
                    'locked.',
              ),
            if (presetWarning != null) _DetailLine(text: presetWarning),
            if (view.incidentDetectionUnavailable)
              const _DetailLine(
                text:
                    'Incident detection unavailable (no motion sensor): '
                    'clips are not auto-locked. Use LOCK.',
              ),
            if (view.locationOff)
              const _DetailLine(
                text:
                    'Location is off: no speed, distance or route is '
                    'recorded.',
              ),
            if (view.highIncidentSensitivity)
              const _DetailLine(
                text:
                    'High incident sensitivity may increase auto-lock '
                    'frequency.',
              ),
            Row(
              children: [
                Expanded(
                  child: ValueListenableBuilder<DeviceStatusSnapshot>(
                    valueListenable: deviceStatus,
                    builder: (context, status, _) {
                      final level = status.batteryLevelPercent;
                      return _Reading(
                        caption: 'Battery',
                        value: level == null ? '--' : '$level%',
                      );
                    },
                  ),
                ),
                Expanded(
                  child: Selector<TelemetryProvider, String>(
                    selector: (_, telemetry) =>
                        '${telemetry.rideDistanceKm.toStringAsFixed(2)} km',
                    builder: (context, distance, _) =>
                        _Reading(caption: 'Distance', value: distance),
                  ),
                ),
                Expanded(
                  child: ValueListenableBuilder<DeviceStatusSnapshot>(
                    valueListenable: deviceStatus,
                    builder: (context, status, _) {
                      final temp = status.batteryTemperatureC;
                      return _Reading(
                        caption: 'Temp',
                        value: temp == null
                            ? '--'
                            : '${temp.toStringAsFixed(1)} C',
                      );
                    },
                  ),
                ),
              ],
            ),
            if (view.isRecording) ...[
              const SizedBox(height: MotoSize.gap),
              Row(
                children: [
                  Expanded(
                    child: ThumbButton(
                      variant: ThumbButtonVariant.secondary,
                      label: 'Settings',
                      semanticsLabel: 'Settings',
                      icon: Icons.tune_rounded,
                      height: MotoSize.minTarget,
                      labelSize: 22,
                      onPressed: view.settingsEnabled ? onSettings : null,
                    ),
                  ),
                  if (showPopOut) ...[
                    const SizedBox(width: MotoSize.gap),
                    Expanded(
                      child: ThumbButton(
                        variant: ThumbButtonVariant.secondary,
                        label: 'Pop-out',
                        semanticsLabel: 'Pop-out',
                        icon: Icons.picture_in_picture_alt_outlined,
                        height: MotoSize.minTarget,
                        labelSize: 22,
                        onPressed: view.secondaryEnabled ? onPop : null,
                      ),
                    ),
                  ],
                ],
              ),
            ],
            const SizedBox(height: 6),
            Text(
              view.profileDetail,
              style: MotoFonts.bodyStyle(14, color: MotoColors.dim),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line of the panel: a bold lead and dim text, as on the boards.
class _DetailLine extends StatelessWidget {
  const _DetailLine({this.lead, this.text});

  final String? lead;
  final String? text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2, right: 8),
            child: Icon(
              Icons.warning_amber_rounded,
              size: 18,
              color: MotoColors.amber,
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  if (lead != null)
                    TextSpan(
                      text: lead,
                      style: MotoFonts.bodyStyle(
                        15,
                        weight: FontWeight.w600,
                        color: MotoColors.text,
                      ),
                    ),
                  if (lead != null && text != null) const TextSpan(text: ' '),
                  if (text != null) TextSpan(text: text),
                ],
              ),
              style: MotoFonts.bodyStyle(15, color: MotoColors.dim),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small reading: a caption over a value.
class _Reading extends StatelessWidget {
  const _Reading({required this.caption, required this.value});

  final String caption;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          caption,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: MotoFonts.bodyStyle(13, color: MotoColors.muted),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: MotoFonts.condensedStyle(
              22,
              weight: FontWeight.w600,
              color: MotoColors.text,
              tabularFigures: true,
            ),
          ),
        ),
      ],
    );
  }
}
