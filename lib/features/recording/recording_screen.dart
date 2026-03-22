// lib/features/recording/recording_screen.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import '../../core/providers/app_settings_provider.dart';
import '../camera/providers/camera_provider.dart';
import '../telemetry/providers/telemetry_provider.dart';
import '../history/rides_list_screen.dart';

class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key});

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> {
  DateTime? _lastHandledIncidentAt;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  void _handleIncidentAutoLock({
    required CameraProvider camera,
    required TelemetryProvider telemetry,
  }) {
    final detectedAt = telemetry.lastIncidentDetectedAt;
    if (!camera.isRecording || detectedAt == null) {
      return;
    }

    if (_lastHandledIncidentAt != null &&
        !detectedAt.isAfter(_lastHandledIncidentAt!)) {
      return;
    }

    _lastHandledIncidentAt = detectedAt;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !camera.isRecording) {
        return;
      }

      camera.markIncident(
        protectPastSegments: 2,
        protectCurrentSegment: true,
        reason: 'auto-crash',
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Incident detected (${telemetry.lastIncidentGForce.toStringAsFixed(2)}g). Recent segments are locked.'),
          duration: const Duration(seconds: 3),
        ),
      );
    });
  }

  Future<void> _initializeCamera() async {
    final settingsProvider = context.read<AppSettingsProvider>();
    final cameraProvider = context.read<CameraProvider>();
    final telemetryProvider = context.read<TelemetryProvider>();

    if (!settingsProvider.isLoaded) {
      await settingsProvider.load();
    }

    await cameraProvider.initializeCamera(
      resolutionPreset:
          AppSettingsProvider.toResolutionPreset(settingsProvider.recordingResolution),
      recordingFps: settingsProvider.recordingFps,
      videoBitrateBps: settingsProvider.videoBitrateMbps * 1000 * 1000,
      audioEnabled: settingsProvider.audioEnabled,
      segmentDurationMinutes: settingsProvider.segmentMinutes,
      maxRollingSegments: settingsProvider.loopSegmentCount,
    );

    telemetryProvider.setSpeedUiRefreshInterval(
      Duration(milliseconds: settingsProvider.speedRefreshMs),
    );
    telemetryProvider.setIncidentDetectionConfig(
      triggerGForce: settingsProvider.incidentTriggerGForce,
      debounce: settingsProvider.incidentDebounce,
    );

    if (!mounted) {
      return;
    }

    await telemetryProvider.initialize();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildActiveProfileBar(),
            Expanded(child: _buildCameraPreview()),
            _buildTelemetryStats(),
            _buildControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'MotoCam',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white),
            onPressed: _openSettingsSheet,
          ),
        ],
      ),
    );
  }

  Future<void> _openSettingsSheet() async {
    final settings = context.read<AppSettingsProvider>();
    final cameraProvider = context.read<CameraProvider>();
    if (!settings.isLoaded) {
      await settings.load();
    }

    if (!mounted) {
      return;
    }

    final initialFpsOptions =
        await cameraProvider.getSupportedFpsOptionsForPreset(
      preset: AppSettingsProvider.toResolutionPreset(settings.recordingResolution),
    );

    if (!mounted) {
      return;
    }

    final result = await showModalBottomSheet<_SettingsFormResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        int selectedResolution = settings.recordingResolution;
        int selectedFps = settings.recordingFps;
        int selectedBitrateMbps = settings.videoBitrateMbps;
        String selectedQualityProfileId = settings.qualityProfileId;
        QualityPresetTier selectedPresetTier =
          AppSettingsProvider.profileById(settings.qualityProfileId)?.tier ??
            QualityPresetTier.balanced;
        bool audioEnabled = settings.audioEnabled;
        int speedRefreshMs = settings.speedRefreshMs;
        int segmentMinutes = settings.segmentMinutes;
        int loopSegmentCount = settings.loopSegmentCount;
        IncidentSensitivity incidentSensitivity = settings.incidentSensitivity;
        List<int> availableFps = List<int>.from(initialFpsOptions);

        return StatefulBuilder(
          builder: (context, setModalState) {
            final maxSheetHeight = MediaQuery.of(context).size.height * 0.88;
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxSheetHeight),
                child: Padding(
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 16,
                    bottom: MediaQuery.of(context).viewInsets.bottom + 12,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Recording Settings',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _buildSettingsLabel('Quality group'),
                        DropdownButtonFormField<QualityPresetTier>(
                          initialValue: selectedPresetTier,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: QualityPresetTier.values
                              .map(
                                (tier) => DropdownMenuItem<QualityPresetTier>(
                                  value: tier,
                                  child: Text(
                                      AppSettingsProvider.qualityTierLabel(tier)),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;

                            final tierProfiles =
                                AppSettingsProvider.qualityProfilesForTier(value);
                            if (tierProfiles.isEmpty) {
                              return;
                            }

                            final selectedProfile = tierProfiles.first;
                            setModalState(() {
                              selectedPresetTier = value;
                              selectedQualityProfileId = selectedProfile.id;
                            });

                            () async {
                              final fpsOptions = await cameraProvider
                                  .getSupportedFpsOptionsForPreset(
                                preset: AppSettingsProvider.toResolutionPreset(
                                    selectedProfile.resolution),
                              );
                              if (!mounted) {
                                return;
                              }
                              setModalState(() {
                                selectedResolution = selectedProfile.resolution;
                                selectedBitrateMbps = selectedProfile.bitrateMbps;
                                availableFps = List<int>.from(fpsOptions);
                                if (availableFps.contains(selectedProfile.fps)) {
                                  selectedFps = selectedProfile.fps;
                                } else {
                                  selectedFps = availableFps.last;
                                  selectedQualityProfileId =
                                      AppSettingsProvider.customQualityProfileId;
                                }
                              });
                            }();
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildSettingsLabel('Recording quality preset'),
                        DropdownButtonFormField<String>(
                          initialValue: selectedQualityProfileId,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: [
                            const DropdownMenuItem<String>(
                              value: AppSettingsProvider.customQualityProfileId,
                              child: Text('Custom'),
                            ),
                            ...AppSettingsProvider
                                .qualityProfilesForTier(selectedPresetTier)
                                .map(
                              (profile) => DropdownMenuItem<String>(
                                value: profile.id,
                                child: Text(profile.label),
                              ),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setModalState(() => selectedQualityProfileId = value);

                            if (value ==
                                AppSettingsProvider.customQualityProfileId) {
                              return;
                            }

                            final profile = AppSettingsProvider.profileById(value);
                            if (profile == null) {
                              return;
                            }

                            setModalState(() => selectedPresetTier = profile.tier);

                            () async {
                              final fpsOptions = await cameraProvider
                                  .getSupportedFpsOptionsForPreset(
                                preset: AppSettingsProvider.toResolutionPreset(
                                    profile.resolution),
                              );
                              if (!mounted) {
                                return;
                              }
                              setModalState(() {
                                selectedResolution = profile.resolution;
                                selectedBitrateMbps = profile.bitrateMbps;
                                availableFps = List<int>.from(fpsOptions);
                                if (availableFps.contains(profile.fps)) {
                                  selectedFps = profile.fps;
                                } else {
                                  selectedFps = availableFps.last;
                                  selectedQualityProfileId =
                                      AppSettingsProvider.customQualityProfileId;
                                }
                              });
                            }();
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildSettingsLabel('Recording resolution'),
                        DropdownButtonFormField<int>(
                          initialValue: selectedResolution,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: AppSettingsProvider.resolutionOptions
                              .map(
                                (resolution) => DropdownMenuItem<int>(
                                  value: resolution,
                                  child: Text(AppSettingsProvider.resolutionLabel(
                                      resolution)),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setModalState(() {
                              selectedResolution = value;
                              selectedQualityProfileId =
                                  AppSettingsProvider.customQualityProfileId;
                            });

                            () async {
                              final fpsOptions = await cameraProvider
                                  .getSupportedFpsOptionsForPreset(
                                preset: AppSettingsProvider.toResolutionPreset(
                                    value),
                              );
                              if (!mounted) {
                                return;
                              }
                              setModalState(() {
                                availableFps = List<int>.from(fpsOptions);
                                if (!availableFps.contains(selectedFps)) {
                                  selectedFps = availableFps.last;
                                }
                              });
                            }();
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildSettingsLabel('Frame rate (FPS)'),
                        DropdownButtonFormField<int>(
                          initialValue: selectedFps,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: availableFps
                              .map(
                                (fps) => DropdownMenuItem<int>(
                                  value: fps,
                                  child: Text('$fps FPS'),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setModalState(() {
                              selectedFps = value;
                              selectedQualityProfileId =
                                  AppSettingsProvider.customQualityProfileId;
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildSettingsLabel('Video bitrate'),
                        DropdownButtonFormField<int>(
                          initialValue: selectedBitrateMbps,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: AppSettingsProvider.bitrateOptionsMbps
                              .map(
                                (mbps) => DropdownMenuItem<int>(
                                  value: mbps,
                                  child: Text('$mbps Mbps'),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setModalState(() {
                              selectedBitrateMbps = value;
                              selectedQualityProfileId =
                                  AppSettingsProvider.customQualityProfileId;
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildSettingsLabel('Segment length'),
                        DropdownButtonFormField<int>(
                          initialValue: segmentMinutes,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: AppSettingsProvider.segmentMinutesOptions
                              .map(
                                (minutes) => DropdownMenuItem<int>(
                                  value: minutes,
                                  child: Text('$minutes min per segment'),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setModalState(() => segmentMinutes = value);
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildSettingsLabel('Loop buffer size'),
                        DropdownButtonFormField<int>(
                          initialValue: loopSegmentCount,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: AppSettingsProvider.loopSegmentCountOptions
                              .map(
                                (segments) => DropdownMenuItem<int>(
                                  value: segments,
                                  child: Text('$segments segments'),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setModalState(() => loopSegmentCount = value);
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildSettingsLabel('Speed UI refresh'),
                        DropdownButtonFormField<int>(
                          initialValue: speedRefreshMs,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: const [100, 200, 300, 500]
                              .map(
                                (ms) => DropdownMenuItem<int>(
                                  value: ms,
                                  child: Text('$ms ms'),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setModalState(() => speedRefreshMs = value);
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildSettingsLabel('Incident sensitivity'),
                        DropdownButtonFormField<IncidentSensitivity>(
                          initialValue: incidentSensitivity,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: IncidentSensitivity.values
                              .map(
                                (sensitivity) =>
                                    DropdownMenuItem<IncidentSensitivity>(
                                  value: sensitivity,
                                  child: Text(AppSettingsProvider
                                      .incidentSensitivityLabel(sensitivity)),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setModalState(() => incidentSensitivity = value);
                          },
                        ),
                        const SizedBox(height: 8),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          activeThumbColor: Colors.blue,
                          activeTrackColor: Colors.blue.withValues(alpha: 0.35),
                          value: audioEnabled,
                          title: const Text(
                            'Record audio',
                            style: TextStyle(color: Colors.white),
                          ),
                          subtitle: const Text(
                            'Disable for lower CPU and storage usage',
                            style: TextStyle(color: Colors.white70),
                          ),
                          onChanged: (value) {
                            setModalState(() => audioEnabled = value);
                          },
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () {
                              Navigator.of(context).pop(
                                _SettingsFormResult(
                                  resolution: selectedResolution,
                                  fps: selectedFps,
                                  bitrateMbps: selectedBitrateMbps,
                                  audioEnabled: audioEnabled,
                                  speedRefreshMs: speedRefreshMs,
                                  segmentMinutes: segmentMinutes,
                                  loopSegmentCount: loopSegmentCount,
                                  incidentSensitivity: incidentSensitivity,
                                ),
                              );
                            },
                            style: ElevatedButton.styleFrom(
                              minimumSize: const Size(double.infinity, 52),
                              backgroundColor: Colors.blue,
                            ),
                            child: const Text(
                              'SAVE SETTINGS',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (result == null || !mounted) {
      return;
    }

    final matchedProfile = AppSettingsProvider.findMatchingQualityProfile(
      resolution: result.resolution,
      fps: result.fps,
      bitrateMbps: result.bitrateMbps,
    );
    if (matchedProfile != null) {
      await settings.updateRecordingQualityProfile(matchedProfile.id);
    } else {
      await settings.updateRecordingResolution(result.resolution);
      await settings.updateRecordingFps(result.fps);
      await settings.updateVideoBitrateMbps(result.bitrateMbps);
    }
    await settings.updateAudioEnabled(result.audioEnabled);
    await settings.updateSpeedRefreshMs(result.speedRefreshMs);
    await settings.updateSegmentMinutes(result.segmentMinutes);
    await settings.updateLoopSegmentCount(result.loopSegmentCount);
    await settings.updateIncidentSensitivity(result.incidentSensitivity);

    if (!mounted) {
      return;
    }

    final telemetry = context.read<TelemetryProvider>();
    telemetry.setSpeedUiRefreshInterval(
      Duration(milliseconds: result.speedRefreshMs),
    );
    telemetry.setIncidentDetectionConfig(
      triggerGForce: settings.incidentTriggerGForce,
      debounce: settings.incidentDebounce,
    );

    final camera = context.read<CameraProvider>();
    final applied = await camera.applyRecordingSettings(
      resolutionPreset: AppSettingsProvider.toResolutionPreset(result.resolution),
      recordingFps: result.fps,
      videoBitrateBps: result.bitrateMbps * 1000 * 1000,
      audioEnabled: result.audioEnabled,
      segmentDurationMinutes: result.segmentMinutes,
      maxRollingSegments: result.loopSegmentCount,
    );

    if (applied && camera.recordingFps != result.fps) {
      await settings.updateRecordingFps(camera.recordingFps);
    }

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          applied
              ? 'Settings applied: ${result.resolution}p, ${camera.recordingFps} FPS, ${result.bitrateMbps}Mbps, ${result.segmentMinutes}m segments, loop ${result.loopSegmentCount} segments'
              : 'Stop recording first to apply camera settings',
        ),
      ),
    );
  }

  Widget _buildActiveProfileBar() {
    return Consumer<AppSettingsProvider>(
      builder: (context, settings, _) {
        final chips = <Widget>[
          _buildProfileChip('${settings.recordingResolution}p'),
          _buildProfileChip('${settings.recordingFps} FPS'),
          _buildProfileChip('${settings.videoBitrateMbps} Mbps'),
          _buildProfileChip(settings.audioEnabled ? 'Audio On' : 'Audio Off'),
          _buildProfileChip(
              '${settings.segmentMinutes}m x ${settings.loopSegmentCount} loop'),
            _buildProfileChip(
              'Incident ${settings.incidentSensitivity.name.toUpperCase()}'),
          _buildProfileChip('Speed ${settings.speedRefreshMs}ms'),
        ];

        final showHighSensitivityWarning =
            settings.incidentSensitivity == IncidentSensitivity.high;

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            border: Border(
              bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 34,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: chips.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, index) => chips[index],
                ),
              ),
              if (showHighSensitivityWarning)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'High incident sensitivity may increase auto-lock frequency.',
                    style: TextStyle(
                      color: Colors.orange.withValues(alpha: 0.9),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildProfileChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  InputDecoration _settingsInputDecoration() {
    return InputDecoration(
      filled: true,
      fillColor: const Color(0xFF1B1B1B),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _buildSettingsLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildCameraPreview() {
    return Consumer<CameraProvider>(
      builder: (context, camera, _) {
        if (!camera.isInitialized || camera.controller == null) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }

        final controller = camera.controller!;
        final portraitAspectRatio = 1 / controller.value.aspectRatio;

        return Stack(
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: portraitAspectRatio,
                      child: CameraPreview(controller),
                    ),
                  ),
                ),
              ),
            ),
            if (camera.isRecording)
              Positioned(
                top: 12,
                left: 12,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'REC',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildTelemetryStats() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          Selector<TelemetryProvider, String>(
            selector: (_, telemetry) =>
                '${telemetry.currentData.speed.toStringAsFixed(0)} km/h',
            builder: (context, speed, _) {
              return _buildStatItem(
                icon: Icons.speed,
                label: 'Speed',
                value: speed,
              );
            },
          ),
          Consumer<CameraProvider>(
            builder: (context, camera, _) {
              return StreamBuilder<Duration>(
                stream: camera.timerStream,
                initialData: camera.elapsedTime,
                builder: (context, snapshot) {
                  final duration = snapshot.data ?? Duration.zero;
                  final hours = duration.inHours;
                  final minutes = duration.inMinutes.remainder(60);
                  final seconds = duration.inSeconds.remainder(60);
                  final formattedTime =
                      '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';

                  return _buildStatItem(
                    icon: Icons.timer,
                    label: 'Duration',
                    value: formattedTime,
                  );
                },
              );
            },
          ),
          Selector<TelemetryProvider, String>(
            selector: (_, telemetry) =>
                '${telemetry.rideDistanceKm.toStringAsFixed(2)} km',
            builder: (context, distance, _) {
              return _buildStatItem(
                icon: Icons.route,
                label: 'Distance',
                value: distance,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Column(
      children: [
        Icon(icon, color: Colors.blue, size: 24),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: Colors.grey[400],
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Consumer2<CameraProvider, TelemetryProvider>(
            builder: (context, camera, telemetry, _) {
              _handleIncidentAutoLock(camera: camera, telemetry: telemetry);
              return ElevatedButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  if (camera.isRecording) {
                    final videoPath = await camera.stopRecording();
                    if (!mounted) {
                      return;
                    }

                    if (videoPath != null) {
                      final telemetryPath =
                          await telemetry.stopRideSessionAndPersist(
                        videoPath,
                        segmentPaths: camera.lastSessionSegmentPaths,
                        lockedSegmentPaths: camera.lockedSegmentPaths,
                      );
                      if (!mounted) {
                        return;
                      }

                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            telemetryPath == null
                                ? 'Video saved to:\n$videoPath'
                                : 'Video saved:\n$videoPath\nTelemetry saved:\n$telemetryPath',
                          ),
                          duration: const Duration(seconds: 4),
                        ),
                      );
                    } else {
                      telemetry.cancelRideSession();
                    }
                  } else {
                    await camera.startRecording();
                    if (camera.isRecording) {
                      telemetry.startRideSession();
                    }
                    if (!mounted) {
                      return;
                    }

                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                            'Recording started\nSaving to: ${camera.recordingsDirectory}'),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      camera.isRecording ? Colors.red : Colors.blue,
                  minimumSize: const Size(double.infinity, 52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  camera.isRecording ? 'STOP RECORDING' : 'START RECORDING',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Consumer<CameraProvider>(
            builder: (context, camera, _) {
              return Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const RidesListScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.video_library_outlined,
                          color: Colors.blue),
                      label: const Text(
                        'HISTORY',
                        style: TextStyle(fontSize: 14, color: Colors.blue),
                      ),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(44),
                        side: const BorderSide(color: Colors.blue),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: camera.isRecording
                          ? () {
                              camera.markIncident(
                                protectPastSegments: 2,
                                protectCurrentSegment: true,
                                reason: 'manual-emergency',
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                      'Emergency lock enabled. Protected segments: ${camera.lockedSegmentCount}'),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            }
                          : null,
                      icon: const Icon(Icons.warning_amber_rounded,
                          color: Colors.orange),
                      label: const Text(
                        'LOCK',
                        style: TextStyle(fontSize: 14, color: Colors.orange),
                      ),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(44),
                        side: BorderSide(
                          color: camera.isRecording
                              ? Colors.orange
                              : Colors.orange.withValues(alpha: 0.3),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SettingsFormResult {
  const _SettingsFormResult({
    required this.resolution,
    required this.fps,
    required this.bitrateMbps,
    required this.audioEnabled,
    required this.speedRefreshMs,
    required this.segmentMinutes,
    required this.loopSegmentCount,
    required this.incidentSensitivity,
  });

  final int resolution;
  final int fps;
  final int bitrateMbps;
  final bool audioEnabled;
  final int speedRefreshMs;
  final int segmentMinutes;
  final int loopSegmentCount;
  final IncidentSensitivity incidentSensitivity;
}
