/// Centralized tile-provider configuration for all map widgets.
///
/// Switching map providers (e.g. OpenStreetMap → Mapbox) requires changing
/// only the constants in this class.
class MapSourceConfig {
  const MapSourceConfig._();

  /// Tile URL template passed to flutter_map's `TileLayer`.
  static const String tileUrlTemplate =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// Host that receives tile requests; named in the online-map disclosure.
  static const String tileHost = 'tile.openstreetmap.org';

  /// Short attribution drawn on the map.
  static const String attribution = '© OpenStreetMap contributors';

  /// Page with the full OpenStreetMap copyright and licence information.
  static const String copyrightUrl = 'https://www.openstreetmap.org/copyright';

  /// Licence summary shown when the rider taps the attribution.
  static const String licenceSummary =
      'Map data © OpenStreetMap contributors, available under the Open '
      'Database License (ODbL). Map tiles are provided by the OpenStreetMap '
      'Foundation. Full copyright and licence details: $copyrightUrl';

  /// Application id that identifies this app in the tile User-Agent.
  static const String userAgentPackageName = 'com.example.motocam';

  /// Public contact for the tile server operators, as the OSM tile usage
  /// policy asks for.
  static const String contactUrl = 'https://github.com/Sarthak195/MotoCam';

  /// User-Agent header sent with every tile request.
  static const String userAgent =
      'MotoCam ($userAgentPackageName; +$contactUrl) flutter_map';

  /// Deepest zoom level the map camera may reach.
  static const double maxZoom = 19;

  /// Deepest zoom level the tile server provides.
  static const int maxNativeZoom = 19;

  /// Upper bound, in bytes, of flutter_map's on-device tile cache.
  static const int maxTileCacheBytes = 25 * 1000 * 1000;
}
