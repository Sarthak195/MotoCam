import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/utils/format_utils.dart';
import '../camera/providers/camera_provider.dart';
import 'models/ride_history_loader.dart';
import 'models/ride_record.dart';
import 'ride_playback_screen.dart';
import 'widgets/playback_timeline.dart';

/// Ride History: lists recorded rides (locked clips first) with their
/// summary, integrity status and lock state, and opens playback on tap.
class RidesListScreen extends StatefulWidget {
  /// Creates the Ride History screen.
  const RidesListScreen({super.key});

  @override
  State<RidesListScreen> createState() => _RidesListScreenState();
}

class _RidesListScreenState extends State<RidesListScreen> {
  late Future<List<RideRecord>> _ridesFuture;
  bool _isOpeningRide = false;
  final Set<String> _lockUpdatesInFlight = <String>{};
  final Set<String> _deletesInFlight = <String>{};

  Widget _buildStatusBadge({required String label, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  bool _hasLoadedRides = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hasLoadedRides) {
      _hasLoadedRides = true;
      _ridesFuture = _loadRides();
    }
  }

  Future<List<RideRecord>> _loadRides() async {
    final cameraProvider = context.read<CameraProvider>();
    final recordings = await cameraProvider.getRecordings();
    final recordingPaths = recordings
        .whereType<File>()
        .map((file) => file.path)
        .toList(growable: false);
    return _loadRideHistoryInBackground(recordingPaths);
  }

  /// Parses and hash-checks the rides on a background isolate so long
  /// histories do not block the UI thread. Static so the isolate closure
  /// captures only [recordingPaths].
  static Future<List<RideRecord>> _loadRideHistoryInBackground(
    List<String> recordingPaths,
  ) async {
    try {
      return await Isolate.run(() => loadRideHistory(recordingPaths));
    } catch (_) {
      // Fall back to the current isolate if the background one fails.
      return loadRideHistory(recordingPaths);
    }
  }

  String _formatDuration(Duration duration) => formatElapsed(duration);

  String _lockKeyFor(RideRecord ride) => ride.telemetryPath ?? ride.videoPath;

  /// Whether [RideRecord.setLockState] may run for [ride]: it refuses rides
  /// that failed the integrity check or have quarantined paths.
  static bool _canChangeLockState(RideRecord ride) =>
      ride.integrity.status != RideIntegrityStatus.modified &&
      !ride.hasQuarantinedSegments;

  Future<void> _confirmAndUnlock(RideRecord ride) async {
    final lockKey = _lockKeyFor(ride);
    if (_lockUpdatesInFlight.contains(lockKey)) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unlock this clip?'),
        content: const Text(
          'Unlocking only removes the lock marker. MotoCam never deletes '
          'past rides automatically; the ride moves from Locked Clips to '
          'All Rides.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _lockUpdatesInFlight.add(lockKey);
    });

    var unlocked = false;
    try {
      unlocked = await ride.setLockState(false);
    } catch (_) {
      unlocked = false;
    }
    if (!mounted) {
      return;
    }

    setState(() {
      _lockUpdatesInFlight.remove(lockKey);
      if (unlocked) {
        _ridesFuture = _loadRides();
      }
    });
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          unlocked
              ? 'Clip unlocked.'
              : 'Could not unlock this clip: its files failed the integrity check or could not be saved.',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Files that make up [ride] on disk: its trusted segment files, its main
  /// video and its ride JSON. Quarantined paths (outside the recordings
  /// directory) are never included.
  static List<String> _filesOfRide(RideRecord ride) {
    final paths = <String>{
      ...ride.segmentPaths,
      ride.videoPath,
      if (ride.telemetryPath != null) ride.telemetryPath!,
    };
    paths.removeAll(ride.quarantinedSegmentPaths);
    return paths.where((path) => path.trim().isNotEmpty).toList();
  }

  Future<void> _confirmAndDelete(RideRecord ride) async {
    final key = _lockKeyFor(ride);
    if (_deletesInFlight.contains(key)) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    // A locked ride whose lock cannot be removed (failed integrity check
    // or quarantined paths) may still be deleted, after a warning;
    // otherwise it could never be removed in-app.
    final lockIsStuck = ride.isLocked && !_canChangeLockState(ride);
    if (ride.isLocked && !lockIsStuck) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'This ride has locked clips. Unlock it first to delete it.',
          ),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    final files = _filesOfRide(ride);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this ride?'),
        content: Text(
          '${lockIsStuck ? 'This ride has locked clips and failed the integrity check, so it cannot be unlocked. ' : ''}'
          'This permanently deletes the ride\'s ${ride.segmentPaths.length} '
          'video segment(s) and its telemetry from this device. Copies '
          'already exported to the gallery are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _deletesInFlight.add(key);
    });
    var failed = 0;
    for (final path in files) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _deletesInFlight.remove(key);
      _ridesFuture = _loadRides();
    });
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? 'Ride deleted.'
              : 'Ride deleted, but $failed file(s) could not be removed.',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// How much of the ride's duration has video, when loop recording
  /// overwrote part of it (for example the start of a long ride); `null`
  /// when the video covers the whole ride or no timeline is stored.
  String? _videoCoverageText(RideRecord ride) {
    final totalMs = ride.duration.inMilliseconds;
    if (ride.segmentTimeline.isEmpty || totalMs <= 0) {
      return null;
    }
    final gaps = uncoveredRanges(
      timeline: ride.segmentTimeline,
      totalMs: totalMs,
    );
    if (gaps.isEmpty) {
      return null;
    }
    final missingMs = gaps.fold<int>(0, (sum, gap) => sum + gap.lengthMs);
    final coveredMs = (totalMs - missingMs).clamp(0, totalMs);
    return 'Video: ${_formatDuration(Duration(milliseconds: coveredMs))} '
        'of ${_formatDuration(ride.duration)} kept';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ride History')),
      body: FutureBuilder<List<RideRecord>>(
        future: _ridesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Text('Failed to load rides: ${snapshot.error}'),
            );
          }

          final rides = snapshot.data ?? const <RideRecord>[];
          if (rides.isEmpty) {
            return const Center(
              child: Text('No rides found yet. Record a ride to see it here.'),
            );
          }

          final lockedRides = rides.where((ride) => ride.isLocked).toList();
          final otherRides = rides.where((ride) => !ride.isLocked).toList();

          return RefreshIndicator(
            onRefresh: () async {
              setState(() {
                _ridesFuture = _loadRides();
              });
              await _ridesFuture;
            },
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (lockedRides.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Locked Clips',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  ...lockedRides
                      .map((ride) => _buildRideCard(context, ride))
                      .expand((card) => [card, const SizedBox(height: 10)]),
                ],
                const Padding(
                  padding: EdgeInsets.only(bottom: 8, top: 6),
                  child: Text(
                    'All Rides',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                ...otherRides
                    .map((ride) => _buildRideCard(context, ride))
                    .expand((card) => [card, const SizedBox(height: 10)]),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _buildBadges(RideRecord ride) {
    final hasTelemetry = ride.telemetryPath != null;
    final status = ride.integrity.status;
    return [
      if (!hasTelemetry)
        _buildStatusBadge(
          label: 'VIDEO ONLY (RECOVERED)',
          color: Colors.blueGrey,
        ),
      if (status == RideIntegrityStatus.modified)
        _buildStatusBadge(label: 'INTEGRITY WARNING', color: Colors.redAccent)
      // GPS from a mock-location provider: never shown as unmodified.
      else if (ride.mockLocationDetected)
        _buildStatusBadge(label: 'SIMULATED GPS', color: Colors.purpleAccent)
      // The list checks only the ride data; video files are hashed when
      // the ride is opened.
      else if (status == RideIntegrityStatus.verified)
        _buildStatusBadge(label: 'DATA UNMODIFIED', color: Colors.lightGreen)
      else if (hasTelemetry)
        _buildStatusBadge(label: 'UNVERIFIED', color: Colors.grey),
      if (ride.hasQuarantinedSegments)
        _buildStatusBadge(
          label: 'QUARANTINED ${ride.quarantinedSegmentPaths.length}',
          color: Colors.deepOrangeAccent,
        ),
      if (ride.hasMissingSegments)
        _buildStatusBadge(label: 'INCOMPLETE', color: Colors.amber),
      // A checkpoint written during the ride: the app stopped before the
      // ride was saved normally.
      if (hasTelemetry && !ride.isSessionComplete)
        _buildStatusBadge(label: 'RECOVERED (INCOMPLETE)', color: Colors.amber),
      if (ride.isLocked)
        _buildStatusBadge(label: 'LOCKED', color: Colors.orange),
    ];
  }

  String _integrityText(RideRecord ride) {
    switch (ride.integrity.status) {
      case RideIntegrityStatus.verified:
        return 'Integrity: ride data unmodified since recording '
            '(videos are checked on playback)';
      case RideIntegrityStatus.modified:
        return 'Integrity: check failed';
      case RideIntegrityStatus.unknown:
        if (ride.telemetryPath == null) {
          return 'Integrity: not available';
        }
        return ride.isSessionComplete
            ? 'Integrity: not available (recorded by an older version)'
            : 'Integrity: not available (ride was not saved completely)';
    }
  }

  String _integrityLine(RideRecord ride) {
    final text = _integrityText(ride);
    if (!ride.mockLocationDetected) {
      return text;
    }
    return '$text. GPS came from a simulated (mock) location provider.';
  }

  Widget _buildRideCard(BuildContext context, RideRecord ride) {
    final hasTelemetry = ride.telemetryPath != null;
    final segmentCount = ride.segmentPaths.length;
    final availableSegmentCount = ride.availableSegmentCount;
    final isUpdatingLock = _lockUpdatesInFlight.contains(_lockKeyFor(ride));
    final canToggleLockState = _canChangeLockState(ride) && !isUpdatingLock;
    final badges = _buildBadges(ride);
    final videoCoverage = _videoCoverageText(ride);
    final isDeleting = _deletesInFlight.contains(_lockKeyFor(ride));

    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(12),
        title: Text(
          DateFormat('dd MMM yyyy, hh:mm a').format(ride.createdAt),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 2),
            Text(
              ride.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (badges.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: badges),
            ],
            const SizedBox(height: 6),
            Text('Distance: ${ride.distanceKm.toStringAsFixed(2)} km'),
            Text('Duration: ${_formatDuration(ride.duration)}'),
            if (videoCoverage != null)
              Text(
                videoCoverage,
                style: const TextStyle(color: Colors.blueGrey),
              ),
            Text('Max speed: ${ride.maxSpeedKmh.toStringAsFixed(1)} km/h'),
            Text('Avg speed: ${ride.averageSpeedKmh.toStringAsFixed(1)} km/h'),
            Text(
              availableSegmentCount == segmentCount
                  ? 'Segments: $segmentCount'
                  : 'Segments: $availableSegmentCount of $segmentCount available',
            ),
            Text('Samples: ${ride.samples.length}'),
            Text(_integrityLine(ride)),
            if (ride.hasQuarantinedSegments)
              Text(
                'Quarantined paths: ${ride.quarantinedSegmentPaths.length}',
                style: const TextStyle(color: Colors.deepOrangeAccent),
              ),
            Text(
              hasTelemetry
                  ? 'Telemetry: Available'
                  : 'Telemetry: Not available',
            ),
          ],
        ),
        trailing: SizedBox(
          width: ride.isLocked ? 116 : 64,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (ride.isLocked && isUpdatingLock)
                const Padding(
                  padding: EdgeInsets.all(4),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (ride.isLocked)
                IconButton(
                  tooltip: canToggleLockState
                      ? 'Unlock clip'
                      : 'Integrity warning: lock state changes disabled',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  iconSize: 20,
                  onPressed: canToggleLockState
                      ? () => _confirmAndUnlock(ride)
                      : null,
                  icon: const Icon(Icons.lock_open),
                ),
              if (isDeleting)
                const Padding(
                  padding: EdgeInsets.all(4),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  tooltip: ride.isLocked && _canChangeLockState(ride)
                      ? 'Unlock the ride to delete it'
                      : 'Delete ride',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  iconSize: 20,
                  onPressed: () => _confirmAndDelete(ride),
                  icon: const Icon(Icons.delete_outline),
                ),
              const Icon(Icons.play_circle_outline),
            ],
          ),
        ),
        onTap: () async {
          if (_isOpeningRide) {
            return;
          }
          _isOpeningRide = true;
          try {
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => RidePlaybackScreen(ride: ride)),
            );
          } finally {
            _isOpeningRide = false;
          }
        },
      ),
    );
  }
}
