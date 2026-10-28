import 'package:latlong2/latlong.dart';

import '../telemetry/models/telemetry_data.dart';

/// Maximum number of points plotted for one route before downsampling.
const int maxPlottedRoutePoints = 1800;

/// Returns the GPS position of [sample], or `null` when it is not a real fix.
///
/// Samples with `hasFix == false` (no fix yet, or the last fix is stale; old
/// files infer this for (0, 0) samples) are rejected. A sample at exactly
/// (0, 0) is also treated as "no fix yet", and coordinates outside the
/// WGS 84 range are rejected as well.
LatLng? latLngFromSample(TelemetryData? sample) {
  if (sample == null || !sample.hasFix) {
    return null;
  }

  final lat = sample.latitude;
  final lon = sample.longitude;
  if (lat == 0 && lon == 0) {
    return null;
  }
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
    return null;
  }
  return LatLng(lat, lon);
}

/// Returns the samples of [samples] that carry a real GPS fix, in order.
List<TelemetryData> samplesWithGpsFix(List<TelemetryData> samples) {
  return samples
      .where((sample) => latLngFromSample(sample) != null)
      .toList(growable: false);
}

/// Returns the GPS positions of all samples that carry a real fix, in order.
List<LatLng> routePointsFromSamples(List<TelemetryData> samples) {
  final points = <LatLng>[];
  for (final sample in samples) {
    final point = latLngFromSample(sample);
    if (point != null) {
      points.add(point);
    }
  }
  return points;
}

/// Thins [points] to roughly [maxPoints] by keeping every n-th point.
///
/// The last point is always kept so the route still ends where the ride
/// ended, so the result can hold `maxPoints + 1` points.
List<LatLng> downsampleRoute(
  List<LatLng> points, {
  int maxPoints = maxPlottedRoutePoints,
}) {
  if (points.length <= maxPoints) {
    return points;
  }

  final sampled = <LatLng>[];
  final step = (points.length / maxPoints).ceil();
  for (var i = 0; i < points.length; i += step) {
    sampled.add(points[i]);
  }

  if (sampled.last != points.last) {
    sampled.add(points.last);
  }
  return sampled;
}
