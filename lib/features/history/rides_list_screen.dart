import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:permission_handler/permission_handler.dart';

import '../../core/providers/app_settings_provider.dart';
import '../../core/services/app_permission_service.dart';
import '../../core/services/device_status_service.dart';
import '../../core/services/legacy_recordings_access.dart';
import '../../core/services/ride_signing_service.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/format_utils.dart';
import '../../core/utils/path_utils.dart' as path_utils;
import '../camera/providers/camera_provider.dart';
import '../camera/providers/gallery_export.dart';
import '../camera/providers/recordings_migration.dart';
import 'models/ride_history_loader.dart';
import 'models/ride_index.dart';
import 'models/ride_record.dart';
import 'models/segment_verifier.dart';
import 'ride_playback_screen.dart';
import 'services/gallery_copy_removal.dart';
import 'services/gallery_links.dart';
import 'services/legacy_ride_import.dart';
import 'services/ride_integrity_text.dart';
import 'services/ride_deletion.dart';
import 'services/ride_export.dart';
import 'widgets/playback_timeline.dart';
import 'widgets/ride_export_flow.dart';
import 'widgets/ride_list_model.dart';
import 'widgets/ride_list_widgets.dart';
import 'widgets/recordings_migration_banner.dart';

/// Ride History ("Rides"): lists recorded rides (Locked Clips first, then
/// All Rides by month) with their summary and integrity stamps, filters
/// them in memory, and opens playback on tap.
class RidesListScreen extends StatefulWidget {
  /// Creates the Ride History screen.
  const RidesListScreen({super.key});

  @override
  State<RidesListScreen> createState() => _RidesListScreenState();
}

class _RidesListScreenState extends State<RidesListScreen> {
  late Future<List<RideRecord>> _ridesFuture;
  bool _isOpeningRide = false;

  /// The filter chips that are on (in memory only; reset when the screen
  /// closes).
  final Set<RideFilter> _filters = <RideFilter>{};
  final Set<String> _lockUpdatesInFlight = <String>{};

  /// Share of a running lock change's segment checks that are done, by
  /// lock key; `null` (indeterminate) until the first segment is checked.
  final Map<String, double?> _lockProgress = <String, double?>{};
  final Set<String> _deletesInFlight = <String>{};

  /// Rides (by lock key) whose export flow runs, from the menu tap until
  /// [runRideExportFlow] returns: before its export publishes progress,
  /// too.
  final Set<String> _exportFlowsPending = <String>{};

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

  /// The import from the old public folder (Android), for its banner.
  LegacyRideImportController? _legacyImport;

  /// The gallery-link store this screen listens to, once resolved, and
  /// its content (the gallery copies each ride has).
  GalleryLinkStore? _galleryLinks;
  GalleryLinkData? _galleryData;

  /// Rides being saved to the gallery or having their gallery copies
  /// removed, by lock key; for a save, the share of segments done (`null`
  /// until the first is done).
  final Map<String, double?> _galleryProgress = <String, double?>{};

  /// The running ride export's progress (CameraProvider), listened to so
  /// the exported ride's row shows its ring.
  ValueListenable<RideExportProgress?>? _exportProgress;

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
      _legacyImport = context.read<CameraProvider>().legacyRideImport;
      _exportProgress = context.read<CameraProvider>().rideExportProgress
        ..addListener(_onExportProgressChanged);
      _ridesFuture = _loadRides();
    }
  }

  @override
  void dispose() {
    _indexStore?.removeListener(_onIndexChanged);
    _migration?.removeListener(_onMigrationChanged);
    _galleryLinks?.removeListener(_onGalleryLinksChanged);
    _exportProgress?.removeListener(_onExportProgressChanged);
    super.dispose();
  }

  /// Shows a ride export's progress (or its end) on the ride's row.
  void _onExportProgressChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// The running export's progress when it is of [ride], else `null`.
  RideExportProgress? _exportProgressOf(RideRecord ride) {
    final progress = _exportProgress?.value;
    return progress != null && progress.rideKey == _lockKeyFor(ride)
        ? progress
        : null;
  }

  /// While a ride is being exported its files must stay as they are, so
  /// unlocking (which rewrites the ride file) and deleting wait: shows a
  /// notice and returns `true` while an export runs or the export flow of
  /// the ride with lock [key] is under way.
  bool _refuseWhileExporting(String key) {
    if (_exportProgress?.value == null && !_exportFlowsPending.contains(key)) {
      return false;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'A ride is being exported. Try again when the export finishes.',
        ),
        duration: Duration(seconds: 3),
      ),
    );
    return true;
  }

  /// The ride menu's "Export to folder" and "Share": never while the ride
  /// is being deleted or unlocked, or its export flow already runs; the
  /// ride is marked busy ([_exportFlowsPending]) until the flow ends.
  Future<void> _exportRide(
    RideRecord ride,
    RideExportDestination destination,
  ) async {
    final key = _lockKeyFor(ride);
    if (_deletesInFlight.contains(key) ||
        _lockUpdatesInFlight.contains(key) ||
        _exportFlowsPending.contains(key)) {
      return;
    }
    _exportFlowsPending.add(key);
    try {
      await runRideExportFlow(context, ride, destination);
    } finally {
      _exportFlowsPending.remove(key);
    }
  }

  /// Shows a changed gallery-link store (a copy made or removed).
  void _onGalleryLinksChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// The gallery copies MotoCam recorded for [ride].
  List<GalleryLink> _galleryLinksOf(RideRecord ride) =>
      _galleryData?.linksOfRide(ride) ?? const <GalleryLink>[];

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
  /// paths, and while the storage budget deletes old rides their files go
  /// away, so opening, unlocking and deleting wait: shows a notice and
  /// returns `true` while either runs.
  bool _refuseWhileFilesChange() {
    final String message;
    if (_migration?.isRunning ?? false) {
      message =
          'Rides are being moved to private storage. Try again when the '
          'move finishes.';
    } else if (_legacyImport?.isRunning ?? false) {
      message =
          'Rides are being imported from the old folder. Try again when the '
          'import finishes.';
    } else if (context.read<CameraProvider>().isStorageBudgetRunning) {
      message =
          'Old rides are being deleted for the storage budget. Try again in '
          'a moment.';
    } else {
      return false;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
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
    // A ride the migration is moving (or paused in the middle of), or the
    // import is copying, is left out until it is whole in one root.
    final inFlight = <String>{
      ...cameraProvider.recordingsMigration.inFlightPaths,
      ...cameraProvider.legacyRideImport.inFlightPaths,
    };
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
    if (Platform.isAndroid) {
      final links = await GalleryLinkStore.shared();
      if (links != null) {
        if (_galleryLinks == null && mounted) {
          _galleryLinks = links;
          links.addListener(_onGalleryLinksChanged);
        }
        _galleryData = await links.read();
      }
    }
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
    if (_lockUpdatesInFlight.contains(lockKey) ||
        _galleryProgress.containsKey(lockKey) ||
        _refuseWhileFilesChange() ||
        _refuseWhileExporting(lockKey)) {
      return;
    }

    final budgetOn =
        context.read<AppSettingsProvider>().recordingsStorageBudgetGb > 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unlock this clip?'),
        content: Text(
          budgetOn
              ? 'Unlocking removes the lock marker; the ride moves from '
                    'Locked Clips to All Rides. With the storage budget on, '
                    'an unlocked ride can be deleted automatically once it '
                    'is among the oldest.'
              : 'Unlocking only removes the lock marker. MotoCam never '
                    'deletes past rides automatically; the ride moves from '
                    'Locked Clips to All Rides.',
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
    if (confirmed != true ||
        !mounted ||
        _refuseWhileFilesChange() ||
        _refuseWhileExporting(lockKey)) {
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
    // No file of the ride moves into private storage meanwhile.
    final releaseMigration = context
        .read<CameraProvider>()
        .holdRecordingsMigration();
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
    } finally {
      releaseMigration();
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
    // Queued copies of an unlocked ride are cancelled (the automatic export
    // is for locked clips); a copy being made now is deleted when it ends.
    var cancelledCopies = 0;
    if (unlocked && Platform.isAndroid) {
      final links = _galleryLinks ?? await GalleryLinkStore.shared();
      cancelledCopies =
          await links?.dropPending(galleryKeysOfRide(ride).keys) ?? 0;
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
          RideLockChangeResult.saved =>
            cancelledCopies == 0
                ? 'Clip unlocked.'
                : 'Clip unlocked. $cancelledCopies queued gallery '
                      'cop${cancelledCopies == 1 ? 'y was' : 'ies were'} '
                      'cancelled.',
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
    final links = _galleryLinksOf(ride);
    if (unlocked && links.isNotEmpty) {
      await _offerToRemoveGalleryCopies(
        ride,
        links,
        reason: 'The clip is unlocked. ',
        canRetry: true,
      );
    }
  }

  /// Asks (default: keep) whether to remove [links]' gallery copies, then
  /// removes them (after cancelling [ride]'s queued copies, and including
  /// copies linked since [links] was read) and reports what was not
  /// removed. [reason] starts the dialog text; [canRetry] is false when the
  /// ride is about to be deleted (its menu cannot offer the removal again).
  /// Returns whether the rider chose to remove them.
  Future<bool> _offerToRemoveGalleryCopies(
    RideRecord ride,
    List<GalleryLink> links, {
    required String reason,
    required bool canRetry,
  }) async {
    final count = links.length;
    final copies = '$count gallery cop${count == 1 ? 'y' : 'ies'}';
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove $copies?'),
        content: Text(
          '${reason}MotoCam saved $copies of this ride in '
          'Movies/MotoCam/Recordings. Other apps can read them, and they stay '
          'on the phone after MotoCam is uninstalled.\n\nRemove them from the '
          'gallery? The phone may ask you to allow it.',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep copies'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove copies'),
          ),
        ],
      ),
    );
    if (remove != true || !mounted) {
      return false;
    }
    await _removeGalleryCopies(ride, links, canRetry: canRetry);
    return true;
  }

  Future<void> _removeGalleryCopies(
    RideRecord ride,
    List<GalleryLink> links, {
    required bool canRetry,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await removeGalleryCopies(
      links,
      store: _galleryLinks ?? await GalleryLinkStore.shared(),
      rideKeys: galleryKeysOfRide(ride).keys,
      requestStoragePermission: () async =>
          AppPermissionService.isPermissionGranted(
            await Permission.storage.request(),
          ),
    );
    if (!mounted) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(galleryRemovalSummary(result, canRetry: canRetry)),
        duration: Duration(seconds: result.notRemoved.isEmpty ? 3 : 8),
      ),
    );
  }

  /// Save to gallery: explains what a gallery copy means, then copies every
  /// existing video file of [ride] to Movies/MotoCam/Recordings through
  /// [CameraProvider.saveRideToGallery], with progress and a summary.
  Future<void> _confirmAndSaveToGallery(RideRecord ride) async {
    final key = _lockKeyFor(ride);
    // Never while the ride is being deleted or unlocked: a copy made then
    // would miss the removal those offer.
    if (_galleryProgress.containsKey(key) ||
        _deletesInFlight.contains(key) ||
        _lockUpdatesInFlight.contains(key) ||
        _refuseWhileFilesChange()) {
      return;
    }
    final camera = context.read<CameraProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final blocked = camera.gallerySaveBlockedReason;
    if (blocked != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(blocked), duration: const Duration(seconds: 3)),
      );
      return;
    }
    final files = galleryKeysOfRide(ride).length;
    final linked = _galleryLinksOf(ride).length;
    final status = await const DeviceStatusService()
        .getBatteryAndThermalStatus();
    if (!mounted) {
      return;
    }
    final askStorage = AppPermissionService.needsLegacyStoragePermission(
      status.androidSdkInt,
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Save to gallery?'),
        content: Text(
          'MotoCam copies this ride\'s $files video file${files == 1 ? '' : 's'} '
          'to the phone\'s gallery (Movies/MotoCam/Recordings). Other apps '
          'can read gallery copies, they include the audio if it was '
          'recorded, and they stay on the phone after MotoCam is '
          'uninstalled. The GPS route is not copied.'
          '${linked > 0 ? '\n\n$linked of them ${linked == 1 ? 'is' : 'are'} already in the gallery and ${linked == 1 ? 'is' : 'are'} not copied again.' : ''}'
          '${askStorage ? '\n\nThis phone needs storage access to write to the gallery; MotoCam asks for it next.' : ''}'
          '\n\nYou can remove the copies later from this ride\'s menu.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        _deletesInFlight.contains(key) ||
        _lockUpdatesInFlight.contains(key) ||
        _refuseWhileFilesChange()) {
      return;
    }
    setState(() {
      _galleryProgress[key] = null;
    });
    GalleryExportRun? run;
    try {
      run = await camera.saveRideToGallery(
        ride,
        onProgress: (done, total) {
          if (mounted && total > 0) {
            setState(() {
              _galleryProgress[key] = (done / total).clamp(0.0, 1.0);
            });
          }
        },
      );
    } finally {
      if (mounted) {
        setState(() {
          _galleryProgress.remove(key);
        });
      }
    }
    if (!mounted) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          run == null
              ? camera.gallerySaveBlockedReason ??
                    'Could not save to the gallery on this phone.'
              : gallerySaveSummary(run),
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// The ride menu's "Remove gallery copies".
  Future<void> _confirmAndRemoveGalleryCopies(RideRecord ride) async {
    final key = _lockKeyFor(ride);
    final links = _galleryLinksOf(ride);
    if (links.isEmpty || _galleryProgress.containsKey(key)) {
      return;
    }
    setState(() {
      _galleryProgress[key] = null;
    });
    try {
      await _offerToRemoveGalleryCopies(
        ride,
        links,
        reason: '',
        canRetry: true,
      );
    } finally {
      if (mounted) {
        setState(() {
          _galleryProgress.remove(key);
        });
      }
    }
  }

  Future<void> _confirmAndDelete(RideRecord ride) async {
    final key = _lockKeyFor(ride);
    if (_deletesInFlight.contains(key) ||
        _galleryProgress.containsKey(key) ||
        _refuseWhileFilesChange() ||
        _refuseWhileExporting(key)) {
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

    final links = _galleryLinksOf(ride);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this ride?'),
        content: Text(
          '${lockIsStuck ? 'This ride has locked clips and failed the integrity check, so it cannot be unlocked. ' : ''}'
          'This permanently deletes the ride\'s ${ride.segmentPaths.length} '
          'video segment(s) and its telemetry from this device. '
          '${links.isEmpty ? 'Gallery copies are not affected.' : 'MotoCam asks next whether to also remove its gallery copies.'}',
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
    if (confirmed != true ||
        !mounted ||
        _refuseWhileFilesChange() ||
        _refuseWhileExporting(key)) {
      return;
    }
    // Before the ride's files go: deleting them drops the links.
    if (links.isNotEmpty) {
      await _offerToRemoveGalleryCopies(
        ride,
        links,
        reason: 'The ride will be deleted next. ',
        canRetry: false,
      );
      if (!mounted ||
          _galleryProgress.containsKey(key) ||
          _refuseWhileFilesChange() ||
          _refuseWhileExporting(key)) {
        return;
      }
    }

    setState(() {
      _deletesInFlight.add(key);
    });
    // No file of the ride moves into private storage meanwhile.
    final releaseMigration = context
        .read<CameraProvider>()
        .holdRecordingsMigration();
    final RideDeletionResult result;
    try {
      result = await deleteRideFiles(
        ride,
        indexStore: await RideIndexStore.shared(),
        galleryLinks: _galleryLinks ?? await GalleryLinkStore.shared(),
      );
    } finally {
      releaseMigration();
    }
    final failed = result.failed;
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

  /// Imports the rides that v0.1.11 and v0.1.12 left in the public folder
  /// Movies/MotoCam/Recordings (Android): explains the folder, opens the
  /// system folder picker there, imports through [CameraProvider], shows
  /// the summary and then offers to delete the imported originals.
  Future<void> _importFromOlderVersion() async {
    final camera = context.read<CameraProvider>();
    final messenger = ScaffoldMessenger.of(context);
    void show(String text) => messenger.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 6)),
    );

    final blocked = camera.legacyImportBlockedReason;
    if (blocked != null) {
      show(blocked);
      return;
    }
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Import rides from an older version'),
        content: const Text(
          'MotoCam 0.1.11 and 0.1.12 saved rides in Movies/MotoCam/Recordings. '
          'Other apps can read the files there, including each ride\'s GPS '
          'route, and they stay on the phone after MotoCam is uninstalled.\n\n'
          'On the next screen, open that folder (it usually opens there), tap '
          '"Use this folder" and allow access. MotoCam copies the rides into '
          'its private storage and changes nothing in the folder.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Choose folder'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) {
      return;
    }

    String? treeUri;
    try {
      treeUri = await LegacyRecordingsAccess.pickRecordingsTree();
    } on PlatformException {
      show('Could not open the folder picker on this phone.');
      return;
    } on MissingPluginException {
      show('Importing rides is not available on this phone.');
      return;
    }
    if (treeUri == null || !mounted) {
      return;
    }
    if (!LegacyRecordingsAccess.isRecordingsFolder(treeUri)) {
      final picked = LegacyRecordingsAccess.describeTree(treeUri);
      show(
        '${picked == null ? 'That folder' : '"$picked"'} is not '
        'Movies/MotoCam/Recordings, the folder older versions recorded to. '
        'Nothing was imported; choose that folder to import its rides.',
      );
      return;
    }

    final source = LegacyRecordingsAccess(treeUri);
    final summary = await camera.importLegacyRides(source);
    if (!mounted) {
      return;
    }
    setState(() {
      _ridesFuture = _loadRides();
    });
    if (summary == null) {
      show(camera.legacyImportBlockedReason ?? 'The import could not start.');
      return;
    }
    show(summary.message);
    if (summary.outcome == LegacyImportOutcome.completed &&
        summary.importedDocuments.isNotEmpty) {
      await _offerToDeleteOriginals(source, summary.importedDocuments);
    }
  }

  /// Asks (default: keep) whether to delete the originals of an import
  /// from the public folder, then deletes only [documents] (files with a
  /// verified copy in private storage) and reports what could not be
  /// deleted.
  Future<void> _offerToDeleteOriginals(
    LegacyRideDocumentSource source,
    List<LegacyRideDocument> documents,
  ) async {
    final count = documents.length;
    final delete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete the originals?'),
        content: Text(
          'The imported rides are now in MotoCam\'s private storage. Their '
          '$count original file${count == 1 ? '' : 's'} in '
          'Movies/MotoCam/Recordings can still be read by other apps, '
          'including the GPS routes, and stay on the phone after MotoCam is '
          'uninstalled.\n\nDelete them from that folder? Files that were not '
          'imported are left alone.',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep originals'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete originals'),
          ),
        ],
      ),
    );
    if (delete != true || !mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final failed = await deleteImportedOriginals(source, documents);
    if (!mounted) {
      return;
    }
    final deleted = count - failed.length;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failed.isEmpty
              ? 'Deleted $count original file${count == 1 ? '' : 's'} from '
                    'Movies/MotoCam/Recordings.'
              : 'Deleted $deleted of $count original files. '
                    '${failed.length} could not be deleted (for example '
                    '${failed.first.name}); remove them with a file manager.',
        ),
        duration: const Duration(seconds: 8),
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
      appBar: AppBar(
        title: Text(
          'Rides',
          style: MotoFonts.condensedStyle(30, color: MotoColors.text),
        ),
        actions: [
          RideListTopBarActions(
            android: Platform.isAndroid,
            onImport: _importFromOlderVersion,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MotoSize.gutter,
              MotoSize.gap,
              MotoSize.gutter,
              0,
            ),
            child: RideFilterBar(
              selected: _filters,
              onToggle: (filter) => setState(() {
                if (!_filters.remove(filter)) {
                  _filters.add(filter);
                }
              }),
            ),
          ),
          if (_migration != null)
            RecordingsMigrationBanner(migration: _migration!),
          if (_legacyImport != null)
            ListenableBuilder(
              listenable: _legacyImport!,
              builder: (context, _) {
                final text = _legacyImport!.bannerText;
                if (text == null) {
                  return const SizedBox.shrink();
                }
                final progress = _legacyImport!.progress;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(
                    MotoSize.gutter,
                    MotoSize.gap,
                    MotoSize.gutter,
                    0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        text,
                        style: MotoFonts.bodyStyle(14, color: MotoColors.dim),
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        color: MotoColors.text,
                        backgroundColor: MotoColors.hairlineStrong,
                        value: progress == null || progress.total == 0
                            ? null
                            : progress.done / progress.total,
                      ),
                    ],
                  ),
                );
              },
            ),
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

        final items = rideListItems(
          rides,
          filters: _filters,
          now: DateTime.now(),
        );

        return RefreshIndicator(
          onRefresh: () async {
            setState(() {
              _ridesFuture = _loadRides();
            });
            await _ridesFuture;
          },
          // Only the visible rows are built.
          child: items.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(MotoSize.gutter),
                  children: const [
                    Text(
                      'No rides match these filters.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                    MotoSize.gutter,
                    MotoSize.gapWide,
                    MotoSize.gutter,
                    MotoSize.gutter,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return switch (item) {
                      RideListRide(:final ride) => Padding(
                        padding: const EdgeInsets.only(bottom: MotoSize.gap),
                        child: _buildRideCard(context, ride),
                      ),
                      RideSectionHeader(:final title) => Padding(
                        padding: EdgeInsets.only(
                          bottom: MotoSize.gap,
                          top: index == 0 ? 0 : MotoSize.gapWide,
                        ),
                        child: RideListHeader.section(title),
                      ),
                      RideMonthHeader(:final label) => Padding(
                        padding: const EdgeInsets.only(
                          bottom: MotoSize.gap,
                          top: 4,
                        ),
                        child: RideListHeader.month(label),
                      ),
                    };
                  },
                ),
        );
      },
    );
  }

  /// The row's trailing slot: a ring while the ride is exported, saved to
  /// or removed from the gallery, checked before unlocking or deleted;
  /// otherwise the Ride actions menu.
  Widget _buildTrailing(RideRecord ride) {
    final key = _lockKeyFor(ride);
    final isUpdatingLock = _lockUpdatesInFlight.contains(key);
    // A gallery save or removal of the ride blocks unlocking and deleting
    // it until it ends.
    final galleryBusy = _galleryProgress.containsKey(key);
    // So does an export of the ride.
    final export = _exportProgressOf(ride);
    final exportBusy = export != null;
    final busy = rideRowBusy(
      exportBusy: exportBusy,
      galleryBusy: galleryBusy,
      isUpdatingLock: ride.isLocked && isUpdatingLock,
      isDeleting: _deletesInFlight.contains(key),
    );
    return switch (busy) {
      RideRowBusy.export => RideProgressRing(
        value: export!.fraction,
        tooltip: 'Stop export',
        onStop: () =>
            unawaited(context.read<CameraProvider>().cancelRideExport()),
      ),
      RideRowBusy.gallery => RideProgressRing(
        value: _galleryProgress[key],
        tooltip: 'Wait for the gallery copies to finish',
      ),
      RideRowBusy.lockCheck => RideProgressRing(
        value: _lockProgress[key],
        tooltip: 'Checking the videos before unlocking',
      ),
      RideRowBusy.deleting => const RideProgressRing(
        value: null,
        tooltip: 'Deleting the ride',
      ),
      RideRowBusy.none => RideActionsMenu(
        entries: rideMenuEntries(
          android: Platform.isAndroid,
          isLocked: ride.isLocked,
          canChangeLockState: _canChangeLockState(ride),
          isUpdatingLock: isUpdatingLock,
          galleryBusy: galleryBusy,
          exportBusy: exportBusy,
          galleryCopies: _galleryLinksOf(ride).length,
        ),
        onSelected: (action) {
          switch (action) {
            case RideMenuAction.saveToGallery:
              unawaited(_confirmAndSaveToGallery(ride));
            case RideMenuAction.removeGalleryCopies:
              unawaited(_confirmAndRemoveGalleryCopies(ride));
            case RideMenuAction.exportFolder:
              unawaited(_exportRide(ride, RideExportDestination.folder));
            case RideMenuAction.share:
              unawaited(_exportRide(ride, RideExportDestination.share));
            case RideMenuAction.unlock:
              unawaited(_confirmAndUnlock(ride));
            case RideMenuAction.delete:
              unawaited(_confirmAndDelete(ride));
          }
        },
      ),
    };
  }

  Widget _buildRideCard(BuildContext context, RideRecord ride) {
    final now = DateTime.now();
    final videoCheck = _videoCheckOf(ride);
    final stamps = rideStamps(ride, videoCheck);
    final videoLine = describeVideoCheck(videoCheck);
    final integrity = [rideIntegrityLine(ride), ?videoLine].join('\n');
    final galleryCopies = _galleryLinksOf(ride).length;
    final details = <String>[
      ?_videoCoverageText(ride),
      if (galleryCopies > 0)
        'Gallery copies: $galleryCopies (readable by other apps)',
    ];
    if (isIncompleteRideRow(ride)) {
      final note = incompleteRideNote(ride);
      return IncompleteRideRow(
        dateLabel: rideDateLabel(ride.createdAt, now),
        text: incompleteRideText(ride),
        note: note,
        stamps: note == null
            ? stamps
            : stamps
                  .where((stamp) => stamp.kind != RideStampKind.unsigned)
                  .toList(growable: false),
        integrityText: integrity,
        details: details,
        trailing: _buildTrailing(ride),
        onOpen: () => unawaited(_openRide(ride)),
      );
    }
    return RideRow(
      dateLabel: rideDateLabel(ride.createdAt, now),
      summary: rideSummaryText(ride, formatFileSize),
      stamps: stamps,
      integrityText: integrity,
      details: details,
      trailing: _buildTrailing(ride),
      onOpen: () => unawaited(_openRide(ride)),
    );
  }

  /// Opens [ride] for playback: never while it is being unlocked or
  /// deleted, or while files change; holds the move into private storage
  /// while it is open and refreshes its video check when it closes.
  Future<void> _openRide(RideRecord ride) async {
    final key = _lockKeyFor(ride);
    if (_isOpeningRide ||
        _lockUpdatesInFlight.contains(key) ||
        _deletesInFlight.contains(key) ||
        _refuseWhileFilesChange()) {
      return;
    }
    _isOpeningRide = true;
    _openedRide = ride;
    // No file of the ride moves into private storage while it is open.
    final releaseMigration = context
        .read<CameraProvider>()
        .holdRecordingsMigration();
    try {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => RidePlaybackScreen(ride: ride)));
    } finally {
      _isOpeningRide = false;
      releaseMigration();
    }
    // Playback stored the segments it checked; show the new state. A
    // segment still being hashed refreshes it again through
    // _onIndexChanged when its result is stored.
    unawaited(_refreshVideoCheck(ride));
  }
}
