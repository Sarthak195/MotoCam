class MapSourceConfig {
  const MapSourceConfig._();

  // Keep provider selection centralized so switching providers is a config change.
  static const String tileUrlTemplate =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String attribution = '© OpenStreetMap contributors';
  static const String userAgentPackageName = 'com.example.motocam';
  static const double maxZoom = 19;
  static const int maxNativeZoom = 19;
}
