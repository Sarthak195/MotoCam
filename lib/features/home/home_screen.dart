// lib/features/home/home_screen.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../map/widgets/map_view.dart';
import '../camera/widgets/camera_preview_pip.dart';
import '../telemetry/widgets/speed_overlay.dart';
import '../camera/widgets/recording_indicator.dart';
import '../camera/providers/camera_provider.dart';
import '../telemetry/providers/telemetry_provider.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    final cameraProvider = context.read<CameraProvider>();
    final telemetryProvider = context.read<TelemetryProvider>();
    
    await cameraProvider.initializeCamera();
    telemetryProvider.startAccelerometerTracking();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 🗺️ Full-screen map (background)
          const Positioned.fill(
            child: MapView(),
          ),

          // 📷 Camera PiP (top-right corner)
          Positioned(
            top: 60,
            right: 16,
            child: CameraPreviewPip(),  // REMOVE const here
          ),

          // 🏃 Speed overlay (top-center)
          const Positioned(
            top: 60,
            left: 0,
            right: 0,
            child: SpeedOverlay(),
          ),

          // 🔴 Recording indicator (top-left)
          Positioned(
            top: 60,
            left: 16,
            child: Consumer<CameraProvider>(
              builder: (context, camera, _) {
                return RecordingIndicator(
                  isRecording: camera.isRecording,
                );
              },
            ),
          ),

          // 🎮 Bottom controls
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _buildBottomControls(),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.black.withOpacity(0.7),
            Colors.transparent,
          ],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildControlButton(
            icon: Icons.my_location,
            label: 'Center',
            onPressed: () {
              // Center map on current location
            },
          ),
          _buildControlButton(
            icon: Icons.navigation,
            label: 'Navigate',
            onPressed: () {
              // Open route planning
            },
          ),
          _buildControlButton(
            icon: Icons.folder,
            label: 'Rides',
            onPressed: () {
              // Open ride history
            },
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(icon, color: Colors.white),
          onPressed: onPressed,
          iconSize: 32,
        ),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}