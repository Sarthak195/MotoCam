import 'package:flutter/material.dart';

import '../../../core/utils/format_utils.dart';
import '../models/ride_record.dart';

/// The "Size: 1.08 GB" detail line of a Ride History card: the total size
/// of the ride's segment files that exist. Nothing is shown when the size
/// is unknown or zero, rather than a wrong number.
class RideSizeLine extends StatelessWidget {
  /// Creates the line for [ride].
  const RideSizeLine({super.key, required this.ride});

  /// The ride whose [RideRecord.totalSegmentBytes] is shown.
  final RideRecord ride;

  @override
  Widget build(BuildContext context) {
    final bytes = ride.totalSegmentBytes;
    if (bytes == null || bytes <= 0) {
      return const SizedBox.shrink();
    }
    return Text('Size: ${formatFileSize(bytes)}');
  }
}
