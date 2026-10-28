// lib/features/map/widgets/osm_attribution.dart

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:url_launcher/url_launcher.dart';

import '../map_source_config.dart';

/// Opens [uri] in the system browser; returns whether a browser was started.
///
/// The default for [OsmAttribution.openLink].
Future<bool> openInBrowser(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// OpenStreetMap attribution layer for a `FlutterMap`.
///
/// Draws flutter_map's [RichAttributionWidget]: an info button that opens a
/// box with "© OpenStreetMap contributors". Tapping that line opens
/// [MapSourceConfig.copyrightUrl] in the browser, as the OpenStreetMap
/// attribution guidelines ask. Place it as the last child of every
/// `FlutterMap` that shows OpenStreetMap tiles.
class OsmAttribution extends StatelessWidget {
  /// Creates the attribution layer. [openLink] opens the copyright page and
  /// defaults to [openInBrowser]; tests replace it.
  const OsmAttribution({super.key, this.openLink = openInBrowser});

  /// Opens a URL in the browser and reports whether it succeeded.
  final Future<bool> Function(Uri uri) openLink;

  Future<void> _openCopyrightPage(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    var opened = false;
    try {
      opened = await openLink(Uri.parse(MapSourceConfig.copyrightUrl));
    } catch (_) {
      opened = false;
    }
    if (!opened) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text(
            'Could not open the link. Visit '
            'openstreetmap.org/copyright in a browser.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return RichAttributionWidget(
      alignment: AttributionAlignment.bottomRight,
      attributions: [
        TextSourceAttribution(
          MapSourceConfig.attributionText,
          onTap: () => _openCopyrightPage(context),
        ),
      ],
    );
  }
}
