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
  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    final settingsProvider = context.read<AppSettingsProvider>();
    final cameraProvider = context.read<CameraProvider>();
    final telemetryProvider = context.read<TelemetryProvider>();

    if (!settingsProvider.isLoaded) {
      await settingsProvider.load();
    }

    await cameraProvider.initializeCamera(
      resolutionPreset: settingsProvider.recordingQuality.toResolutionPreset(),
      recordingFps: settingsProvider.recordingFps,
      videoBitrateBps: settingsProvider.videoBitrateMbps * 1000 * 1000,
      audioEnabled: settingsProvider.audioEnabled,
    );

    telemetryProvider.setSpeedUiRefreshInterval(
      Duration(milliseconds: settingsProvider.speedRefreshMs),
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
      preset: settings.recordingQuality.toResolutionPreset(),
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
        RecordingQuality selectedQuality = settings.recordingQuality;
        int selectedFps = settings.recordingFps;
        int selectedBitrateMbps = settings.videoBitrateMbps;
        bool audioEnabled = settings.audioEnabled;
        int speedRefreshMs = settings.speedRefreshMs;
        List<int> availableFps = List<int>.from(initialFpsOptions);

        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                ),
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
                    _buildSettingsLabel('Video quality'),
                    DropdownButtonFormField<RecordingQuality>(
                      initialValue: selectedQuality,
                      dropdownColor: const Color(0xFF1B1B1B),
                      decoration: _settingsInputDecoration(),
                      items: RecordingQuality.values
                          .map(
                            (quality) => DropdownMenuItem<RecordingQuality>(
                              value: quality,
                              child: Text(quality.label),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setModalState(() => selectedQuality = value);

                        () async {
                          final fpsOptions = await cameraProvider
                              .getSupportedFpsOptionsForPreset(
                            preset: value.toResolutionPreset(),
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
                        setModalState(() => selectedFps = value);
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
                        setModalState(() => selectedBitrateMbps = value);
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
                              quality: selectedQuality,
                              fps: selectedFps,
                              bitrateMbps: selectedBitrateMbps,
                              audioEnabled: audioEnabled,
                              speedRefreshMs: speedRefreshMs,
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
            );
          },
        );
      },
    );

    if (result == null || !mounted) {
      return;
    }

    await settings.updateRecordingQuality(result.quality);
    await settings.updateRecordingFps(result.fps);
    await settings.updateVideoBitrateMbps(result.bitrateMbps);
    await settings.updateAudioEnabled(result.audioEnabled);
    await settings.updateSpeedRefreshMs(result.speedRefreshMs);

    if (!mounted) {
      return;
    }

    final telemetry = context.read<TelemetryProvider>();
    telemetry.setSpeedUiRefreshInterval(
      Duration(milliseconds: result.speedRefreshMs),
    );

    final camera = context.read<CameraProvider>();
    final applied = await camera.applyRecordingSettings(
      resolutionPreset: result.quality.toResolutionPreset(),
      recordingFps: result.fps,
      videoBitrateBps: result.bitrateMbps * 1000 * 1000,
      audioEnabled: result.audioEnabled,
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
              ? 'Settings applied: ${result.quality.label}, ${camera.recordingFps} FPS, ${result.bitrateMbps}Mbps, speed every ${result.speedRefreshMs}ms'
              : 'Stop recording first to apply camera settings',
        ),
      ),
    );
  }

  Widget _buildActiveProfileBar() {
    return Consumer<AppSettingsProvider>(
      builder: (context, settings, _) {
        final chips = <Widget>[
          _buildProfileChip(settings.recordingQuality.label),
          _buildProfileChip('${settings.recordingFps} FPS'),
          _buildProfileChip('${settings.videoBitrateMbps} Mbps'),
          _buildProfileChip(settings.audioEnabled ? 'Audio On' : 'Audio Off'),
          _buildProfileChip('Speed ${settings.speedRefreshMs}ms'),
        ];

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            border: Border(
              bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: chips,
          ),
        );
      },
    );
  }

  Widget _buildProfileChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
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

        return Stack(
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: camera.controller!.value.aspectRatio,
                child: CameraPreview(camera.controller!),
              ),
            ),
            if (camera.isRecording)
              Positioned(
                top: 16,
                left: 16,
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
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Consumer<CameraProvider>(
            builder: (context, camera, _) {
              return ElevatedButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final telemetry = context.read<TelemetryProvider>();
                  if (camera.isRecording) {
                    final videoPath = await camera.stopRecording();
                    if (!mounted) {
                      return;
                    }

                    if (videoPath != null) {
                      final telemetryPath =
                          await telemetry.stopRideSessionAndPersist(videoPath);
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
                  minimumSize: const Size(double.infinity, 56),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  camera.isRecording ? 'STOP RECORDING' : 'START RECORDING',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const RidesListScreen(),
                ),
              );
            },
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 56),
              side: const BorderSide(color: Colors.blue),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'VIEW RIDE HISTORY',
              style: TextStyle(fontSize: 16, color: Colors.blue),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsFormResult {
  const _SettingsFormResult({
    required this.quality,
    required this.fps,
    required this.bitrateMbps,
    required this.audioEnabled,
    required this.speedRefreshMs,
  });

  final RecordingQuality quality;
  final int fps;
  final int bitrateMbps;
  final bool audioEnabled;
  final int speedRefreshMs;
}
