import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../telemetry/models/telemetry_data.dart';
import '../../../core/theme/tokens.dart';
import 'route_map_view.dart';

/// Builds the route map shown while [RouteMapPanel] is expanded.
typedef RouteMapBuilder =
    Widget Function(
      BuildContext context,
      List<TelemetryData> samples,
      double height,
      ValueListenable<TelemetryData?> currentSample,
    );

/// Builds a [RouteMapView] for the route in `samples`, its marker following
/// `currentSample`.
Widget defaultRouteMapBuilder(
  BuildContext context,
  List<TelemetryData> samples,
  double height,
  ValueListenable<TelemetryData?> currentSample,
) => RouteMapView(
  telemetryData: samples,
  height: height,
  currentSampleListenable: currentSample,
);

/// The "Route Map" card under the video: a header button that expands or
/// collapses the map.
///
/// The map is built only while [expanded], because a built map fetches tiles
/// from the network; collapsed, the card holds an empty box and nothing is
/// built or laid out for the map. The map is fed the playback position's
/// sample through [currentSample] and is not rebuilt when it changes.
class RouteMapPanel extends StatelessWidget {
  /// Creates the panel for the route in [samples].
  const RouteMapPanel({
    super.key,
    required this.samples,
    required this.currentSample,
    required this.mapHeight,
    required this.expanded,
    required this.onToggle,
    this.mapBuilder = defaultRouteMapBuilder,
  });

  /// Telemetry samples of the ride; the route is drawn from their GPS fixes.
  final List<TelemetryData> samples;

  /// The sample at the playback position, drawn as the current marker.
  final ValueListenable<TelemetryData?> currentSample;

  /// Height of the map while expanded.
  final double mapHeight;

  /// Whether the map is shown.
  final bool expanded;

  /// The rider pressed the header.
  final VoidCallback onToggle;

  /// Builds the map; defaults to [RouteMapView]. Tests replace it.
  final RouteMapBuilder mapBuilder;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
      decoration: BoxDecoration(
        color: MotoColors.surface,
        borderRadius: BorderRadius.circular(MotoRadii.sm),
        border: Border.all(color: MotoColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            label: 'Route map',
            onTap: onToggle,
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onToggle,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    const Icon(
                      Icons.map_outlined,
                      size: 20,
                      color: MotoColors.dim,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Route Map',
                        style: MotoFonts.bodyStyle(
                          15,
                          weight: FontWeight.w600,
                          color: MotoColors.text,
                        ),
                      ),
                    ),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      color: MotoColors.dim,
                      size: 22,
                    ),
                  ],
                ),
              ),
            ),
          ),
          // The map is only built while expanded: a built map fetches tiles
          // from the network.
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: mapBuilder(
                      context,
                      samples,
                      mapHeight,
                      currentSample,
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
