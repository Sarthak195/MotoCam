// lib/features/recording/widgets/recording_settings_page.dart
//
// The Settings page (board A-Settings) and its sub-pages: Advanced,
// Storage, Safety, and Privacy and data. One [RecordingSettingsForm] holds
// the choices of every page; only SAVE on the main page returns them, as
// the same [RecordingSettingsFormResult] the old bottom sheet returned.
// Nothing is persisted or applied here.

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/build_flags.dart';
import '../../../core/providers/app_settings_provider.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/ui/kit.dart';
import '../../camera/providers/camera_provider.dart';
import 'recording_settings_form.dart';
import 'recording_settings_sheet.dart';

/// Resolutions on the main page (the board's 720p, 1080p and 4K).
const List<int> mainPageResolutions = [720, 1080, 2160];

/// Bitrates on the main page. The board's 20 Mbps does not exist.
const List<int> mainPageBitratesMbps = [8, 12, 16];

/// Clip lengths on the main page, in seconds (1, 2 and 3 min).
const List<int> mainPageClipLengthsSeconds = [60, 120, 180];

/// Pushes the Settings page and completes with the rider's choices on
/// SAVE, or null when the rider goes back without saving.
///
/// It takes the same option lists the old bottom sheet took, so the
/// caller's code before and after the sheet stays as it is.
Future<RecordingSettingsFormResult?> showRecordingSettingsPage(
  BuildContext context, {
  required List<int> initialFpsOptions,
  required List<CameraDescription> initialCameraOptions,
  required Set<ResolutionPreset> initialUnsupportedPresets,
}) {
  return Navigator.of(context).push<RecordingSettingsFormResult>(
    MaterialPageRoute<RecordingSettingsFormResult>(
      builder: (_) => RecordingSettingsPage(
        initialFpsOptions: initialFpsOptions,
        initialCameraOptions: initialCameraOptions,
        initialUnsupportedPresets: initialUnsupportedPresets,
      ),
    ),
  );
}

/// The Settings page: the recording settings with their applied values,
/// links to the sub-pages and SAVE.
///
/// Reads the saved values from [AppSettingsProvider] and the applied ones
/// from [CameraProvider], and pops a [RecordingSettingsFormResult] on SAVE.
class RecordingSettingsPage extends StatefulWidget {
  /// Creates the page with the given option lists.
  const RecordingSettingsPage({
    super.key,
    required this.initialFpsOptions,
    required this.initialCameraOptions,
    required this.initialUnsupportedPresets,
  });

  /// Frame rates offered for the saved resolution.
  final List<int> initialFpsOptions;

  /// Cameras the rider can choose from.
  final List<CameraDescription> initialCameraOptions;

  /// Resolution presets known to fail on this device; shown as unsupported.
  final Set<ResolutionPreset> initialUnsupportedPresets;

  @override
  State<RecordingSettingsPage> createState() => _RecordingSettingsPageState();
}

class _RecordingSettingsPageState extends State<RecordingSettingsPage> {
  late final CameraProvider _camera;
  late final RecordingSettingsForm _form;

  @override
  void initState() {
    super.initState();
    final settings = context.read<AppSettingsProvider>();
    _camera = context.read<CameraProvider>();
    final camera = _camera;
    _form = RecordingSettingsForm(
      settings: settings,
      activeCameraName: camera.activeCameraName,
      initialFpsOptions: widget.initialFpsOptions,
      initialCameraOptions: widget.initialCameraOptions,
      initialUnsupportedPresets: widget.initialUnsupportedPresets,
      lookupFpsOptions: (preset) =>
          camera.getSupportedFpsOptionsForPreset(preset: preset),
    );
  }

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  void _openSubPage(Widget Function() builder) {
    unawaited(
      Navigator.of(
        context,
      ).push<void>(MaterialPageRoute<void>(builder: (_) => builder())),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_form, _camera]),
      builder: (context, _) {
        final form = _form;
        final camera = _camera;
        final android = defaultTargetPlatform == TargetPlatform.android;
        return _SettingsScaffold(
          title: 'Settings',
          footer: _SaveFooter(
            note: camera.isRecording
                ? 'A ride is recording. Resolution, frame rate, bitrate, '
                      'clip length, lens and audio apply to the next '
                      'recording.'
                : 'Recording settings apply to the next recording.',
            onSave: () => Navigator.of(context).pop(form.toResult()),
          ),
          children: [
            const _SectionLabel('RECORDING'),
            ..._recordingRows(form, camera),
            const SizedBox(height: MotoSize.gapWide),
            _NavGroup(
              rows: [
                _NavRowData(
                  title: 'Advanced',
                  subtitle:
                      'Presets, lens, every resolution, frame rate, '
                      'bitrate and clip length, loop buffer, speed refresh',
                  onTap: () => _openSubPage(
                    () => _AdvancedPage(form: form, camera: camera),
                  ),
                ),
              ],
            ),
            const SizedBox(height: MotoSize.gapWide),
            _NavGroup(
              rows: [
                _NavRowData(
                  title: 'Storage',
                  subtitle: _storageSummary(form, android),
                  onTap: () => _openSubPage(() => _StoragePage(form: form)),
                ),
                if (kControlsRow)
                  const _NavRowData(
                    title: 'Controls',
                    subtitle: 'Buttons and key learning',
                  ),
                _NavRowData(
                  title: 'Safety',
                  subtitle: _safetySummary(form, android),
                  onTap: () => _openSubPage(() => _SafetyPage(form: form)),
                ),
                _NavRowData(
                  title: 'Privacy and data',
                  subtitle: 'Audio ${form.audioEnabled ? 'on' : 'off'}',
                  onTap: () => _openSubPage(() => _PrivacyPage(form: form)),
                ),
                if (kBackupRow)
                  const _NavRowData(title: 'Backup', subtitle: 'Backup'),
                _NavRowData(
                  title: 'About and licences',
                  subtitle: 'Open-source licences',
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'MotoCam',
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  List<Widget> _recordingRows(RecordingSettingsForm form, CameraProvider cam) {
    final applied = cam.isInitialized;
    String? status(String now, String requested, String saved) => applied
        ? appliedStatusText(
            applied: now,
            requested: requested,
            saved: saved,
            recording: cam.isRecording,
          )
        : null;

    String mbps(int value) => '$value Mbps';
    String onOff(bool value) => value ? 'on' : 'off';
    final unsupported = form.unsupportedResolutions;

    return [
      SegmentedRow<int>(
        label: 'Resolution',
        options: [
          for (final option in mainPageOptions(
            mainPageResolutions,
            form.resolution,
          ))
            SegmentOption(
              value: option,
              label: shortResolutionLabel(option),
              enabled: !form.isResolutionUnsupported(option),
              semanticsLabel: AppSettingsProvider.resolutionLabel(option),
            ),
        ],
        selected: form.resolution,
        onChanged: (value) => form.selectResolution(value),
        status: status(
          shortResolutionLabel(
            CameraProvider.resolutionForPreset(cam.resolutionPreset),
          ),
          shortResolutionLabel(form.resolution),
          shortResolutionLabel(form.savedResolution),
        ),
      ),
      if (unsupported.isNotEmpty) _UnsupportedNote(unsupported),
      const SizedBox(height: MotoSize.gap),
      _FrameRateRow(
        form: form,
        appliedStatus: status(
          '${cam.recordingFps} fps',
          '${form.fps} fps',
          '${form.savedFps} fps',
        ),
      ),
      const SizedBox(height: MotoSize.gap),
      SegmentedRow<int>(
        label: 'Bitrate',
        options: [
          for (final option in mainPageOptions(
            mainPageBitratesMbps,
            form.bitrateMbps,
          ))
            SegmentOption(value: option, label: mbps(option)),
        ],
        selected: form.bitrateMbps,
        onChanged: form.selectBitrate,
        status: status(
          mbps(cam.appliedVideoBitrateMbps),
          mbps(form.bitrateMbps),
          mbps(form.savedBitrateMbps),
        ),
      ),
      const SizedBox(height: MotoSize.gapWide),
      SegmentedRow<int>(
        label: 'Clip length',
        options: [
          for (final option in mainPageOptions(
            mainPageClipLengthsSeconds,
            form.segmentDurationSeconds,
          ))
            SegmentOption(
              value: option,
              label: shortClipLengthLabel(option),
              semanticsLabel: AppSettingsProvider.segmentDurationLabel(option),
            ),
        ],
        selected: form.segmentDurationSeconds,
        onChanged: form.selectSegmentDuration,
        status: status(
          shortClipLengthLabel(cam.segmentDurationSeconds),
          shortClipLengthLabel(form.segmentDurationSeconds),
          shortClipLengthLabel(form.savedSegmentDurationSeconds),
        ),
      ),
      const SizedBox(height: MotoSize.gap),
      _SwitchRow(
        title: 'Record audio',
        subtitle:
            status(
              onOff(cam.audioEnabled),
              onOff(form.audioEnabled),
              onOff(form.savedAudioEnabled),
            ) ??
            'Disable for lower CPU and storage usage',
        value: form.audioEnabled,
        onChanged: form.setAudioEnabled,
      ),
    ];
  }

  static String _storageSummary(RecordingSettingsForm form, bool android) {
    final budget = form.recordingsStorageBudgetGb;
    final buffer = StringBuffer();
    if (budget <= 0) {
      buffer.write('Budget off');
    } else {
      final hours = storageBudgetHours(budget, form.bitrateMbps);
      buffer.write(
        'Budget $budget GB, about ${hours.toStringAsFixed(1)} h at '
        '${form.bitrateMbps} Mbps',
      );
    }
    if (android) {
      buffer.write(
        '. Gallery copies ${form.exportLockedClipsToGallery ? 'on' : 'off'}',
      );
    }
    return buffer.toString();
  }

  static String _safetySummary(RecordingSettingsForm form, bool android) {
    final sensitivity = _shortSensitivityLabel(
      form.incidentSensitivity,
    ).toLowerCase();
    final screen = form.keepScreenOnWhileRecording
        ? 'Screen kept on'
        : 'Screen may turn off';
    return android
        ? 'Crash detection $sensitivity. $screen'
        : 'Crash detection $sensitivity';
  }
}

String _shortSensitivityLabel(IncidentSensitivity sensitivity) {
  switch (sensitivity) {
    case IncidentSensitivity.low:
      return 'Low';
    case IncidentSensitivity.medium:
      return 'Medium';
    case IncidentSensitivity.high:
      return 'High';
  }
}

// Sub-pages ------------------------------------------------------------------

class _AdvancedPage extends StatelessWidget {
  const _AdvancedPage({required this.form, required this.camera});

  final RecordingSettingsForm form;
  final CameraProvider camera;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: form,
      builder: (context, _) {
        final unsupported = form.unsupportedResolutions;
        return _SettingsScaffold(
          title: 'Advanced',
          footer: const _SubPageFooter(),
          children: [
            const _SectionLabel('QUALITY'),
            _DropdownRow<QualityPresetTier>(
              label: 'Quality group',
              value: form.presetTier,
              items: {
                for (final tier in QualityPresetTier.values)
                  tier: AppSettingsProvider.qualityTierLabel(tier),
              },
              onChanged: (value) => form.selectTier(value),
            ),
            _DropdownRow<String>(
              label: 'Recording quality preset',
              value: form.qualityProfileId,
              items: {
                AppSettingsProvider.customQualityProfileId: 'Custom',
                for (final profile
                    in AppSettingsProvider.qualityProfilesForTier(
                      form.presetTier,
                    ))
                  profile.id: profile.label,
              },
              onChanged: (value) => form.selectProfile(value),
            ),
            if (form.cameraOptions.isNotEmpty)
              _DropdownRow<String>(
                label: 'Camera lens',
                value: form.displayedCameraName,
                items: {
                  for (final option in form.cameraOptions)
                    option.name: camera.cameraLabel(option),
                },
                onChanged: form.selectCamera,
              ),
            const SizedBox(height: MotoSize.gap),
            SegmentedRow<int>(
              label: 'Resolution',
              options: [
                for (final option in AppSettingsProvider.resolutionOptions)
                  SegmentOption(
                    value: option,
                    label: shortResolutionLabel(option),
                    enabled: !form.isResolutionUnsupported(option),
                    semanticsLabel: AppSettingsProvider.resolutionLabel(option),
                  ),
              ],
              selected: form.resolution,
              onChanged: (value) => form.selectResolution(value),
            ),
            if (unsupported.isNotEmpty) _UnsupportedNote(unsupported),
            const SizedBox(height: MotoSize.gapWide),
            if (form.availableFps.length > 1)
              SegmentedRow<int>(
                label: 'Frame rate',
                options: [
                  for (final option in form.availableFps)
                    SegmentOption(value: option, label: '$option fps'),
                ],
                selected: form.fps,
                onChanged: form.selectFps,
                status: 'Offered by this camera',
              )
            else
              _FrameRateRow(form: form, appliedStatus: null),
            const SizedBox(height: MotoSize.gapWide),
            SegmentedRow<int>(
              label: 'Bitrate',
              options: [
                for (final option in AppSettingsProvider.bitrateOptionsMbps)
                  SegmentOption(value: option, label: '$option Mbps'),
              ],
              selected: form.bitrateMbps,
              onChanged: form.selectBitrate,
            ),
            const SizedBox(height: MotoSize.gapWide),
            _DropdownRow<int>(
              label: 'Clip length',
              value: form.segmentDurationSeconds,
              items: {
                for (final seconds
                    in AppSettingsProvider.segmentDurationOptionsSeconds)
                  seconds: AppSettingsProvider.segmentDurationLabel(seconds),
              },
              onChanged: form.selectSegmentDuration,
            ),
            const SizedBox(height: MotoSize.gap),
            SegmentedRow<int>(
              label: 'Loop buffer',
              status: 'Unlocked clips kept per ride',
              options: [
                for (final count in AppSettingsProvider.loopSegmentCountOptions)
                  SegmentOption(
                    value: count,
                    label: '$count',
                    semanticsLabel: '$count segments',
                  ),
              ],
              selected: form.loopSegmentCount,
              onChanged: form.selectLoopSegmentCount,
            ),
            const SizedBox(height: MotoSize.gapWide),
            SegmentedRow<int>(
              label: 'Speed refresh',
              options: [
                for (final ms in const [100, 200, 300, 500])
                  SegmentOption(value: ms, label: '$ms ms'),
              ],
              selected: form.speedRefreshMs,
              onChanged: form.selectSpeedRefresh,
            ),
          ],
        );
      },
    );
  }
}

class _StoragePage extends StatelessWidget {
  const _StoragePage({required this.form});

  final RecordingSettingsForm form;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: form,
      builder: (context, _) {
        final budget = form.recordingsStorageBudgetGb;
        final hours = storageBudgetHours(budget, form.bitrateMbps);
        return _SettingsScaffold(
          title: 'Storage',
          footer: const _SubPageFooter(),
          children: [
            SegmentedRow<int>(
              label: 'Storage budget for all rides',
              status: budget <= 0
                  ? 'Off'
                  : 'About ${hours.toStringAsFixed(1)} h at '
                        '${form.bitrateMbps} Mbps',
              options: [
                for (final gigabytes
                    in AppSettingsProvider.storageBudgetOptionsGb)
                  SegmentOption(
                    value: gigabytes,
                    label: gigabytes <= 0 ? 'Off' : '$gigabytes',
                    semanticsLabel: AppSettingsProvider.storageBudgetLabel(
                      gigabytes,
                    ),
                  ),
              ],
              selected: budget,
              onChanged: form.selectStorageBudget,
            ),
            const _BodyNote(
              'Sizes are in GB. When recordings exceed the budget, the oldest '
              'unlocked rides are deleted while you record. Locked rides are '
              'never deleted.',
            ),
            if (defaultTargetPlatform == TargetPlatform.android) ...[
              const SizedBox(height: MotoSize.gapWide),
              _SwitchRow(
                title: 'Copy locked clips to gallery',
                subtitle:
                    'When a ride stops, locked clips are copied to '
                    'Movies/MotoCam/Recordings. Other apps can read gallery '
                    'copies and they stay after MotoCam is uninstalled; Ride '
                    'History offers to remove them when you unlock or '
                    'delete the ride.',
                value: form.exportLockedClipsToGallery,
                onChanged: form.setExportLockedClipsToGallery,
              ),
            ],
          ],
        );
      },
    );
  }
}

class _SafetyPage extends StatelessWidget {
  const _SafetyPage({required this.form});

  final RecordingSettingsForm form;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: form,
      builder: (context, _) {
        return _SettingsScaffold(
          title: 'Safety',
          footer: const _SubPageFooter(),
          children: [
            SegmentedRow<IncidentSensitivity>(
              label: 'Crash detection',
              status: AppSettingsProvider.incidentSensitivityLabel(
                form.incidentSensitivity,
              ),
              options: [
                for (final sensitivity in IncidentSensitivity.values)
                  SegmentOption(
                    value: sensitivity,
                    label: _shortSensitivityLabel(sensitivity),
                    semanticsLabel:
                        AppSettingsProvider.incidentSensitivityLabel(
                          sensitivity,
                        ),
                  ),
              ],
              selected: form.incidentSensitivity,
              onChanged: form.selectIncidentSensitivity,
            ),
            const _BodyNote(
              'How easily a hard jolt locks the current clip. Low locks '
              'fewer clips, High locks more.',
            ),
            if (defaultTargetPlatform == TargetPlatform.android) ...[
              const SizedBox(height: MotoSize.gapWide),
              _SwitchRow(
                title: 'Keep screen on while recording',
                subtitle:
                    'Recording is designed to continue with the screen off, '
                    'but this is not yet confirmed on every phone. Keeping '
                    'the screen on is the safe fallback; it uses more '
                    'battery. A change applies at once to a ride in '
                    'progress.',
                value: form.keepScreenOnWhileRecording,
                onChanged: form.setKeepScreenOnWhileRecording,
              ),
            ],
          ],
        );
      },
    );
  }
}

class _PrivacyPage extends StatelessWidget {
  const _PrivacyPage({required this.form});

  final RecordingSettingsForm form;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: form,
      builder: (context, _) {
        return _SettingsScaffold(
          title: 'Privacy and data',
          footer: const _SubPageFooter(),
          children: [
            _SwitchRow(
              title: 'Record audio',
              subtitle:
                  'Records sound with the video. Disable for lower CPU and '
                  'storage usage.',
              value: form.audioEnabled,
              onChanged: form.setAudioEnabled,
            ),
          ],
        );
      },
    );
  }
}

// Building blocks ------------------------------------------------------------

/// A settings page: a back arrow and title, a scrolling list capped in
/// width, and a footer pinned under it.
class _SettingsScaffold extends StatelessWidget {
  const _SettingsScaffold({
    required this.title,
    required this.children,
    required this.footer,
  });

  final String title;
  final List<Widget> children;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MotoColors.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    MotoSize.gutter,
                    MotoSize.gap,
                    MotoSize.gutter,
                    0,
                  ),
                  child: _PageHeader(title: title),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      MotoSize.gutter,
                      MotoSize.gap,
                      MotoSize.gutter,
                      MotoSize.gutter,
                    ),
                    children: children,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    MotoSize.gutter,
                    0,
                    MotoSize.gutter,
                    MotoSize.gutter,
                  ),
                  child: footer,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    void back() => Navigator.of(context).maybePop();
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          Semantics(
            button: true,
            label: 'Back',
            excludeSemantics: true,
            onTap: back,
            child: Material(
              color: MotoColors.bg,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(MotoRadii.sm)),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: back,
                child: const SizedBox.square(
                  dimension: MotoSize.minTarget,
                  child: Icon(
                    Icons.chevron_left_rounded,
                    size: 30,
                    color: MotoColors.text,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MotoFonts.condensedStyle(30, color: MotoColors.text),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: MotoSize.gap),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: MotoFonts.bodyStyle(
            13,
            letterSpacingEm: 0.08,
            color: MotoColors.dim,
          ),
        ),
      ),
    );
  }
}

class _UnsupportedNote extends StatelessWidget {
  const _UnsupportedNote(this.resolutions);

  final List<int> resolutions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        'Known unsupported on this device: '
        '${resolutions.map(AppSettingsProvider.resolutionLabel).join(', ')}',
        style: MotoFonts.bodyStyle(
          13,
          weight: FontWeight.w600,
          color: MotoColors.amber,
        ),
      ),
    );
  }
}

class _BodyNote extends StatelessWidget {
  const _BodyNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        text,
        style: MotoFonts.bodyStyle(13, color: MotoColors.dim, height: 1.35),
      ),
    );
  }
}

/// Frame rate as a read-only row: "Fixed at 30 fps" when the camera offers
/// one rate, otherwise the chosen rate (changed on the Advanced page).
class _FrameRateRow extends StatelessWidget {
  const _FrameRateRow({required this.form, required this.appliedStatus});

  final RecordingSettingsForm form;
  final String? appliedStatus;

  @override
  Widget build(BuildContext context) {
    final fixed = form.availableFps.length <= 1;
    final requested = '${form.fps} fps';
    final String trailing;
    if (appliedStatus == null) {
      trailing = '';
    } else if (appliedStatus == 'Applied $requested') {
      trailing = ', applied';
    } else {
      trailing = '. $appliedStatus';
    }
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: MotoColors.hairline)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(
            'Frame rate',
            style: MotoFonts.bodyStyle(
              16,
              weight: FontWeight.w600,
              color: MotoColors.text,
            ),
          ),
          const SizedBox(width: MotoSize.gapWide),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  if (fixed) const TextSpan(text: 'Fixed at '),
                  TextSpan(
                    text: requested,
                    style: MotoFonts.condensedStyle(
                      20,
                      color: MotoColors.text,
                      tabularFigures: true,
                    ),
                  ),
                  TextSpan(text: trailing),
                  if (!fixed) const TextSpan(text: '. More in Advanced'),
                ],
              ),
              textAlign: TextAlign.end,
              style: MotoFonts.bodyStyle(13, color: MotoColors.dim),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: onChanged,
      title: Text(
        title,
        style: MotoFonts.bodyStyle(
          16,
          weight: FontWeight.w600,
          color: MotoColors.text,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: MotoFonts.bodyStyle(13, color: MotoColors.dim, height: 1.35),
      ),
    );
  }
}

class _DropdownRow<T> extends StatelessWidget {
  const _DropdownRow({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: MotoSize.gapWide),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: MotoFonts.bodyStyle(
              16,
              weight: FontWeight.w600,
              color: MotoColors.text,
            ),
          ),
          const SizedBox(height: 6),
          DropdownButtonFormField<T>(
            key: ValueKey(value),
            initialValue: items.containsKey(value) ? value : null,
            isExpanded: true,
            dropdownColor: MotoColors.surfaceRaised,
            iconEnabledColor: MotoColors.dim,
            style: MotoFonts.bodyStyle(16, color: MotoColors.text),
            decoration: InputDecoration(
              filled: true,
              fillColor: MotoColors.surface,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(MotoRadii.sm),
                borderSide: BorderSide.none,
              ),
            ),
            items: [
              for (final entry in items.entries)
                DropdownMenuItem<T>(
                  value: entry.key,
                  child: Text(
                    entry.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (selected) {
              if (selected != null) {
                onChanged(selected);
              }
            },
          ),
        ],
      ),
    );
  }
}

class _NavRowData {
  const _NavRowData({required this.title, required this.subtitle, this.onTap});

  final String title;
  final String subtitle;
  final VoidCallback? onTap;
}

/// Links grouped as on the board: rounded outer corners, square inner ones,
/// 2 dp apart.
class _NavGroup extends StatelessWidget {
  const _NavGroup({required this.rows});

  final List<_NavRowData> rows;

  @override
  Widget build(BuildContext context) {
    const outer = Radius.circular(MotoRadii.sm);
    const inner = Radius.circular(MotoRadii.xs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 2),
          InstrumentRow(
            title: rows[i].title,
            subtitle: rows[i].subtitle,
            minHeight: MotoSize.minTarget,
            borderRadius: BorderRadius.vertical(
              top: i == 0 ? outer : inner,
              bottom: i == rows.length - 1 ? outer : inner,
            ),
            onTap: rows[i].onTap,
            trailing: rows[i].onTap == null
                ? null
                : const Icon(
                    Icons.chevron_right_rounded,
                    color: MotoColors.dim,
                  ),
          ),
        ],
      ],
    );
  }
}

class _SaveFooter extends StatelessWidget {
  const _SaveFooter({required this.note, required this.onSave});

  final String note;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(top: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: MotoColors.hairlineStrong)),
      ),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(right: MotoSize.gap),
            child: Icon(
              Icons.schedule_rounded,
              size: 16,
              color: MotoColors.dim,
            ),
          ),
          Expanded(
            child: Text(
              note,
              style: MotoFonts.bodyStyle(
                13,
                color: MotoColors.dim,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(width: MotoSize.gapWide),
          Semantics(
            button: true,
            // The phone harness taps "SAVE SETTINGS".
            label: 'SAVE SETTINGS',
            excludeSemantics: true,
            onTap: onSave,
            child: Material(
              color: MotoColors.text,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(MotoRadii.md)),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onSave,
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  alignment: Alignment.center,
                  child: Text(
                    'SAVE',
                    style: MotoFonts.condensedStyle(
                      22,
                      letterSpacingEm: 0.04,
                      color: MotoColors.bg,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SubPageFooter extends StatelessWidget {
  const _SubPageFooter();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(top: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: MotoColors.hairlineStrong)),
      ),
      child: Text(
        'Changes here are kept until you tap SAVE on Settings.',
        style: MotoFonts.bodyStyle(13, color: MotoColors.dim, height: 1.35),
      ),
    );
  }
}
