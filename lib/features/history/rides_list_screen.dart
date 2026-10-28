import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/services/ride_signing_service.dart';
import '../../core/utils/format_utils.dart';
import '../../core/utils/path_utils.dart' as path_utils;
import '../camera/providers/camera_provider.dart';
import '../camera/providers/recordings_migration.dart';
import 'models/ride_history_loader.dart';
import 'models/ride_index.dart';
import 'models/ride_record.dart';
import 'models/segment_verifier.dart';
import 'ride_playback_screen.dart';
import 'widgets/playback_timeline.dart';
import 'widgets/recordings_migration_banner.dart';

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

  /// Share of a running lock change's segment checks that are done, by
  /// lock key; `null` (indeterminate) until the first segment is checked.
  final Map<String, double?> _lockProgress = <String, double?>{};
  final Set<String> _deletesInFlight = <String>{};

  /// Video check state of each telemetry ride, by [rideIndexKey] of its
  /// telemetry path.
  Map<String, RideVideoCheck> _videoChecks = <String, RideVideoCheck>{};

  /// The ride index store this screen listens to, once resolved.
  RideIndexStore? _indexStore;

  /// The ride last opened for playback. Its segment check can still store
  /// a result after playback closed, so its video state is re-read on every
  /// index update.
  RideRecord? _openedRide;

  /// Counts [_refreshVideoCheck] calls, so an older refresh that finishes
  /// late does not overwrite a newer one.
  int _videoCheckRefreshes = 0;

  /// The move of rides into private storage, listened to so the list
  /// reloads when a run ends.
  RecordingsMigrationController? _migration;
  bool _wasMigrating = false;

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
      final migration = context.read<CameraProvider>().recordingsMigration;
      _migration = migration;
      _wasMigrating = migration.isRunning;
      migration.addListener(_onMigrationChanged);
      _ridesFuture = _loadRides();
    }
  }

  @override
  void dispose() {
    _indexStore?.removeListener(_onIndexChanged);
    _migration?.removeListener(_onMigrationChanged);
    super.dispose();
  }

  /// Reloads the list when a migration run ends (moved rides have new
  /// paths).
  void _onMigrationChanged() {
    final migrating = _migration?.isRunning ?? false;
    final ended = _wasMigrating && !migrating;
    _wasMigrating = migrating;
    if (ended && mounted) {
      setState(() {
        _ridesFuture = _loadRides();
      });
    }
  }

  /// While rides are being moved into private storage their files change
  /// paths, so opening, unlocking and deleting wait: shows a notice and
  /// returns `true` while a run is moving files.
  bool _refuseWhileMigrating() {
    if (!(_migration?.isRunning ?? false)) {
      return false;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Rides are being moved to private storage. Try again when the '
          'move finishes.',
        ),
        duration: Duration(seconds: 3),
      ),
    );
    return true;
  }

  void _onIndexChanged() {
    final ride = _openedRide;
    if (ride != null && mounted) {
      unawaited(_refreshVideoCheck(ride));
    }
  }

  Future<List<RideRecord>> _loadRides() async {
    final cameraProvider = context.read<CameraProvider>();
    final recordings = await cameraProvider.getRecordings();
    // A ride the migration is moving (or paused in the middle of) is left
    // out until it is whole in one root.
    final inFlight = cameraProvider.recordingsMigration.inFlightPaths;
    final recordingPaths = recordings
        .whereType<File>()
        .map((file) => file.path)
        .where((path) => !inFlight.contains(path_utils.normalizePath(path)))
        .toList(growable: false);
    final store = await RideIndexStore.shared();
    if (store != null && _indexStore == null && mounted) {
      _indexStore = store;
      store.addListener(_onIndexChanged);
    }
    // This phone's key and the rides it wrote signed: read here (platform
    // channel, SharedPreferences) and passed into the loader isolate.
    final signerContext = await loadRideSignerContext();
    final load = await _loadRideHistoryInBackground(
      recordingPaths,
      indexFilePath: store?.file.path,
      index: store?.loaded,
      signerContext: signerContext,
    );
    if (store != null) {
      // The UI isolate is the index's only writer.
      await store.read(adopt: load.readIndex);
      unawaited(
        store.update((index) {
          index.rides
            ..clear()
            ..addAll(load.rideEntries);
          index.pruneSegmentHashes();
        }),
      );
    }
    _videoChecks = load.videoChecks;
    return load.rides;
  }

  /// Loads the rides through the ride index on a background isolate so
  /// long histories do not block the UI thread. The isolate reads the index
  /// file at [indexFilePath], or uses [index] when the store already holds
  /// it in memory (it may be newer than the file). [signerContext] says
  /// who signed each ride. Static so the isolate closure captures only its
  /// arguments.
  static Future<RideHistoryLoad> _loadRideHistoryInBackground(
    List<String> recordingPaths, {
    required String? indexFilePath,
    required RideIndex? index,
    required RideSignerContext signerContext,
  }) async {
    Future<RideHistoryLoad> load() => loadRideHistoryIndexed(
      recordingPaths,
      indexFilePath: index == null ? indexFilePath : null,
      index: index,
      signerContext: signerContext,
    );
    try {
      return await Isolate.run(load);
    } catch (_) {
      // Fall back to the current isolate if the background one fails.
      return load();
    }
  }

  RideVideoCheck _videoCheckOf(RideRecord ride) {
    final path = ride.telemetryPath;
    if (path == null) {
      return RideVideoCheck.none;
    }
    return _videoChecks[rideIndexKey(path)] ?? RideVideoCheck.none;
  }

  /// Re-reads [ride]'s video check state from the index (after playback
  /// checked its segments); nothing is hashed.
  Future<void> _refreshVideoCheck(RideRecord ride) async {
    final path = ride.telemetryPath;
    final refresh = ++_videoCheckRefreshes;
    final store = await RideIndexStore.shared();
    if (path == null || store == null) {
      return;
    }
    final check = await videoCheckFromIndex(
      ride: ride,
      index: await store.read(),
      stat: statRideFile,
    );
    if (!mounted || refresh != _videoCheckRefreshes) {
      return;
    }
    setState(() {
      _videoChecks = <String, RideVideoCheck>{
        ..._videoChecks,
        rideIndexKey(path): check,
      };
    });
  }

  String _formatDuration(Duration duration) => formatElapsed(duration);

  String _lockKeyFor(RideRecord ride) => ride.telemetryPath ?? ride.videoPath;

  /// Whether [RideRecord.setLockState] may run for [ride]: it refuses rides
  /// that failed the integrity check (including a failed video check
  /// already stored in the ride index) or have quarantined paths.
  bool _canChangeLockState(RideRecord ride) =>
      ride.integrity.status != RideIntegrityStatus.modified &&
      !ride.hasQuarantinedSegments &&
      _videoCheckOf(ride).failed == 0;

  Future<void> _confirmAndUnlock(RideRecord ride) async {
    final lockKey = _lockKeyFor(ride);
    if (_lockUpdatesInFlight.contains(lockKey) || _refuseWhileMigrating()) {
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
    if (confirmed != true || !mounted || _refuseWhileMigrating()) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    // Segments with a recorded hash are checked before the file is
    // rewritten; the progress ring counts them.
    final toCheck = ride.expectedSegmentHashes.keys
        .where((path) => !ride.missingSegmentPaths.contains(path))
        .length;
    var checked = 0;
    setState(() {
      _lockUpdatesInFlight.add(lockKey);
      _lockProgress[lockKey] = null;
    });

    var result = RideLockChangeResult.failed;
    final store = await RideIndexStore.shared();
    try {
      result = await ride.changeLockState(
        false,
        hashSegment: SegmentVerifier(store: store).lockHasher(
          onChecked: () {
            checked++;
            if (mounted && toCheck > 0) {
              setState(() {
                _lockProgress[lockKey] = (checked / toCheck).clamp(0.0, 1.0);
              });
            }
          },
        ),
      );
    } catch (_) {
      result = RideLockChangeResult.failed;
    }
    final unlocked = result == RideLockChangeResult.saved;
    final telemetryPath = ride.telemetryPath;
    if (unlocked && store != null && telemetryPath != null) {
      // The ride JSON changed, so its index entry is stale; the reload
      // below decodes the file again.
      unawaited(
        store.update(
          (index) => index.rides.remove(rideIndexKey(telemetryPath)),
        ),
      );
    }
    if (!mounted) {
      return;
    }

    setState(() {
      _lockUpdatesInFlight.remove(lockKey);
      _lockProgress.remove(lockKey);
      if (unlocked) {
        _ridesFuture = _loadRides();
      }
    });
    messenger.showSnackBar(
      SnackBar(
        content: Text(switch (result) {
          RideLockChangeResult.saved => 'Clip unlocked.',
          RideLockChangeResult.refused =>
            'Could not unlock this clip: its files failed the integrity check or could not be read.',
          RideLockChangeResult.signingFailed =>
            'Could not sign this ride again on this phone. The ride is unchanged; try again.',
          RideLockChangeResult.failed =>
            'Could not unlock this clip: the change could not be saved.',
        }),
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
    if (_deletesInFlight.contains(key) || _refuseWhileMigrating()) {
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
    if (confirmed != true || !mounted || _refuseWhileMigrating()) {
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
    final rideSessionId = ride.rideSessionId;
    final telemetryPath = ride.telemetryPath;
    if (rideSessionId != null &&
        telemetryPath != null &&
        !await File(telemetryPath).exists()) {
      // The ride is gone, so it no longer counts as written signed here.
      // Only its own file name unregisters the id: deleting a copy that
      // carries the id of another ride leaves that ride registered.
      await SignedRideRegistry.instance.remove(
        rideSessionId,
        telemetryFileName: path_utils.fileNameFromPath(telemetryPath),
      );
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
      body: Column(
        children: [
          if (_migration != null)
            RecordingsMigrationBanner(migration: _migration!),
          Expanded(child: _buildRideList()),
        ],
      ),
    );
  }

  Widget _buildRideList() {
    return FutureBuilder<List<RideRecord>>(
      future: _ridesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(child: Text('Failed to load rides: ${snapshot.error}'));
        }

        final rides = snapshot.data ?? const <RideRecord>[];
        if (rides.isEmpty) {
          return const Center(
            child: Text('No rides found yet. Record a ride to see it here.'),
          );
        }

        final lockedRides = rides.where((ride) => ride.isLocked).toList();
        final otherRides = rides.where((ride) => !ride.isLocked).toList();
        final items = <Object>[
          if (lockedRides.isNotEmpty) ...['Locked Clips', ...lockedRides],
          'All Rides',
          ...otherRides,
        ];

        return RefreshIndicator(
          onRefresh: () async {
            setState(() {
              _ridesFuture = _loadRides();
            });
            await _ridesFuture;
          },
          // Section headers are Strings and cards are rides; only the
          // visible cards are built.
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              if (item is RideRecord) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _buildRideCard(context, item),
                );
              }
              return Padding(
                padding: EdgeInsets.only(
                  bottom: 8,
                  top: item == 'All Rides' ? 6 : 0,
                ),
                child: Text(
                  item as String,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  List<Widget> _buildBadges(RideRecord ride) {
    final hasTelemetry = ride.telemetryPath != null;
    final status = ride.integrity.status;
    final videoCheck = _videoCheckOf(ride);
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
      // the ride is opened. Only a ride signed with this phone's own key
      // shows as signed; a copy on another phone shows as unmodified.
      else if (status == RideIntegrityStatus.verified &&
          ride.integrity.signedBy == RideSignedBy.thisDevice)
        _buildStatusBadge(
          label: 'SIGNED ON THIS PHONE',
          color: Colors.lightGreen,
        )
      else if (status == RideIntegrityStatus.verified)
        _buildStatusBadge(label: 'DATA UNMODIFIED', color: Colors.lightGreen)
      else if (hasTelemetry)
        _buildStatusBadge(label: 'UNVERIFIED', color: Colors.grey),
      // From segment hashes stored in the ride index by playback or the
      // lock flow; nothing is hashed here.
      if (videoCheck.failed > 0)
        _buildStatusBadge(label: 'VIDEO CHECK FAILED', color: Colors.redAccent)
      else if (videoCheck.isVerified)
        _buildStatusBadge(label: 'VIDEOS VERIFIED', color: Colors.lightGreen),
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
        return switch (ride.integrity.signedBy) {
          RideSignedBy.thisDevice =>
            'Integrity: ride data unmodified and signed by this phone\'s '
                'MotoCam key (it shows no edit by anyone without that key; it '
                'does not prove the footage is genuine)',
          RideSignedBy.otherKey =>
            'Integrity: ride data unmodified; signed by another phone or an '
                'earlier install of MotoCam',
          RideSignedBy.unknownSigner =>
            'Integrity: ride data unmodified; signed, but this phone\'s key '
                'could not be read to check by whom',
          RideSignedBy.none =>
            'Integrity: ride data unmodified since recording',
        };
      case RideIntegrityStatus.modified:
        return ride.integrity.issues.contains('signature-removed')
            ? 'Integrity: check failed (this phone signed this ride, but the '
                  'signature was removed or replaced)'
            : 'Integrity: check failed';
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
    final videoLine = describeVideoCheck(_videoCheckOf(ride));

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
            Text('Samples: ${ride.sampleCount}'),
            Text(_integrityLine(ride)),
            if (videoLine != null)
              Text(
                videoLine,
                style: TextStyle(
                  color: _videoCheckOf(ride).failed > 0
                      ? Colors.redAccent
                      : null,
                ),
              ),
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
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: Tooltip(
                      message: 'Checking the videos before unlocking',
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: _lockProgress[_lockKeyFor(ride)],
                      ),
                    ),
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
          if (_isOpeningRide || _refuseWhileMigrating()) {
            return;
          }
          _isOpeningRide = true;
          _openedRide = ride;
          try {
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => RidePlaybackScreen(ride: ride)),
            );
          } finally {
            _isOpeningRide = false;
          }
          // Playback stored the segments it checked; show the new state.
          // A segment still being hashed refreshes it again through
          // _onIndexChanged when its result is stored.
          unawaited(_refreshVideoCheck(ride));
        },
      ),
    );
  }
}
