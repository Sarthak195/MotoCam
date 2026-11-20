import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../../core/utils/format_utils.dart';
import '../camera/providers/camera_provider.dart';
import '../map/map_source_config.dart';
import 'models/ride_index.dart';
import 'models/ride_record.dart';
import 'models/segment_verifier.dart';
import 'services/ride_export.dart';
import 'widgets/playback_position.dart';
import 'widgets/playback_timeline.dart';
import 'widgets/playback_video_area.dart';
import 'widgets/ride_export_flow.dart';
import 'widgets/ride_playback_body.dart';
import '../../core/diagnostics/diagnostic_log.dart';

/// Plays back a recorded ride: its video segments as one continuous timeline,
/// with a telemetry overlay, a speed graph, a seekbar that marks missing
/// footage, integrity-check failures, incidents and locked segments, and an
/// optional online route map.
///
/// A sample-less [ride] (from Ride History) is first loaded in full on a
/// background isolate. Segment integrity is then checked in the background,
/// one segment at a time starting with the one about to play; results are
/// stored in the ride index, so an unchanged segment is not hashed again,
/// and leaving the screen stops the check after the segment in flight.
/// Segments that cannot be confirmed unmodified since recording are marked
/// on the seekbar.
class RidePlaybackScreen extends StatefulWidget {
  /// Creates a playback screen for [ride].
  const RidePlaybackScreen({super.key, required this.ride});

  /// The ride to play; it may be sample-less ([RideRecord.samplesLoaded]
  /// `false`).
  final RideRecord ride;

  @override
  State<RidePlaybackScreen> createState() => _RidePlaybackScreenState();
}

enum _SegmentLoadOutcome { loaded, failed, cancelled }

class _PendingSeek {
  const _PendingSeek(this.target, this.shouldResume);

  final Duration target;
  final bool shouldResume;
}

class _RidePlaybackScreenState extends State<RidePlaybackScreen>
    with WidgetsBindingObserver {
  static const String _showRouteMapPrefKey = 'ride_playback_show_route_map';
  static const String _onlineMapConsentPrefKey =
      'ride_playback_online_map_consent';

  /// Tap distance, in logical pixels, within which a seekbar tap snaps to a
  /// marker.
  static const double _markerTapTolerancePx = 18;

  /// The ride being played: [RidePlaybackScreen.ride] until its samples
  /// are loaded.
  late RideRecord _ride;

  /// Stops the running segment check; replaced by each new check.
  SegmentCheckToken? _segmentCheckToken;
  bool _isCheckingSegments = false;

  /// Whether the ride file could not be read again when playback opened.
  /// The ride then plays from the saved summary, whose recorded video
  /// hashes no longer come from a file on disk, so the videos are not
  /// checked against them.
  bool _rideReadFailed = false;

  VideoPlayerController? _controller;
  bool _isLoading = true;
  bool _isDisposing = false;
  bool _isAppInForeground = true;
  String? _playbackError;
  final List<String> _segmentPaths = <String>[];
  final List<Duration> _segmentDurations = <Duration>[];
  final List<Duration> _segmentOffsets = <Duration>[];
  final Set<int> _failedSegmentIndexes = <int>{};
  List<RideSegmentTimelineEntry> _timelineEntries =
      const <RideSegmentTimelineEntry>[];
  Duration _totalDuration = Duration.zero;
  Duration _lastKnownGlobalPosition = Duration.zero;
  Duration? _scrubPreviewPosition;

  /// The position and playing flag the body's position-scoped widgets
  /// listen to; see [_publishPosition].
  final ValueNotifier<PlaybackPosition> _positionNotifier =
      ValueNotifier<PlaybackPosition>(PlaybackPosition.zero);
  int _activeSegmentIndex = 0;
  int _loadGeneration = 0;
  bool _isSwitchingSegment = false;
  bool _isSeekingAcrossSegments = false;
  _PendingSeek? _pendingSeek;
  VideoPlayerController? _erroredController;
  bool _isScrubbing = false;
  bool _resumeAfterScrub = false;
  bool _showRouteMap = false;
  bool _hasOnlineMapConsent = false;
  bool _isFullscreenPlayback = false;
  List<int> _lockMarkerMs = const <int>[];
  List<int> _incidentMarkerMs = const <int>[];
  List<PlaybackRange> _missingSegmentRanges = const <PlaybackRange>[];
  List<PlaybackRange> _failedCheckRanges = const <PlaybackRange>[];
  List<PlaybackRange> _noVideoRanges = const <PlaybackRange>[];
  Set<String> _integrityFailedPaths = const <String>{};
  double _maxSampleSpeed = 1;
  bool _hasShownInitializationWarning = false;
  bool _hasShownIntegrityWarning = false;
  String? _shownIntegrityNotice;

  bool get _isSegmentLoadInFlight =>
      _isSwitchingSegment || _isSeekingAcrossSegments;

  /// The running ride export's progress (CameraProvider, Android only),
  /// for the app bar's ride actions.
  ValueListenable<RideExportProgress?>? _exportProgress;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Platform.isAndroid) {
      _exportProgress ??= context.read<CameraProvider>().rideExportProgress;
    }
  }

  /// The app bar's ride actions (Android): "Export to folder" and "Share",
  /// disabled while the ride loads or could not be read, or a spinner that
  /// stops the export while this ride is being exported.
  Widget _buildRideActions(ValueListenable<RideExportProgress?> progress) {
    final key = _ride.telemetryPath ?? _ride.videoPath;
    return ValueListenableBuilder<RideExportProgress?>(
      valueListenable: progress,
      builder: (context, export, _) {
        if (export != null && export.rideKey == key) {
          return IconButton(
            tooltip: 'Stop export',
            onPressed: () =>
                unawaited(context.read<CameraProvider>().cancelRideExport()),
            icon: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: export.fraction,
              ),
            ),
          );
        }
        return PopupMenuButton<RideExportDestination>(
          tooltip: 'Ride actions',
          icon: const Icon(Icons.more_vert),
          enabled: !_isLoading && !_rideReadFailed,
          // The State's context: the app bar (and this builder's context)
          // unmounts when the video goes fullscreen, the screen does not.
          // A section starts around the playhead (ride time).
          onSelected: (destination) => unawaited(
            runRideExportFlow(
              this.context,
              _ride,
              destination,
              playheadMs: _positionNotifier.value.position.inMilliseconds,
            ),
          ),
          itemBuilder: (_) => const [
            PopupMenuItem<RideExportDestination>(
              value: RideExportDestination.folder,
              child: Text('Export to folder'),
            ),
            PopupMenuItem<RideExportDestination>(
              value: RideExportDestination.share,
              child: Text('Share'),
            ),
          ],
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _ride = widget.ride;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _isAppInForeground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadPlaybackPreferences());
    unawaited(_start());
  }

  /// Loads the samples (Ride History passes a sample-less ride), shows the
  /// load-time notices, builds the playlist and loads the first segment,
  /// then checks the segment files, starting with the one about to play.
  Future<void> _start() async {
    if (!_ride.samplesLoaded) {
      final ride = await _loadFullRide(_ride);
      if (!mounted || _isDisposing) {
        return;
      }
      setState(() {
        _ride = ride;
        // loadSamples returns the sample-less record when the re-read fails.
        _rideReadFailed = ride.telemetryPath != null && !ride.samplesLoaded;
      });
    }
    for (final sample in _ride.samples) {
      _maxSampleSpeed = math.max(_maxSampleSpeed, sample.speed);
    }
    _showInitialIntegrityWarning();
    await _initializePlayback();
    if (!mounted || _isDisposing) {
      return;
    }
    unawaited(_verifySegmentsAsync());
  }

  /// Reads the ride with its samples on a background isolate (on this one
  /// if that fails). A ride that cannot be re-read comes back sample-less
  /// and plays without telemetry (see [_rideReadFailed]).
  static Future<RideRecord> _loadFullRide(RideRecord ride) async {
    try {
      return await Isolate.run(ride.loadSamples);
    } catch (_) {
      try {
        return await ride.loadSamples();
      } catch (_) {
        return ride;
      }
    }
  }

  /// Shows what the payload-level check done when loading the ride found,
  /// that a ride without an integrity record cannot be checked, and that
  /// its GPS came from a simulated location provider.
  void _showInitialIntegrityWarning() {
    final ride = _ride;
    final integrityNotice = describeIntegrityIssues(
      issues: ride.integrity.issues,
      quarantinedCount: ride.quarantinedSegmentPaths.length,
    );
    final notices = <String>[
      ?integrityNotice,
      if (integrityNotice == null &&
          ride.telemetryPath != null &&
          ride.integrity.status == RideIntegrityStatus.unknown)
        'This ride has no integrity record, so its files cannot be checked.',
      if (ride.mockLocationDetected)
        'GPS in this ride came from a simulated (mock) location provider.',
      if (_rideReadFailed) _rideReadFailedMessage,
    ];
    // Segments without a recorded hash are known before any hashing, so the
    // seekbar can mark them right away; the background check adds the
    // segments whose hash differs.
    _integrityFailedPaths = segmentPathsFailingIntegrity(ride.integrity.issues);
    if (notices.isEmpty) {
      return;
    }
    if (integrityNotice != null) {
      _hasShownIntegrityWarning = true;
      _shownIntegrityNotice = integrityNotice;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showMessage(notices.join(' '), duration: const Duration(seconds: 5));
    });
  }

  static const String _rideReadFailedMessage =
      'The ride file could not be read again: showing the saved summary '
      'without telemetry, and its videos were not checked.';

  /// Checks the segment files against the hashes in the ride's envelope,
  /// one at a time: the segment about to play first, then the others in
  /// timeline order. Results stored in the ride index are reused unless
  /// [ignoreCache]; every new result is stored. A failed segment is marked
  /// on the seekbar as soon as it is found. With [announce] (the 'Check
  /// videos again' action) the outcome is always reported.
  Future<void> _verifySegmentsAsync({
    bool ignoreCache = false,
    bool announce = false,
  }) async {
    _segmentCheckToken?.cancel();
    if (_rideReadFailed) {
      if (announce) {
        _showMessage(_rideReadFailedMessage, replaceCurrent: true);
      }
      return;
    }
    final token = SegmentCheckToken();
    _segmentCheckToken = token;
    final ride = _ride;
    final activePath =
        _activeSegmentIndex >= 0 && _activeSegmentIndex < _segmentPaths.length
        ? _segmentPaths[_activeSegmentIndex]
        : null;
    final targets = orderSegmentsForCheck(
      timelineOrder: <String>[
        for (final entry in _timelineEntries) entry.path,
        ...ride.segmentPaths,
      ],
      expectedHashes: ride.expectedSegmentHashes,
      missing: ride.missingSegmentPaths.toSet(),
      first: activePath,
    );
    if (targets.isEmpty) {
      if (announce) {
        _showMessage(
          'This ride has no recorded video hashes to check.',
          replaceCurrent: true,
        );
      }
      return;
    }

    final verifier = SegmentVerifier(store: await RideIndexStore.shared());
    if (token.isCancelled || !mounted || _isDisposing) {
      return;
    }
    setState(() {
      _isCheckingSegments = true;
    });
    final hashIssues = <String>[];
    try {
      await verifier.verify(
        targets,
        token: token,
        ignoreCache: ignoreCache,
        onResult: (result) {
          final issue = result.issue;
          if (issue == null) {
            return;
          }
          hashIssues.add(issue);
          if (token.isCancelled || !mounted || _isDisposing) {
            return;
          }
          setState(() {
            _integrityFailedPaths = <String>{
              ..._integrityFailedPaths,
              result.path,
            };
            _failedCheckRanges = rangesForPaths(
              timeline: _timelineEntries,
              paths: _integrityFailedPaths,
            );
          });
        },
      );
    } catch (_) {
      // The check is advisory; playback continues without it.
    }
    if (token.isCancelled || !mounted || _isDisposing) {
      return;
    }
    setState(() {
      _isCheckingSegments = false;
    });

    final issues = <String>[...ride.integrity.issues, ...hashIssues];
    final notice = describeIntegrityIssues(
      issues: issues,
      quarantinedCount: ride.quarantinedSegmentPaths.length,
    );
    if (announce) {
      _showMessage(
        notice ??
            'Videos checked: all ${targets.length} segment(s) match the '
                'recording.',
        duration: const Duration(seconds: 6),
        replaceCurrent: true,
      );
      return;
    }
    if (hashIssues.isEmpty && _hasShownIntegrityWarning) {
      return;
    }
    // Do not repeat the notice already shown from the load-time check.
    if (notice == null || notice == _shownIntegrityNotice) {
      return;
    }
    _hasShownIntegrityWarning = true;
    _shownIntegrityNotice = notice;
    _showMessage(notice, duration: const Duration(seconds: 6));
  }

  /// The 'Check videos again' action: hashes every segment again, ignoring
  /// stored results (nothing when the ride file could not be read again).
  void _checkVideosAgain() {
    if (_rideReadFailed) {
      _showMessage(_rideReadFailedMessage, replaceCurrent: true);
      return;
    }
    _segmentCheckToken?.cancel();
    setState(() {
      _integrityFailedPaths = segmentPathsFailingIntegrity(
        _ride.integrity.issues,
      );
      _failedCheckRanges = rangesForPaths(
        timeline: _timelineEntries,
        paths: _integrityFailedPaths,
      );
    });
    _showMessage('Checking the videos again...', replaceCurrent: true);
    unawaited(_verifySegmentsAsync(ignoreCache: true, announce: true));
  }

  void _showMessage(
    String message, {
    Duration? duration,
    bool replaceCurrent = false,
  }) {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    if (replaceCurrent) {
      messenger.hideCurrentSnackBar();
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration ?? const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _loadPlaybackPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final consent = prefs.getBool(_onlineMapConsentPrefKey) ?? false;
    final showRouteMap =
        consent && (prefs.getBool(_showRouteMapPrefKey) ?? false);
    if (!mounted) {
      return;
    }
    setState(() {
      _hasOnlineMapConsent = consent;
      _showRouteMap = showRouteMap;
    });
  }

  Future<void> _persistBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  /// Asks once before the online map is first shown, because loading tiles
  /// sends the ride's area to the tile server.
  Future<bool> _confirmOnlineMap() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Show online map?'),
        content: const Text(
          'The route map downloads map tiles from OpenStreetMap '
          '(${MapSourceConfig.tileHost}). This sends the area of this ride '
          'and your IP address to the OpenStreetMap Foundation, and the tiles '
          'are cached on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Show map'),
          ),
        ],
      ),
    );
    return accepted ?? false;
  }

  Future<void> _toggleRouteMapVisibility() async {
    final show = !_showRouteMap;
    if (show && !_hasOnlineMapConsent) {
      if (!await _confirmOnlineMap() || !mounted) {
        return;
      }
      _hasOnlineMapConsent = true;
      unawaited(_persistBool(_onlineMapConsentPrefKey, true));
    }
    setState(() {
      _showRouteMap = show;
    });
    unawaited(_persistBool(_showRouteMapPrefKey, show));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppInForeground = state == AppLifecycleState.resumed;
    if (!_isAppInForeground) {
      unawaited(_stopPlayback());
    }
  }

  Future<void> _initializePlayback() async {
    final declaredPaths = orderedDeclaredSegmentPaths(
      segmentPaths: _ride.segmentPaths,
      videoPath: _ride.videoPath,
    );
    final storedTimelinePaths = <String>{
      for (final entry in _ride.segmentTimeline)
        if (entry.endMs - entry.startMs >= minPlaybackSegmentMs)
          entry.path.trim(),
    };

    // Durations of segments listed in the stored timeline come from it; only
    // segments without a usable entry (rides recorded before the timeline
    // existed, or an entry saved without an end) are probed with a native
    // player. Readability is checked when a segment is loaded.
    final probedDurationsByPath = <String, Duration>{};
    final unavailablePaths = <String>{};
    var missingSegmentsCount = 0;
    var unreadableSegmentsCount = 0;
    var unreadableTrailingSegmentsCount = 0;

    for (var index = 0; index < declaredPaths.length; index++) {
      if (_isDisposing || !mounted) {
        return;
      }
      final path = declaredPaths[index];
      if (!await File(path).exists()) {
        missingSegmentsCount++;
        unavailablePaths.add(path);
        continue;
      }
      if (storedTimelinePaths.contains(path)) {
        continue;
      }

      final isTrailingSegment = index == declaredPaths.length - 1;
      final probe = await _probeSegmentDuration(
        path,
        retryOnFailure: isTrailingSegment,
      );
      if (_isDisposing || !mounted) {
        return;
      }
      if (probe.duration > Duration.zero) {
        probedDurationsByPath[path] = probe.duration;
        continue;
      }

      unreadableSegmentsCount++;
      unavailablePaths.add(path);
      if (isTrailingSegment) {
        unreadableTrailingSegmentsCount++;
      }
      debugPrintError(
        'playback',
        'Ride playback: skipped unreadable segment ${index + 1} '
            '(${probe.error ?? 'unknown-error'})',
        level: DiagnosticLogLevel.warning,
      );
    }
    if (_isDisposing || !mounted) {
      return;
    }

    final timeline = buildEffectiveTimeline(
      declaredPaths: declaredPaths,
      storedTimeline: _ride.segmentTimeline,
      probedDurationsByPath: probedDurationsByPath,
    );
    final declaredSet = declaredPaths.toSet();

    _segmentPaths.clear();
    _segmentDurations.clear();
    _segmentOffsets.clear();
    _failedSegmentIndexes.clear();
    final unplayablePaths = <String>{};
    for (final entry in timeline) {
      if (!declaredSet.contains(entry.path) ||
          unavailablePaths.contains(entry.path)) {
        unplayablePaths.add(entry.path);
        continue;
      }
      _segmentPaths.add(entry.path);
      _segmentOffsets.add(Duration(milliseconds: entry.startMs));
      _segmentDurations.add(
        Duration(milliseconds: entry.endMs - entry.startMs),
      );
    }

    final telemetryMs = _ride.samples.isNotEmpty
        ? _ride.samples.last.elapsedMs
        : 0;
    var totalMs = telemetryMs;
    for (final entry in timeline) {
      totalMs = math.max(totalMs, entry.endMs);
    }

    _timelineEntries = timeline;
    _totalDuration = Duration(milliseconds: totalMs);
    _missingSegmentRanges = rangesForPaths(
      timeline: timeline,
      paths: unplayablePaths,
    );
    _failedCheckRanges = rangesForPaths(
      timeline: timeline,
      paths: _integrityFailedPaths,
    );
    _noVideoRanges = uncoveredRanges(timeline: timeline, totalMs: totalMs);
    _lastKnownGlobalPosition = Duration.zero;
    _lockMarkerMs = lockMarkerOffsetsMs(
      playlistPaths: _segmentPaths,
      playlistOffsets: _segmentOffsets,
      lockedPaths: _ride.lockedSegmentPaths,
      totalMs: totalMs,
    );
    // Rides that saved live-detected incidents show exactly those; older
    // files fall back to the sample heuristic.
    final recordedIncidents = _ride.incidents;
    _incidentMarkerMs = recordedIncidents != null
        ? recordedIncidentOffsetsMs(
            elapsedMs: [
              for (final incident in recordedIncidents) incident.elapsedMs,
            ],
            totalMs: totalMs,
          )
        : incidentMarkerOffsetsMs(samples: _ride.samples, totalMs: totalMs);

    var loaded = false;
    for (var index = 0; index < _segmentPaths.length; index++) {
      final outcome = await _loadSegment(index: index, autoPlay: false);
      if (outcome == _SegmentLoadOutcome.cancelled) {
        return;
      }
      if (outcome == _SegmentLoadOutcome.loaded) {
        loaded = true;
        break;
      }
      unreadableSegmentsCount++;
      _markSegmentFailed(index);
    }
    if (!mounted || _isDisposing) {
      return;
    }

    setState(() {
      _isLoading = false;
      if (!loaded) {
        _playbackError = noPlayableVideoMessage(
          declaredCount: declaredPaths.length,
          missingCount: missingSegmentsCount,
          unreadableCount: unreadableSegmentsCount,
        );
      }
    });
    _publishPosition();
    if (!loaded) {
      return;
    }
    _showInitializationWarning(
      missingSegmentsCount: missingSegmentsCount,
      unreadableSegmentsCount: unreadableSegmentsCount,
      unreadableTrailingSegmentsCount: unreadableTrailingSegmentsCount,
    );
  }

  Future<void> _retryPlayback() async {
    final controller = _controller;
    _loadGeneration++;
    _pendingSeek = null;
    _erroredController = null;
    setState(() {
      _controller = null;
      _isLoading = true;
      _playbackError = null;
      _hasShownInitializationWarning = false;
    });
    if (controller != null) {
      controller.removeListener(_onControllerTick);
      unawaited(_stopAndDisposeController(controller));
    }
    await _initializePlayback();
  }

  void _showInitializationWarning({
    required int missingSegmentsCount,
    required int unreadableSegmentsCount,
    required int unreadableTrailingSegmentsCount,
  }) {
    if (!mounted || _hasShownInitializationWarning) {
      return;
    }
    if (missingSegmentsCount <= 0 && unreadableSegmentsCount <= 0) {
      return;
    }

    _hasShownInitializationWarning = true;
    final details = <String>[];
    if (missingSegmentsCount > 0) {
      details.add('$missingSegmentsCount missing');
    }
    if (unreadableSegmentsCount > 0) {
      details.add('$unreadableSegmentsCount unreadable');
    }

    final trailingHint = unreadableTrailingSegmentsCount > 0
        ? ' The last segment was retried once.'
        : '';

    _showMessage(
      'Some ride segments are unavailable (${details.join(', ')}). '
      'They are marked red on the seekbar and skipped.$trailingHint',
    );
  }

  /// Marks the playlist segment at [index] as unplayable and shows its span as
  /// missing footage.
  void _markSegmentFailed(int index) {
    if (index < 0 || index >= _segmentPaths.length) {
      return;
    }
    if (!_failedSegmentIndexes.add(index)) {
      return;
    }
    final start = _segmentOffsets[index];
    final ranges = mergeRanges(<PlaybackRange>[
      ..._missingSegmentRanges,
      PlaybackRange(
        startMs: start.inMilliseconds,
        endMs: (start + _segmentDurations[index]).inMilliseconds,
      ),
    ]);
    if (mounted) {
      setState(() {
        _missingSegmentRanges = ranges;
      });
    } else {
      _missingSegmentRanges = ranges;
    }
  }

  Future<_SegmentProbeResult> _probeDurationOnce(String path) async {
    final probe = VideoPlayerController.file(File(path));
    try {
      await probe.initialize();
      final duration = probe.value.duration;
      if (duration > Duration.zero) {
        return _SegmentProbeResult(duration: duration);
      }
      return const _SegmentProbeResult(
        duration: Duration.zero,
        error: 'duration-is-zero',
      );
    } catch (e) {
      return _SegmentProbeResult(duration: Duration.zero, error: e.toString());
    } finally {
      await probe.dispose();
    }
  }

  Future<_SegmentProbeResult> _probeSegmentDuration(
    String path, {
    required bool retryOnFailure,
  }) async {
    final firstAttempt = await _probeDurationOnce(path);
    if (firstAttempt.duration > Duration.zero ||
        !retryOnFailure ||
        _isDisposing) {
      return firstAttempt;
    }

    await Future<void>.delayed(const Duration(milliseconds: 300));
    final secondAttempt = await _probeDurationOnce(path);
    if (secondAttempt.duration > Duration.zero) {
      return secondAttempt;
    }

    return _SegmentProbeResult(
      duration: Duration.zero,
      error: secondAttempt.error ?? firstAttempt.error,
    );
  }

  Future<VideoPlayerController?> _initializeSegmentController(
    String path, {
    required bool retryOnFailure,
  }) async {
    Future<VideoPlayerController?> tryInitializeOnce() async {
      final controller = VideoPlayerController.file(File(path));
      try {
        await controller.initialize();
        return controller;
      } catch (e) {
        debugPrintError(
          'playback',
          'Ride playback: failed loading segment ($e)',
        );
        await _stopAndDisposeController(controller);
        return null;
      }
    }

    final firstAttempt = await tryInitializeOnce();
    if (firstAttempt != null || !retryOnFailure || _isDisposing) {
      return firstAttempt;
    }

    await Future<void>.delayed(const Duration(milliseconds: 300));
    return tryInitializeOnce();
  }

  /// Initializes the segment at [index] and makes it the active controller.
  ///
  /// Each call takes a new load generation; a load that a later call (or
  /// dispose) supersedes disposes its own controller and reports
  /// [_SegmentLoadOutcome.cancelled]. The controller that is replaced is read
  /// at swap time, so no initialized controller is ever left undisposed.
  Future<_SegmentLoadOutcome> _loadSegment({
    required int index,
    required bool autoPlay,
    Duration initialPosition = Duration.zero,
  }) async {
    if (_isDisposing || !mounted) {
      return _SegmentLoadOutcome.cancelled;
    }
    if (index < 0 || index >= _segmentPaths.length) {
      return _SegmentLoadOutcome.failed;
    }

    final generation = ++_loadGeneration;
    bool isSuperseded() =>
        _isDisposing || !mounted || generation != _loadGeneration;

    final current = _controller;
    if (current != null && current.value.isInitialized) {
      _lastKnownGlobalPosition = _globalPosition();
    }

    final retryOnFailure = index == _segmentPaths.length - 1;
    final controller = await _initializeSegmentController(
      _segmentPaths[index],
      retryOnFailure: retryOnFailure,
    );
    if (controller == null) {
      return isSuperseded()
          ? _SegmentLoadOutcome.cancelled
          : _SegmentLoadOutcome.failed;
    }

    Duration clampedPosition;
    try {
      if (isSuperseded()) {
        await _stopAndDisposeController(controller);
        return _SegmentLoadOutcome.cancelled;
      }
      await controller.setLooping(false);

      clampedPosition = clampDuration(
        initialPosition,
        controller.value.duration,
      );
      if (clampedPosition > Duration.zero) {
        await controller.seekTo(clampedPosition);
      }
    } catch (_) {
      await _stopAndDisposeController(controller);
      return isSuperseded()
          ? _SegmentLoadOutcome.cancelled
          : _SegmentLoadOutcome.failed;
    }

    if (isSuperseded()) {
      await _stopAndDisposeController(controller);
      return _SegmentLoadOutcome.cancelled;
    }

    final replaced = _controller;
    replaced?.removeListener(_onControllerTick);
    controller.addListener(_onControllerTick);
    final actualDuration = controller.value.duration;
    setState(() {
      _controller = controller;
      _activeSegmentIndex = index;
      if (actualDuration > Duration.zero) {
        _segmentDurations[index] = actualDuration;
      }
      _lastKnownGlobalPosition = clampDuration(
        _segmentOffsets[index] + clampedPosition,
        _totalDuration,
      );
    });
    _publishPosition();

    if (replaced != null && !identical(replaced, controller)) {
      // Dispose the replaced controller after the new one is mounted to avoid
      // a transient "used after dispose" during widget handoff.
      unawaited(_stopAndDisposeController(replaced));
    }

    if (autoPlay && _isAppInForeground && !_isDisposing && !_isScrubbing) {
      try {
        await controller.play();
      } catch (_) {
        // A playback error is reported through the controller value.
      }
    }
    return _SegmentLoadOutcome.loaded;
  }

  void _onControllerTick() {
    if (_isDisposing) {
      return;
    }

    final controller = _controller;
    if (controller == null) {
      return;
    }
    _publishPosition();
    if (controller.value.hasError) {
      _handleRuntimeError(controller);
      return;
    }
    if (!controller.value.isInitialized) {
      return;
    }

    _lastKnownGlobalPosition = _globalPositionFromController(
      controller,
      _activeSegmentIndex,
    );

    if (controller.value.isCompleted &&
        !_isSegmentLoadInFlight &&
        _nextPlayableIndex(_activeSegmentIndex + 1) != null) {
      _lastKnownGlobalPosition = clampDuration(
        _segmentOffsets[_activeSegmentIndex] +
            _segmentDurations[_activeSegmentIndex],
        _totalDuration,
      );
      unawaited(_advanceToNextSegment());
    }
  }

  /// Handles a decode or source error reported after a segment loaded: marks
  /// the segment as unplayable and moves on to the next playable one.
  void _handleRuntimeError(VideoPlayerController controller) {
    if (identical(_erroredController, controller)) {
      return;
    }
    _erroredController = controller;
    final index = _activeSegmentIndex;
    debugPrintError(
      'playback',
      'Ride playback: segment ${index + 1} failed during playback '
          '(${controller.value.errorDescription})',
    );
    _markSegmentFailed(index);

    final hasNext = _nextPlayableIndex(index + 1) != null;
    _showMessage(
      hasNext
          ? 'Segment ${index + 1} could not be played. Skipping to the next segment.'
          : 'Playback ended: segment ${index + 1} could not be played.',
    );
    if (hasNext && !_isSegmentLoadInFlight) {
      unawaited(_advanceToNextSegment());
    }
  }

  int? _nextPlayableIndex(int from) {
    for (var index = math.max(from, 0); index < _segmentPaths.length; index++) {
      if (!_failedSegmentIndexes.contains(index)) {
        return index;
      }
    }
    return null;
  }

  Future<void> _advanceToNextSegment() async {
    if (_isSegmentLoadInFlight || _isDisposing) {
      return;
    }

    _isSwitchingSegment = true;
    try {
      var candidate = _nextPlayableIndex(_activeSegmentIndex + 1);
      while (candidate != null && !_isDisposing) {
        final outcome = await _loadSegment(index: candidate, autoPlay: true);
        if (outcome != _SegmentLoadOutcome.failed) {
          return;
        }
        _markSegmentFailed(candidate);
        candidate = _nextPlayableIndex(candidate + 1);
      }
      if (_isDisposing) {
        return;
      }
      await _stopPlayback();
      _showMessage(
        'Playback ended: the remaining segments could not be opened.',
      );
    } finally {
      _isSwitchingSegment = false;
      _drainPendingSeek();
    }
  }

  Future<void> _stopPlayback() async {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    if (controller.value.isPlaying) {
      await controller.pause();
    }
  }

  Future<void> _stopAndDisposeController(
    VideoPlayerController controller,
  ) async {
    try {
      if (controller.value.isPlaying) {
        await controller.pause();
      }
    } catch (_) {
      // Best effort pause before dispose.
    }
    await controller.dispose();
  }

  Duration _globalPosition() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return _lastKnownGlobalPosition;
    }

    return _globalPositionFromController(controller, _activeSegmentIndex);
  }

  Duration _globalPositionFromController(
    VideoPlayerController controller,
    int segmentIndex,
  ) {
    final offset = segmentIndex < _segmentOffsets.length
        ? _segmentOffsets[segmentIndex]
        : Duration.zero;
    return globalPlaybackPosition(
      segmentOffset: offset,
      localPosition: controller.value.position,
      total: _totalDuration,
    );
  }

  /// Publishes the position the body shows (the scrub preview while the
  /// rider drags, otherwise the playing position) and whether the video is
  /// playing. Widgets that show the position listen to the notifier; an
  /// unchanged value notifies nobody.
  void _publishPosition() {
    if (_isDisposing) {
      return;
    }
    _positionNotifier.value = PlaybackPosition(
      position: _isScrubbing
          ? (_scrubPreviewPosition ?? _globalPosition())
          : _globalPosition(),
      isPlaying: _controller?.value.isPlaying ?? false,
    );
  }

  /// Seeks to [target] on the ride timeline.
  ///
  /// While a segment load is in flight the request is not started; the latest
  /// one is kept and runs when the load finishes, so only one segment load
  /// ever runs at a time.
  Future<void> _seekGlobal(
    Duration target, {
    required bool shouldResume,
  }) async {
    if (_isDisposing ||
        _segmentPaths.isEmpty ||
        _totalDuration == Duration.zero) {
      return;
    }
    if (_isSegmentLoadInFlight) {
      // During an auto-advance the finished segment reports "not playing",
      // but the advance itself resumes playback, so keep it going.
      _pendingSeek = _PendingSeek(target, shouldResume || _isSwitchingSegment);
      return;
    }

    final current = _controller;
    if (current == null) {
      return;
    }
    final safeTarget = clampDuration(target, _totalDuration);
    final seekTarget = locateSegment(
      offsets: _segmentOffsets,
      durations: _segmentDurations,
      position: safeTarget,
    );

    // A segment that failed during playback is skipped like any other
    // unplayable segment instead of seeking its errored controller.
    if (seekTarget.segmentIndex == _activeSegmentIndex &&
        !_failedSegmentIndexes.contains(_activeSegmentIndex)) {
      _lastKnownGlobalPosition = safeTarget;
      try {
        await current.seekTo(seekTarget.localPosition);
        // An auto-advance may have replaced (and disposed) this controller
        // while the seek ran.
        if (shouldResume &&
            _isAppInForeground &&
            !_isDisposing &&
            !_isScrubbing &&
            identical(_controller, current)) {
          await current.play();
        }
      } catch (e) {
        debugPrintError('playback', 'Ride playback: seek failed ($e)');
      }
      return;
    }

    _isSeekingAcrossSegments = true;
    try {
      var candidate = seekTarget.segmentIndex;
      var initialPosition = seekTarget.localPosition;
      var outcome = _SegmentLoadOutcome.failed;

      while (candidate < _segmentPaths.length && !_isDisposing) {
        if (_failedSegmentIndexes.contains(candidate)) {
          candidate++;
          initialPosition = Duration.zero;
          continue;
        }
        outcome = await _loadSegment(
          index: candidate,
          autoPlay: false,
          initialPosition: initialPosition,
        );
        if (outcome != _SegmentLoadOutcome.failed) {
          break;
        }
        _markSegmentFailed(candidate);
        candidate++;
        initialPosition = Duration.zero;
      }

      if (_isDisposing || outcome == _SegmentLoadOutcome.cancelled) {
        return;
      }
      if (outcome == _SegmentLoadOutcome.failed) {
        if (mounted) {
          setState(() {});
        }
        _showMessage(
          'No playable video at ${_formatDuration(safeTarget)} or later.',
        );
        return;
      }

      if (shouldResume && _isAppInForeground && !_isScrubbing) {
        try {
          await _controller?.play();
        } catch (_) {
          // A playback error is reported through the controller value.
        }
      }
    } finally {
      _isSeekingAcrossSegments = false;
      _drainPendingSeek();
    }
  }

  void _drainPendingSeek() {
    final pending = _pendingSeek;
    if (pending == null || _isDisposing || _isSegmentLoadInFlight) {
      return;
    }
    _pendingSeek = null;
    unawaited(_seekGlobal(pending.target, shouldResume: pending.shouldResume));
  }

  Future<void> _beginScrub() async {
    if (_isDisposing) {
      return;
    }

    // A scrub may start while a segment loads: the seek it commits is queued
    // by _seekGlobal. During an auto-advance the finished segment reports
    // "not playing", but playback is meant to continue.
    final wasPlaying = _controller?.value.isPlaying ?? false;
    _resumeAfterScrub = wasPlaying || _isSwitchingSegment;
    _isScrubbing = true;
    _scrubPreviewPosition = _globalPosition();
    if (wasPlaying) {
      await _stopPlayback();
    }
    _publishPosition();
  }

  void _updateScrubPreview(Duration target) {
    if (_isDisposing) {
      return;
    }

    _scrubPreviewPosition = clampDuration(target, _totalDuration);
    _publishPosition();
  }

  Future<void> _commitScrub(Duration target) async {
    if (_isDisposing) {
      return;
    }

    final shouldResume = _resumeAfterScrub;
    _isScrubbing = false;
    _resumeAfterScrub = false;
    _scrubPreviewPosition = null;
    _publishPosition();
    await _seekGlobal(target, shouldResume: shouldResume);
  }

  /// Seeks to [target] (a speed-graph tap), resuming playback if it was
  /// playing.
  void _seekFromGraph(Duration target) {
    if (_isDisposing) {
      return;
    }
    unawaited(
      _seekGlobal(target, shouldResume: _controller?.value.isPlaying ?? false),
    );
  }

  /// Seeks by [offset] from the displayed position (the 10 second buttons).
  void _seekBy(Duration offset) {
    unawaited(
      _seekGlobal(
        _positionNotifier.value.position + offset,
        shouldResume: _controller?.value.isPlaying ?? false,
      ),
    );
  }

  /// Plays when paused, pauses when playing.
  void _togglePlay() {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    if (controller.value.isPlaying) {
      unawaited(controller.pause());
    } else {
      unawaited(controller.play());
    }
  }

  /// Commits a seekbar release at [valueMs]. A release within
  /// [_markerTapTolerancePx] of a marker snaps to that marker, so a tap on a
  /// marker issues exactly one seek.
  Future<void> _commitSeekbarValue(double valueMs, double sliderWidth) async {
    final totalMs = _totalDuration.inMilliseconds;
    final toleranceMs = sliderWidth > 0
        ? _markerTapTolerancePx / sliderWidth * totalMs
        : 0.0;
    final marker = nearestMarker(
      markers: timelineMarkers(
        incidentMarkerMs: _incidentMarkerMs,
        lockMarkerMs: _lockMarkerMs,
      ),
      valueMs: valueMs.round(),
      toleranceMs: toleranceMs,
    );
    final target = Duration(milliseconds: marker?.elapsedMs ?? valueMs.round());
    await _commitScrub(target);
    if (marker == null || !mounted) {
      return;
    }
    final markerLabel = marker.type == PlaybackMarkerType.incident
        ? 'incident'
        : 'locked';
    _showMessage(
      'Jumped to $markerLabel marker at ${_formatDuration(target)}',
      duration: const Duration(milliseconds: 1200),
      replaceCurrent: true,
    );
  }

  void _toggleFullscreenPlayback() {
    if (!mounted) {
      return;
    }
    setState(() {
      _isFullscreenPlayback = !_isFullscreenPlayback;
    });
  }

  String _formatDuration(Duration value) => formatElapsed(value);

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final playbackError = _playbackError;

    return Scaffold(
      appBar: _isFullscreenPlayback
          ? null
          : AppBar(
              title: const Text('Ride Playback'),
              actions: [
                if (_ride.expectedSegmentHashes.isNotEmpty)
                  IconButton(
                    tooltip: _isCheckingSegments
                        ? 'Checking videos'
                        : 'Check videos again',
                    onPressed: _isLoading ? null : _checkVideosAgain,
                    icon: _isCheckingSegments
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.fact_check_outlined),
                  ),
                if (_exportProgress case final progress?)
                  _buildRideActions(progress),
              ],
            ),
      body: playbackError != null
          ? PlaybackErrorView(
              message: playbackError,
              onBack: () => Navigator.of(context).maybePop(),
              onRetry: _retryPlayback,
            )
          : _isLoading || controller == null
          ? const Center(child: CircularProgressIndicator())
          : RidePlaybackBody(
              video: PlaybackVideoSurface(
                controller: controller,
                onTap: _toggleFullscreenPlayback,
              ),
              samples: _ride.samples,
              maxSpeed: _maxSampleSpeed,
              sampleAt: _ride.sampleForPosition,
              position: _positionNotifier,
              totalDuration: _totalDuration,
              marks: PlaybackTimelineMarks(
                missingRanges: _missingSegmentRanges,
                failedCheckRanges: _failedCheckRanges,
                noVideoRanges: _noVideoRanges,
                incidentMarkerMs: _incidentMarkerMs,
                lockMarkerMs: _lockMarkerMs,
              ),
              isFullscreen: _isFullscreenPlayback,
              showRouteMap: _showRouteMap,
              segmentNumber: _activeSegmentIndex + 1,
              segmentCount: _segmentPaths.length,
              onToggleFullscreen: _toggleFullscreenPlayback,
              onToggleRouteMap: _toggleRouteMapVisibility,
              onSeek: _seekFromGraph,
              onSeekBy: _seekBy,
              onTogglePlay: _togglePlay,
              onScrubStart: () => unawaited(_beginScrub()),
              onScrubUpdate: _updateScrubPreview,
              onGraphScrubEnd: (target) => unawaited(_commitScrub(target)),
              onSeekbarScrubEnd: (valueMs, width) =>
                  unawaited(_commitSeekbarValue(valueMs, width)),
            ),
    );
  }

  @override
  void dispose() {
    _isDisposing = true;
    // Stops the segment check after the segment being hashed.
    _segmentCheckToken?.cancel();
    _loadGeneration++;
    _pendingSeek = null;
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_onControllerTick);
      unawaited(_stopAndDisposeController(controller));
    }
    _positionNotifier.dispose();
    super.dispose();
  }
}

class _SegmentProbeResult {
  const _SegmentProbeResult({required this.duration, this.error});

  final Duration duration;
  final String? error;
}
