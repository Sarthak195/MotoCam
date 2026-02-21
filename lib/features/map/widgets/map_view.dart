// lib/features/map/widgets/map_view.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../telemetry/providers/telemetry_provider.dart';

class MapView extends StatelessWidget {
  const MapView({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Consumer<TelemetryProvider>(
      builder: (context, telemetry, _) {
        final data = telemetry.currentData;
        
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.grey[900]!,
                Colors.black,
              ],
            ),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.map_outlined,
                  size: 100,
                  color: Colors.blue.withOpacity(0.3),
                ),
                const SizedBox(height: 24),
                Text(
                  'Map View',
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.1),
                    ),
                  ),
                  child: Column(
                    children: [
                      _buildInfoRow('Latitude', data.latitude.toStringAsFixed(6)),
                      const SizedBox(height: 8),
                      _buildInfoRow('Longitude', data.longitude.toStringAsFixed(6)),
                      const SizedBox(height: 8),
                      _buildInfoRow('Bearing', '${data.bearing.toStringAsFixed(1)}°'),
                      const SizedBox(height: 8),
                      _buildInfoRow('Acceleration', '${data.accelerationG.toStringAsFixed(2)}G'),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '🗺️ Maps will be enabled later',
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey[500],
            fontSize: 14,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.bold,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}