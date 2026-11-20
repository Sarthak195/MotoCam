// lib/features/recording/recording_screen.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/providers/app_settings_provider.dart';
import '../../core/services/app_permission_service.dart';
import '../../core/services/background_recording_service.dart';
import '../../core/services/device_status_service.dart';
import '../../core/services/pip_service.dart';
import '../camera/providers/camera_init_status.dart';
import '../camera/providers/camera_provider.dart';
import '../telemetry/providers/telemetry_provider.dart';
import '../history/rides_list_screen.dart';
import '../history/widgets/recordings_migration_banner.dart';
import 'recording_screen_logic.dart';
import 'ride_orientation.dart';
import 'widgets/recording_settings_sheet.dart';
import 'start_preflight_evaluator.dart';
import 'widgets/start_preflight_sheet.dart';
import '../../core/theme/tokens.dart';
import 'widgets/recording_controls.dart';
import 'widgets/recording_details_panel.dart';
import 'widgets/recording_header.dart';
import 'widgets/recording_landscape.dart';
import 'widgets/recording_preview.dart';
import 'widgets/recording_profile_bar.dart';
import 'widgets/recording_stats.dart';
import 'widgets/recording_view_state.dart';

/// The app's home screen: camera preview, live telemetry and the controls
/// that start, stop and lock recordings.
///
/// It coordinates the recording session across [CameraProvider],
/// [TelemetryProvider], [AppSettingsProvider], the Android foreground
/// service and Picture-in-Picture.
class RecordingScreen extends StatefulWidget {
  /// Creates the recording screen. [landscapeRecording] defaults to the
  /// build switch [kLandscapeRecording]; tests turn it on directly.
  const RecordingScreen({
    super.key,
    @visibleForTesting this.landscapeRecording = kLandscapeRecording,
  });

  /// Whether the landscape recording engine runs (see ride_orientation.dart).
  final bool landscapeRecording;

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen>
    with WidgetsBindingObserver {
  DateTime? _lastHandledIncidentAt;
  final BackgroundStallTracker _stallTracker = BackgroundStallTracker();
  // Watches the in-progress clip file while the app is in the background
  // (Android), so a resume can skip the stall restart when capture
  // demonstrably continued.
  late final BackgroundCaptureMonitor _captureMonitor =
      BackgroundCaptureMonitor(probe: _probeNewestRecordingFile);
  final BackgroundRecordingService _backgroundRecordingService =
      BackgroundRecordingService.instance;
  final PipService _pipService = PipService.instance;
  final AppPermissionService _permissionService = const AppPermissionService();
  final DeviceStatusService _deviceStatusService = DeviceStatusService();
  StreamSubscription<BackgroundRecordingEvent>? _backgroundEventSubscription;
  StreamSubscription<Duration>? _recordingTimerSubscription;
  StreamSubscription<bool>? _pipModeSubscription;
  Timer? _deviceStatusTimer;
  bool _isStartingRecording = false;
  bool _isStoppingRecording = false;
  bool _isApplyingSettings = false;
  bool _isBootstrapping = false;
  // Set once a camera initialization attempt (or the bootstrap) finished, so
  // a failure state is not shown while the first attempt is still pending.
  bool _cameraInitAttempted = false;
  // Camera settings saved while recording; applied before the next START.
  bool _hasPendingCameraSettings = false;
  // Completed on the next AppLifecycleState.resumed after a system settings
  // screen was opened.
  Completer<void>? _resumeWaiter;
  bool _isInPipMode = false;
  bool _isRecoveringFromStall = false;
  bool _isFetchingDeviceStatus = false;
  bool _isNavigatingHistory = false;
  bool _isBlackoutMode = false;
  String? _inAppNoticeText;
  // Only the Battery and Temp items listen, so a poll that changes the
  // temperature does not rebuild the whole screen.
  final ValueNotifier<DeviceStatusSnapshot> _deviceStatus = ValueNotifier(
    DeviceStatusSnapshot.empty,
  );
  // Free bytes for recordings, read with the device status every 15 s; null
  // when unknown. Only the storage chip and the details panel listen.
  final ValueNotifier<int?> _freeStorageBytes = ValueNotifier(null);
  Timer? _inAppNoticeTimer;
  Timer? _blackoutExitHoldTimer;
  bool _blackoutExitTriggered = false;
  TelemetryProvider? _telemetryProvider;
  CameraProvider? _cameraProvider;
  // Recording failure already reacted to (see _onCameraChanged).
  String? _handledRecordingError;
  // Gallery export summary already shown.
  String? _shownGalleryExportMessage;
  // Storage budget notice already shown.
  String? _shownStorageBudgetMessage;
  // Segment and lock state of the last ride checkpoint.
  final RideCheckpointTracker _checkpointTracker = RideCheckpointTracker();
  bool _isOfferingBatteryExemption = false;
  // Landscape recording: pins the UI to the orientation the phone is held
  // in while this screen is idle and visible; frozen from the START tap to
  // the end of the ride (see _syncOrientationPin). Inert with the switch
  // off: no sensor subscription and no pin beyond main.dart's portrait one.
  late final RideOrientationPinner _orientationPinner = RideOrientationPinner(
    enabled: widget.landscapeRecording,
    gravity: () =>
        _telemetryProvider?.gravitySamples ??
        const Stream<({double x, double y, double z, DateTime at})>.empty(),
    onPin: _applyPinnedOrientation,
  );
  AppLifecycleState? _appLifecycleState =
      WidgetsBinding.instance.lifecycleState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initializePipBridge());
    unawaited(_initializeBackgroundRecordingBridge());
    _startDeviceStatusPolling();
    unawaited(_bootstrapRuntimePrerequisites());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final telemetry = Provider.of<TelemetryProvider>(context, listen: false);
    if (_telemetryProvider != telemetry) {
      _telemetryProvider?.removeListener(_onTelemetryChanged);
      _telemetryProvider = telemetry;
      _telemetryProvider?.addListener(_onTelemetryChanged);
    }
    final camera = Provider.of<CameraProvider>(context, listen: false);
    if (_cameraProvider != camera) {
      _cameraProvider?.removeListener(_onCameraChanged);
      _cameraProvider = camera;
      _cameraProvider?.addListener(_onCameraChanged);
    }
    _syncOrientationPin();
  }

  /// Landscape recording: classifies gravity (and so may re-pin the UI)
  /// only while no ride is starting, running or stopping, the app is in the
  /// foreground and not in PiP. Otherwise the pin stays where it is, which
  /// freezes a ride's orientation from the START tap to the end of its
  /// stop.
  ///
  /// The parked screens (Ride History, playback and Settings, which cover
  /// this screen) keep the classifier running while idle, so they follow
  /// the phone's orientation as this screen does, by MotoCam's own gravity
  /// classifier and never by Android auto-rotate (which riders may have
  /// off). Settings opened during a ride stays frozen with the ride.
  void _syncOrientationPin() {
    if (!widget.landscapeRecording) {
      return;
    }
    final camera = _cameraProvider;
    final rideBusy =
        camera == null ||
        camera.isRecording ||
        camera.isStartingRecording ||
        camera.isStoppingRecording ||
        _isStartingRecording ||
        _isStoppingRecording;
    final visible =
        _appLifecycleState == null ||
        _appLifecycleState == AppLifecycleState.resumed;
    _orientationPinner.setWatching(
      mounted && !rideBusy && visible && !_isInPipMode,
    );
  }

  /// Applies a new pinned orientation: the UI follows it and the idle
  /// camera locks its capture to it, so the preview stays upright.
  Future<void> _applyPinnedOrientation(DeviceOrientation orientation) async {
    if (mounted) {
      setState(() {});
    }
    try {
      await SystemChrome.setPreferredOrientations([orientation]);
    } catch (e) {
      debugPrint('Pinning the UI to ${orientation.name} failed: $e');
    }
    await _cameraProvider?.setIdleCaptureOrientation(orientation);
  }

  /// Reacts to camera-provider state that needs more than a rebuild: a
  /// recording failure while recording (stop and save the ride once, then
  /// tell the rider), a finished gallery export and the storage budget's
  /// notice.
  void _onCameraChanged() {
    final camera = _cameraProvider;
    if (!mounted || camera == null) {
      return;
    }
    _syncOrientationPin();

    final error = camera.lastRecordingError;
    if (error != null &&
        camera.isRecording &&
        !camera.isStoppingRecording &&
        !_isStoppingRecording &&
        error != _handledRecordingError) {
      _handledRecordingError = error;
      // Not tied to frames: this also runs while the app is in the
      // background, where post-frame callbacks do not.
      unawaited(Future<void>.microtask(() => _stopAfterRecordingFault(error)));
    }

    // The provider keeps its last summary and builds a new String for each
    // export run, so identity (not equality) tells a new run from the one
    // already shown, including a later run with the same wording.
    final exportMessage = camera.lastGalleryExportMessage;
    if (exportMessage != null &&
        !identical(exportMessage, _shownGalleryExportMessage)) {
      _shownGalleryExportMessage = exportMessage;
      unawaited(
        Future<void>.microtask(() {
          if (!mounted) {
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(exportMessage),
              duration: const Duration(seconds: 5),
            ),
          );
        }),
      );
    }

    // At most one per recording session (the provider sets it once).
    final budgetMessage = camera.lastStorageBudgetMessage;
    if (budgetMessage != null &&
        !identical(budgetMessage, _shownStorageBudgetMessage)) {
      _shownStorageBudgetMessage = budgetMessage;
      unawaited(
        Future<void>.microtask(() {
          if (!mounted) {
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(budgetMessage),
              duration: const Duration(seconds: 6),
            ),
          );
        }),
      );
    }
  }

  /// Stops and saves the ride after the camera reported that recording
  /// cannot continue (failed segment restart, stop failure or low storage),
  /// then tells the rider why it stopped.
  Future<void> _stopAfterRecordingFault(String error) async {
    if (!mounted) {
      return;
    }
    final camera = context.read<CameraProvider>();
    if (!camera.isRecording) {
      return;
    }
    final telemetry = context.read<TelemetryProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await _stopRecordingFlow(
      camera: camera,
      telemetry: telemetry,
      messenger: messenger,
      showSuccessMessage: false,
    );
    if (!mounted || outcome == _StopOutcome.skipped) {
      return;
    }
    // A failed save or stop already has its own SnackBar (with Retry for
    // the telemetry save), so only claim what actually happened.
    final String result;
    switch (outcome) {
      case _StopOutcome.saved:
        result = ' The ride so far was saved.';
        break;
      case _StopOutcome.videoOnly:
        result = ' The video recorded so far was kept.';
        break;
      case _StopOutcome.saveFailed:
      case _StopOutcome.stopFailed:
      case _StopOutcome.nothingSaved:
      case _StopOutcome.skipped:
        result = '';
        break;
    }
    _showInAppNotice('Recording stopped', duration: const Duration(seconds: 4));
    messenger.showSnackBar(
      SnackBar(
        content: Text('Recording stopped: $error$result'),
        duration: const Duration(seconds: 10),
      ),
    );
  }

  void _onTelemetryChanged() {
    if (!mounted) return;
    final telemetry = context.read<TelemetryProvider>();
    final camera = context.read<CameraProvider>();
    _handleIncidentAutoLock(camera: camera, telemetry: telemetry);
  }

  Future<void> _bootstrapRuntimePrerequisites() async {
    if (_isBootstrapping) {
      return;
    }

    _isBootstrapping = true;
    try {
      final settings = context.read<AppSettingsProvider>();
      if (!settings.isLoaded) {
        await settings.load();
      }
      if (!mounted) {
        return;
      }

      final permissionAudit = await _permissionService
          .ensureRequiredPermissions(
            audioEnabled: settings.audioEnabled,
            galleryExportEnabled: settings.exportLockedClipsToGallery,
          );
      if (!mounted) {
        return;
      }

      final resolvedAudit = await _handlePermissionAuditResult(
        permissionAudit,
        audioEnabled: settings.audioEnabled,
      );
      if (!mounted) {
        return;
      }
      if (resolvedAudit.hasBlockingIssues) {
        // The camera is not initialized; say why instead of leaving the
        // preview area without a reason.
        await _reportPermissionBlock(settings);
        return;
      }

      await _initializeCamera();
    } finally {
      _isBootstrapping = false;
      if (mounted) {
        setState(() {
          _cameraInitAttempted = true;
        });
      }
    }
  }

  /// Records why setup stopped at the permission audit as the camera's init
  /// failure, from the current permission statuses. A missing required
  /// permission that is neither camera nor microphone is the location one.
  Future<void> _reportPermissionBlock(AppSettingsProvider settings) async {
    final cameraStatus = await Permission.camera.status;
    final microphoneStatus = await Permission.microphone.status;
    if (!mounted) {
      return;
    }
    final failure =
        cameraInitFailureForPermissions(
          camera: cameraStatus,
          microphone: microphoneStatus,
          audioEnabled: settings.audioEnabled,
        ) ??
        const CameraInitFailure(
          CameraInitFailureReason.locationPermissionDenied,
        );
    context.read<CameraProvider>().reportInitBlocked(failure);
  }

  /// Retries the permission audit and camera initialization (Retry button
  /// of the camera-unavailable state).
  void _retryCameraSetup() {
    if (_isBootstrapping) {
      return;
    }
    unawaited(_bootstrapRuntimePrerequisites());
    // The bootstrap sets _isBootstrapping synchronously; rebuild to show the
    // spinner instead of the failure state.
    setState(() {});
  }

  Future<void> _openAppSettingsAndRetry() async {
    await _openSystemSettingsAndWaitForReturn(openAppSettings);
    if (!mounted) {
      return;
    }
    _retryCameraSetup();
  }

  /// Opens a system settings screen with [open] and waits until the app is
  /// resumed again (or two minutes pass), so callers re-check permissions or
  /// location services only after the rider has come back.
  Future<void> _openSystemSettingsAndWaitForReturn(
    Future<bool> Function() open,
  ) async {
    final waiter = Completer<void>();
    _resumeWaiter = waiter;

    var opened = false;
    try {
      opened = await open();
    } catch (e) {
      debugPrint('Opening system settings failed: $e');
    }

    if (opened) {
      await waiter.future.timeout(const Duration(minutes: 2), onTimeout: () {});
    }
    if (identical(_resumeWaiter, waiter)) {
      _resumeWaiter = null;
    }
  }

  /// Re-initializes the camera after the app returns to the foreground while
  /// idle, when it is not initialized and the permissions it needs are now
  /// granted (for example after the rider granted them in system settings).
  void _retryCameraInitAfterResume(CameraProvider camera) {
    if (_isBootstrapping ||
        _isStartingRecording ||
        _isStoppingRecording ||
        _isApplyingSettings ||
        _isNavigatingHistory ||
        camera.isInitialized ||
        camera.isInitializing ||
        camera.isStartingRecording ||
        camera.isStoppingRecording) {
      return;
    }
    unawaited(_initializeCameraIfPermitted());
  }

  Future<void> _initializeCameraIfPermitted() async {
    final settings = context.read<AppSettingsProvider>();
    final cameraStatus = await Permission.camera.status;
    var granted = AppPermissionService.isPermissionGranted(cameraStatus);
    if (granted && settings.audioEnabled) {
      final micStatus = await Permission.microphone.status;
      granted = AppPermissionService.isPermissionGranted(micStatus);
    }
    if (!mounted || !granted) {
      return;
    }
    await _initializeCamera();
  }

  Future<PermissionAuditResult> _handlePermissionAuditResult(
    PermissionAuditResult audit, {
    required bool audioEnabled,
  }) async {
    var resolvedAudit = audit;

    if (resolvedAudit.hasBlockingIssues && mounted) {
      final permissionAction = await showDialog<_PermissionRecoveryAction>(
        context: context,
        builder: (dialogContext) {
          final missing = resolvedAudit.missingRequired.join(', ');
          final permanentNote = resolvedAudit.hasPermanentlyDenied
              ? '\n\nPermanently denied: ${resolvedAudit.permanentlyDeniedRequired.join(', ')}. Use Open Settings to enable them.'
              : '';
          return AlertDialog(
            title: const Text('Permissions Required'),
            content: Text(
              'Recording cannot start until these permissions are granted:\n$missing$permanentNote',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(_PermissionRecoveryAction.dismiss),
                child: const Text('Later'),
              ),
              TextButton(
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(_PermissionRecoveryAction.retryRequest),
                child: const Text('Request Again'),
              ),
              TextButton(
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(_PermissionRecoveryAction.openSettings),
                child: const Text('Open Settings'),
              ),
            ],
          );
        },
      );

      if (!mounted) {
        return resolvedAudit;
      }

      switch (permissionAction) {
        case _PermissionRecoveryAction.retryRequest:
          resolvedAudit = await _permissionService.ensureRequiredPermissions(
            audioEnabled: audioEnabled,
          );
          break;
        case _PermissionRecoveryAction.openSettings:
          await _openSystemSettingsAndWaitForReturn(openAppSettings);
          if (!mounted) {
            return resolvedAudit;
          }
          resolvedAudit = await _permissionService.ensureRequiredPermissions(
            audioEnabled: audioEnabled,
          );
          break;
        case _PermissionRecoveryAction.dismiss:
        case null:
          break;
      }
    }

    if (!mounted || !resolvedAudit.hasAnyIssue) {
      return resolvedAudit;
    }

    // The battery-optimization exemption is never requested automatically;
    // it is offered once, after a saved ride. Stop listing it once that offer
    // was made.
    final batteryOffered = await _backgroundRecordingService
        .hasOfferedBatteryOptimizationExemption();
    if (!mounted) {
      return resolvedAudit;
    }
    final recommended = resolvedAudit.missingRecommended
        .where(
          (issue) =>
              !(batteryOffered && issue == _batteryOptimizationIssueLabel),
        )
        .toList();
    if (!resolvedAudit.hasBlockingIssues && recommended.isEmpty) {
      return resolvedAudit;
    }

    final issues = <String>[...resolvedAudit.missingRequired, ...recommended];
    final message = resolvedAudit.hasBlockingIssues
        ? 'Required permissions missing: ${resolvedAudit.missingRequired.join(', ')}'
        : 'Recommended for reliable background recording: ${issues.join(', ')}';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );

    return resolvedAudit;
  }

  void _startDeviceStatusPolling() {
    unawaited(_refreshDeviceStatus());
    unawaited(_refreshFreeStorage());
    _deviceStatusTimer?.cancel();
    _deviceStatusTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_refreshDeviceStatus());
      unawaited(_refreshFreeStorage());
    });
  }

  // Updates only the storage notifier, never the whole screen.
  Future<void> _refreshFreeStorage() async {
    if (!mounted) {
      return;
    }
    final freeBytes = await context
        .read<CameraProvider>()
        .availableStorageBytes();
    if (!mounted) {
      return;
    }
    _freeStorageBytes.value = freeBytes;
  }

  Future<void> _refreshDeviceStatus() async {
    if (_isFetchingDeviceStatus || !mounted) {
      return;
    }

    _isFetchingDeviceStatus = true;
    try {
      final snapshot = await _deviceStatusService.getBatteryAndThermalStatus();
      if (!mounted) {
        return;
      }
      _deviceStatus.value = snapshot;
    } finally {
      _isFetchingDeviceStatus = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) {
      return;
    }
    _appLifecycleState = state;
    _syncOrientationPin();

    final camera = context.read<CameraProvider>();
    if (_isBlackoutMode && leavesBlackoutOnLifecycle(state)) {
      unawaited(_exitBlackoutMode(camera: camera));
    }

    final wasBackgrounded = _stallTracker.backgroundedAt != null;
    final backgroundDuration = _stallTracker.onLifecycleChanged(
      state,
      isRecording: camera.isRecording,
      now: DateTime.now(),
    );
    final backgroundedAt = _stallTracker.backgroundedAt;
    if (!wasBackgrounded &&
        backgroundedAt != null &&
        defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_captureMonitor.start(backgroundedAt));
    }
    if (state != AppLifecycleState.resumed) {
      return;
    }
    if (backgroundDuration == null ||
        !camera.isRecording ||
        _resumeWaiter != null) {
      // No recovery decision follows this resume.
      _captureMonitor.reset();
    }

    final resumeWaiter = _resumeWaiter;
    if (resumeWaiter != null) {
      // The flow that opened a system settings screen re-checks itself.
      _resumeWaiter = null;
      if (!resumeWaiter.isCompleted) {
        resumeWaiter.complete();
      }
      return;
    }

    if (!camera.isRecording) {
      _retryCameraInitAfterResume(camera);
      return;
    }

    if (backgroundDuration == null) {
      return;
    }

    unawaited(
      _attemptRecoveryFromPossibleVideoStall(
        backgroundDuration: backgroundDuration,
      ),
    );
  }

  Future<void> _attemptRecoveryFromPossibleVideoStall({
    required Duration backgroundDuration,
  }) async {
    if (_isRecoveringFromStall || !mounted) {
      _captureMonitor.reset();
      return;
    }

    _isRecoveringFromStall = true;
    final messenger = ScaffoldMessenger.of(context);
    final camera = context.read<CameraProvider>();

    try {
      // Restart unless the clip file shows that capture went on in the
      // background (Android only; anything uncertain means restart).
      final continued = await _captureMonitor.finish(DateTime.now());
      if (!mounted) {
        return;
      }
      if (continued) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Recording continued in the background.'),
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }

      final recovered = await camera.recoverRecordingPipeline(
        reason: 'resume-after-background-${backgroundDuration.inSeconds}s',
      );
      if (!mounted) {
        return;
      }

      if (recovered) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Recording was restarted after ${backgroundDuration.inSeconds}s in the background in case the video feed stalled.',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Recording resumed from background. If video appears frozen, stop and restart recording.',
            ),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } finally {
      _isRecoveringFromStall = false;
    }
  }

  /// Newest in-progress clip file written by the camera plugin, for
  /// [_captureMonitor].
  Future<RecordingFileSample?> _probeNewestRecordingFile() async {
    return newestRecordingFileIn(await getTemporaryDirectory());
  }

  Future<void> _initializePipBridge() async {
    await _pipService.initialize();
    _isInPipMode = _pipService.isInPipMode;
    await _pipModeSubscription?.cancel();
    _pipModeSubscription = _pipService.pipModeStream.listen((inPip) {
      if (!mounted) {
        return;
      }

      if (_isInPipMode && !inPip) {
        Future<void>.delayed(const Duration(milliseconds: 200), () {
          if (!mounted) {
            return;
          }
          setState(() {
            _isInPipMode = false;
          });
          _syncOrientationPin();
        });
        return;
      }

      setState(() {
        _isInPipMode = inPip;
      });
      _syncOrientationPin();
    });
  }

  Future<void> _initializeBackgroundRecordingBridge() async {
    await _backgroundRecordingService.initialize();
    await _backgroundEventSubscription?.cancel();
    _backgroundEventSubscription = _backgroundRecordingService.events.listen((
      event,
    ) async {
      if (!mounted) {
        return;
      }
      if (event == BackgroundRecordingEvent.protectionLost) {
        if (context.read<CameraProvider>().isRecording) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(_backgroundProtectionUnavailableMessage),
              duration: Duration(seconds: 6),
            ),
          );
        }
        return;
      }
      if (event != BackgroundRecordingEvent.stopRequested) {
        return;
      }

      final camera = context.read<CameraProvider>();
      final telemetry = context.read<TelemetryProvider>();
      final messenger = ScaffoldMessenger.of(context);
      await _stopRecordingFlow(
        camera: camera,
        telemetry: telemetry,
        messenger: messenger,
        showSuccessMessage: false,
      );
    });
  }

  Future<void> _startRecordingFlow({
    required CameraProvider camera,
    required TelemetryProvider telemetry,
    required ScaffoldMessengerState messenger,
  }) async {
    if (_isStartingRecording ||
        _isStoppingRecording ||
        camera.isRecording ||
        camera.isStartingRecording ||
        camera.isStoppingRecording ||
        telemetry.isPersistingRide) {
      return;
    }

    setState(() {
      _isStartingRecording = true;
    });
    // Landscape recording: the orientation pinned now is the ride's.
    _syncOrientationPin();
    try {
      await _runStartRecordingFlow(
        camera: camera,
        telemetry: telemetry,
        messenger: messenger,
      );
    } finally {
      _isStartingRecording = false;
      if (mounted) {
        setState(() {});
      }
      // A refused START resumes the classifier; a started ride keeps it
      // frozen until it stops.
      _syncOrientationPin();
    }
  }

  Future<void> _runStartRecordingFlow({
    required CameraProvider camera,
    required TelemetryProvider telemetry,
    required ScaffoldMessengerState messenger,
  }) async {
    final settings = context.read<AppSettingsProvider>();
    final permissionAudit = await _permissionService.ensureRequiredPermissions(
      audioEnabled: settings.audioEnabled,
      galleryExportEnabled: settings.exportLockedClipsToGallery,
    );
    if (!mounted) {
      return;
    }

    final resolvedAudit = await _handlePermissionAuditResult(
      permissionAudit,
      audioEnabled: settings.audioEnabled,
    );
    if (resolvedAudit.hasBlockingIssues) {
      return;
    }

    final hasLocationServices = await _ensureLocationServiceEnabled(
      messenger: messenger,
    );
    if (!mounted || !hasLocationServices) {
      return;
    }

    if (_hasPendingCameraSettings && !camera.isRecording) {
      // Settings saved during the previous recording. If they cannot be
      // applied the camera is left uninitialized and the preflight's
      // Camera Ready check reports it.
      _hasPendingCameraSettings = false;
      await _applySavedCameraSettings(camera: camera, settings: settings);
      if (!mounted) {
        return;
      }
    }

    final preflightApproved = await _showStartPreflightChecklist(
      camera: camera,
      settings: settings,
    );
    if (!mounted || !preflightApproved) {
      return;
    }

    await telemetry.initialize();
    if (!mounted) {
      return;
    }

    // Gallery export of locked clips is opt-in (off by default).
    camera.autoExportLockedClipsToGallery = settings.exportLockedClipsToGallery;
    // Off by default; the budget never deletes the ride being recorded.
    camera.storageBudgetBytes = settings.recordingsStorageBudgetBytes;
    camera.currentRideSessionIdSource = () => telemetry.rideSessionId;
    // A ride export waits while the ride file is still being written.
    camera.isPersistingRideSource = () => telemetry.isPersistingRide;
    final rideOrientation = _orientationPinner.pinned;
    if (widget.landscapeRecording) {
      await PipService.setAspectRatio(
        landscape: isLandscapeOrientation(rideOrientation),
      );
      if (!mounted) {
        return;
      }
    }
    final started = await camera.startRecording(
      captureOrientation: rideOrientation,
    );
    var backgroundProtected = true;
    if (started && camera.isRecording) {
      if (!mounted) {
        return;
      }
      _handledRecordingError = null;
      // The previous ride's export summary stays in the provider; mark it as
      // shown so it is not repeated during this ride.
      _shownGalleryExportMessage = camera.lastGalleryExportMessage;
      _checkpointTracker.reset();

      // One zero point for the video segment timeline and the telemetry
      // samples.
      telemetry.startRideSession(startedAt: camera.recordingStartedAt);
      try {
        backgroundProtected = await _backgroundRecordingService
            .startForegroundRecording(elapsed: Duration.zero);
      } catch (e) {
        backgroundProtected = false;
        debugPrint('Starting the foreground recording service failed: $e');
      }
      if (!mounted) {
        // dispose() already asked to stop the service, possibly before the
        // start above reached the native side; stop again so neither the
        // service nor the camera lifecycle hold outlives this screen.
        await _stopForegroundServiceSafely();
        return;
      }
      // Applied whatever the service result: keeping the screen on is the
      // fallback when screen-off capture is unavailable. The native side
      // clears it at stopForegroundRecording.
      await _backgroundRecordingService.setKeepScreenOn(
        enabled: settings.keepScreenOnWhileRecording,
      );
      await _recordingTimerSubscription?.cancel();
      _recordingTimerSubscription = camera.timerStream.listen((elapsed) {
        unawaited(
          _backgroundRecordingService
              .updateForegroundRecording(elapsed: elapsed)
              .catchError((Object e) {
                debugPrint('Updating the recording notification failed: $e');
              }),
        );
        // Segment registration does not notify listeners, so new segments
        // and locks are picked up here, about once per second.
        _checkpointRideIfChanged(camera);
        // Also runs in the background, under the service's wake lock.
        if (_captureMonitor.isObserving) {
          unawaited(_captureMonitor.sample(DateTime.now()));
        }
      });
    }

    if (!mounted) {
      return;
    }

    if (!started) {
      final reason = camera.lastRecordingError;
      if (reason != null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Recording did not start: $reason'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
      _showInAppNotice(
        reason != null ? 'Start refused' : 'Start failed. Try lower quality.',
      );
      return;
    }

    _showInAppNotice('REC started');
    if (!backgroundProtected) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(_backgroundProtectionUnavailableMessage),
          duration: Duration(seconds: 6),
        ),
      );
    }
  }

  /// The recording settings stored with the ride: what the rider requested
  /// and what the camera applied.
  Map<String, dynamic> _recordingSettingsSnapshot({
    required CameraProvider camera,
    required AppSettingsProvider settings,
  }) {
    return <String, dynamic>{
      'requestedResolution': settings.recordingResolution,
      'requestedFps': settings.recordingFps,
      'requestedBitrateMbps': settings.videoBitrateMbps,
      'requestedSegmentDurationSeconds': settings.segmentDurationSeconds,
      'requestedLoopSegmentCount': settings.loopSegmentCount,
      'requestedAudioEnabled': settings.audioEnabled,
      'requestedCameraName': settings.selectedCameraName,
      'requestedIncidentSensitivity': settings.incidentSensitivity.name,
      'requestedSpeedRefreshMs': settings.speedRefreshMs,
      'appliedResolution': CameraProvider.resolutionForPreset(
        camera.resolutionPreset,
      ),
      'appliedFps': camera.recordingFps,
      // The encoder's target; null in rides recorded on Android before the
      // camera plugin applied the bitrate there (MOTOCAM_PATCHES.md patch 4).
      'appliedBitrateMbps': camera.appliedVideoBitrateMbps,
      'appliedAudioEnabled': camera.audioEnabled,
      'appliedSegmentDurationSeconds': camera.segmentDurationSeconds,
      'appliedLoopSegmentCount': camera.maxRollingSegments,
      'appliedCameraName': camera.activeCameraName,
      // Landscape recording only (missing means portraitUp): the capture
      // orientation the ride was locked to at START.
      if (widget.landscapeRecording)
        'appliedCaptureOrientation': camera.rideCaptureOrientation.name,
    };
  }

  /// Writes a ride checkpoint when the session gained a segment or a lock
  /// since the last one, so a crash or kill mid-ride keeps the ride JSON.
  void _checkpointRideIfChanged(CameraProvider camera) {
    if (!mounted || !camera.isRecording || camera.isStoppingRecording) {
      return;
    }
    final segmentPaths = camera.lastSessionSegmentPaths;
    if (!_checkpointTracker.shouldCheckpoint(
      segmentPaths,
      camera.lockedSegmentCount,
    )) {
      return;
    }
    final telemetry = context.read<TelemetryProvider>();
    unawaited(
      telemetry.checkpointRideSession(
        segmentPaths: segmentPaths,
        lockedSegmentPaths: camera.lockedSegmentPaths,
        segmentTimeline: camera.lastSessionSegmentTimeline,
        recordingSettings: _recordingSettingsSnapshot(
          camera: camera,
          settings: context.read<AppSettingsProvider>(),
        ),
      ),
    );
  }

  void _showInAppNotice(
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    if (!mounted) {
      return;
    }

    _inAppNoticeTimer?.cancel();
    setState(() {
      _inAppNoticeText = message;
    });
    _inAppNoticeTimer = Timer(duration, () {
      if (!mounted) {
        return;
      }
      setState(() {
        _inAppNoticeText = null;
      });
    });
  }

  // Blackout is a Flutter-only black overlay. It must never pause or resume
  // the camera preview: the plugin implements that by unbinding and binding
  // CameraX's Preview use case, which cost about 1.2 s of video at each
  // toggle, and with only VideoCapture bound the camera closed and reopened
  // at every segment roll (ride on the phone, 2026-11-13). The preview
  // widget is not built under the overlay, but the use case stays bound.
  Future<void> _enterBlackoutMode({required CameraProvider camera}) async {
    if (_isBlackoutMode || !camera.isRecording || !mounted) {
      return;
    }

    setState(() {
      _isBlackoutMode = true;
    });
    _showInAppNotice('Blackout on. Hold 2s anywhere to exit.');
  }

  Future<void> _exitBlackoutMode({required CameraProvider camera}) async {
    if (!_isBlackoutMode || !mounted) {
      return;
    }

    _blackoutExitHoldTimer?.cancel();
    _blackoutExitTriggered = false;
    setState(() {
      _isBlackoutMode = false;
    });
    _showInAppNotice('Blackout off');
  }

  void _startBlackoutExitHold({required CameraProvider camera}) {
    _blackoutExitHoldTimer?.cancel();
    _blackoutExitTriggered = false;
    _blackoutExitHoldTimer = Timer(const Duration(seconds: 2), () {
      _blackoutExitTriggered = true;
      unawaited(HapticFeedback.mediumImpact());
      unawaited(_exitBlackoutMode(camera: camera));
    });
  }

  void _endBlackoutExitHold() {
    // Blackout already ended (the hold or another exit): the overlay's
    // gesture is cancelled as it unmounts, which must not show a stale
    // "Hold for 2 seconds" notice after "Blackout off".
    if (!_isBlackoutMode || !mounted) {
      _blackoutExitHoldTimer?.cancel();
      _blackoutExitTriggered = false;
      return;
    }
    if (_blackoutExitTriggered) {
      _blackoutExitTriggered = false;
      return;
    }

    _blackoutExitHoldTimer?.cancel();
    _showInAppNotice('Hold for 2 seconds to exit blackout');
  }

  Future<bool> _showStartPreflightChecklist({
    required CameraProvider camera,
    required AppSettingsProvider settings,
  }) async {
    final checks = await _buildStartPreflightChecks(
      camera: camera,
      settings: settings,
    );

    if (!mounted) {
      return false;
    }

    if (!startPreflightNeedsSheet(checks)) {
      return true;
    }

    // The page completes true only when START was tapped while its current
    // checks (rechecked after each fix) have no blocking failure.
    return showStartPreflightPage(
      context,
      checks: checks,
      onFix: _runStartPreflightFix,
      onRecheck: () =>
          _buildStartPreflightChecks(camera: camera, settings: settings),
    );
  }

  /// Runs a checklist Fix and completes when the rider is back in the app.
  /// The battery exemption is requested only on the rider's tap.
  /// [StartPreflightFix.retryCamera] needs no action here: the recheck
  /// initializes the camera again when it is not ready.
  Future<void> _runStartPreflightFix(StartPreflightFix fix) async {
    switch (fix) {
      case StartPreflightFix.appSettings:
        await _openSystemSettingsAndWaitForReturn(openAppSettings);
      case StartPreflightFix.locationServices:
        await _openSystemSettingsAndWaitForReturn(
          Geolocator.openLocationSettings,
        );
      case StartPreflightFix.batteryExemption:
        await _openSystemSettingsAndWaitForReturn(
          _backgroundRecordingService.requestIgnoreBatteryOptimizations,
        );
      case StartPreflightFix.retryCamera:
        break;
    }
  }

  Future<List<StartPreflightCheck>> _buildStartPreflightChecks({
    required CameraProvider camera,
    required AppSettingsProvider settings,
  }) async {
    if (!camera.isInitialized && !camera.isRecording) {
      await _initializeCamera();
    }

    final cameraGranted = AppPermissionService.isPermissionGranted(
      await Permission.camera.status,
    );
    final micGranted =
        settings.audioEnabled &&
        AppPermissionService.isPermissionGranted(
          await Permission.microphone.status,
        );
    final locationGranted = AppPermissionService.isPermissionGranted(
      await Permission.locationWhenInUse.status,
    );
    final locationEnabled = await Geolocator.isLocationServiceEnabled();
    final cameraReady =
        camera.isInitialized &&
        camera.controller != null &&
        camera.controller!.value.isInitialized;
    final canWriteMedia = await _verifyRecordingDirectoryWritable(camera);

    final isAndroid = Platform.isAndroid;
    var notificationsGranted = false;
    var ignoresBatteryOptimization = false;
    var batteryOfferShown = false;
    if (isAndroid) {
      notificationsGranted = AppPermissionService.isPermissionGranted(
        await Permission.notification.status,
      );
      ignoresBatteryOptimization = await _backgroundRecordingService
          .isIgnoringBatteryOptimizations();
      batteryOfferShown =
          !ignoresBatteryOptimization &&
          await _backgroundRecordingService
              .hasOfferedBatteryOptimizationExemption();
    }

    return StartPreflightEvaluator.evaluate(
      StartPreflightInputs(
        cameraPermissionGranted: cameraGranted,
        audioEnabled: settings.audioEnabled,
        microphonePermissionGranted: micGranted,
        locationPermissionGranted: locationGranted,
        locationServicesEnabled: locationEnabled,
        cameraReady: cameraReady,
        recordingStorageWritable: canWriteMedia,
        isAndroid: isAndroid,
        notificationsGranted: notificationsGranted,
        ignoresBatteryOptimization: ignoresBatteryOptimization,
        batteryExemptionOffered: batteryOfferShown,
        incidentDetectionAvailable:
            !mounted ||
            context.read<TelemetryProvider>().isIncidentDetectionAvailable,
        batteryLevelPercent: _deviceStatus.value.batteryLevelPercent,
        batteryTemperatureC: _deviceStatus.value.batteryTemperatureC,
      ),
    );
  }

  Future<bool> _verifyRecordingDirectoryWritable(CameraProvider camera) async {
    final path = camera.recordingsDirectory;
    if (path == null || path.isEmpty) {
      return false;
    }

    final directory = Directory(path);
    if (!await directory.exists()) {
      try {
        await directory.create(recursive: true);
      } catch (_) {
        return false;
      }
    }

    final probeFile = File(
      '${directory.path}${Platform.pathSeparator}.__motocam_write_probe.tmp',
    );
    try {
      await probeFile.writeAsString('ok', flush: true);
      if (await probeFile.exists()) {
        await probeFile.delete();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _ensureLocationServiceEnabled({
    required ScaffoldMessengerState messenger,
  }) async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (enabled) {
      return true;
    }

    if (!mounted) {
      return false;
    }

    final shouldOpenSettings =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: const Text('Turn On Location Services'),
              content: const Text(
                'Location services are currently off. Turn them on to start recording ride telemetry.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Open Location Settings'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!shouldOpenSettings) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Location services must be enabled before recording starts.',
          ),
          duration: Duration(seconds: 3),
        ),
      );
      return false;
    }

    await _openSystemSettingsAndWaitForReturn(Geolocator.openLocationSettings);
    if (!mounted) {
      return false;
    }

    final enabledAfterPrompt = await Geolocator.isLocationServiceEnabled();
    if (enabledAfterPrompt) {
      return true;
    }

    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Location is still off. Enable it in system settings, then press START RECORDING again.',
        ),
        duration: Duration(seconds: 4),
      ),
    );
    return false;
  }

  /// Stops the recording, saves the ride and reports what was saved.
  Future<_StopOutcome> _stopRecordingFlow({
    required CameraProvider camera,
    required TelemetryProvider telemetry,
    required ScaffoldMessengerState messenger,
    bool showSuccessMessage = true,
  }) async {
    if (_isStoppingRecording) {
      return _StopOutcome.skipped;
    }

    if (!camera.isRecording) {
      // Nothing to save, e.g. a notification Stop that arrives after the
      // ride was already stopped; only make sure the service is gone.
      await _stopForegroundServiceSafely();
      return _StopOutcome.skipped;
    }

    // Taken before stopping (and before the stopping flag is set) so the
    // fallback save below keeps it as well.
    final recordingSettings = _recordingSettingsSnapshot(
      camera: camera,
      settings: context.read<AppSettingsProvider>(),
    );
    setState(() {
      _isStoppingRecording = true;
    });
    _syncOrientationPin();
    String? telemetryPath;
    var persistAttempted = false;
    Object? stopError;
    try {
      await _recordingTimerSubscription?.cancel();
      _recordingTimerSubscription = null;

      // The foreground service (and its wake lock) stays up until the ride
      // is saved; it is stopped in the finally block below. The camera
      // lifecycle hold ends as soon as capture has stopped, so the camera
      // does not stay open during the save with the screen off.
      final String? videoPath;
      try {
        videoPath = await camera.stopRecording();
      } finally {
        await _backgroundRecordingService.releaseCameraHold();
      }
      final sessionSegmentPaths = camera.lastSessionSegmentPaths;
      final resolvedVideoPath =
          videoPath ??
          (sessionSegmentPaths.isNotEmpty ? sessionSegmentPaths.last : null);

      if (resolvedVideoPath != null) {
        persistAttempted = true;
        telemetryPath = await telemetry.stopRideSessionAndPersist(
          resolvedVideoPath,
          segmentPaths: sessionSegmentPaths,
          lockedSegmentPaths: camera.lockedSegmentPaths,
          segmentTimeline: camera.lastSessionSegmentTimeline,
          recordingSettings: recordingSettings,
        );
      } else {
        telemetry.cancelRideSession();
      }
    } catch (e) {
      stopError = e;
      debugPrint('Stopping the recording failed: $e');
      // Do not leave the telemetry ride active (the next START would
      // discard it): save it with whatever segments were registered.
      if (telemetry.isRideActive) {
        final segments = camera.lastSessionSegmentPaths;
        if (segments.isNotEmpty) {
          persistAttempted = true;
          try {
            telemetryPath = await telemetry.stopRideSessionAndPersist(
              segments.last,
              segmentPaths: segments,
              lockedSegmentPaths: camera.lockedSegmentPaths,
              segmentTimeline: camera.lastSessionSegmentTimeline,
              recordingSettings: recordingSettings,
            );
          } catch (persistError) {
            debugPrint(
              'Saving the ride after a stop failure failed: '
              '$persistError',
            );
          }
        } else {
          telemetry.cancelRideSession();
        }
      }
    } finally {
      await _stopForegroundServiceSafely();
      // Always leave blackout, also after an error or a notification Stop.
      if (_isBlackoutMode && mounted) {
        await _exitBlackoutMode(camera: camera);
      }
      _isStoppingRecording = false;
      if (mounted) {
        setState(() {});
      }
      if (widget.landscapeRecording) {
        unawaited(PipService.setAspectRatio(landscape: false));
      }
      _syncOrientationPin();
    }

    final saveFailed =
        persistAttempted &&
        telemetryPath == null &&
        telemetry.lastPersistError != null;
    final _StopOutcome outcome;
    if (telemetryPath != null) {
      outcome = _StopOutcome.saved;
    } else if (saveFailed) {
      outcome = _StopOutcome.saveFailed;
    } else if (stopError != null) {
      outcome = _StopOutcome.stopFailed;
    } else if (persistAttempted) {
      outcome = _StopOutcome.videoOnly;
    } else {
      outcome = _StopOutcome.nothingSaved;
    }

    if (!mounted) {
      return outcome;
    }

    if (stopError != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Stopping the recording failed: $stopError'),
          duration: const Duration(seconds: 6),
        ),
      );
      return outcome;
    }

    if (saveFailed) {
      _showTelemetrySaveFailure(telemetry: telemetry, messenger: messenger);
      return outcome;
    }

    if (!showSuccessMessage || !persistAttempted) {
      return outcome;
    }
    _showInAppNotice(
      telemetryPath == null ? 'Recording saved' : 'Recording + telemetry saved',
    );
    if (telemetryPath != null) {
      unawaited(_maybeOfferBatteryOptimizationExemption());
    }
    return outcome;
  }

  /// Tells the rider the ride JSON could not be saved and offers a retry.
  /// The video segments are already on disk; the provider keeps the ride in
  /// memory for [TelemetryProvider.retryPendingPersist].
  void _showTelemetrySaveFailure({
    required TelemetryProvider telemetry,
    required ScaffoldMessengerState messenger,
  }) {
    messenger.showSnackBar(
      SnackBar(
        content: const Text(
          'Telemetry could not be saved. The video was kept.',
        ),
        duration: const Duration(seconds: 20),
        action: SnackBarAction(
          label: 'Retry',
          onPressed: () {
            unawaited(() async {
              final path = await telemetry.retryPendingPersist();
              if (path != null) {
                messenger.showSnackBar(
                  const SnackBar(content: Text('Telemetry saved')),
                );
              } else if (telemetry.lastPersistError != null) {
                _showTelemetrySaveFailure(
                  telemetry: telemetry,
                  messenger: messenger,
                );
              }
            }());
          },
        ),
      ),
    );
  }

  /// Offers the battery-optimization exemption at most once ever, after a
  /// saved ride, behind a dialog the rider can decline.
  Future<void> _maybeOfferBatteryOptimizationExemption() async {
    if (_isOfferingBatteryExemption) {
      return;
    }
    _isOfferingBatteryExemption = true;
    try {
      final shouldOffer = await _backgroundRecordingService
          .shouldOfferBatteryOptimizationExemption();
      if (!shouldOffer || !mounted) {
        return;
      }
      await _backgroundRecordingService
          .markBatteryOptimizationExemptionOffered();
      if (!mounted) {
        return;
      }
      final accepted =
          await showDialog<bool>(
            context: context,
            builder: (dialogContext) {
              return AlertDialog(
                title: const Text('Keep recording with the screen off?'),
                content: const Text(
                  'Android battery optimization can stop MotoCam while the '
                  'screen is off or the app is in the background. You can '
                  'exempt MotoCam so long rides keep recording. This uses '
                  'more battery, and you can change it later in system '
                  'settings. MotoCam asks only once.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    child: const Text('Not now'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    child: const Text('Open setting'),
                  ),
                ],
              );
            },
          ) ??
          false;
      if (!accepted || !mounted) {
        return;
      }
      await _backgroundRecordingService.requestIgnoreBatteryOptimizations();
    } catch (e) {
      debugPrint('Battery optimization offer failed: $e');
    } finally {
      _isOfferingBatteryExemption = false;
    }
  }

  Future<void> _stopForegroundServiceSafely() async {
    try {
      await _backgroundRecordingService.stopForegroundRecording();
    } catch (e) {
      debugPrint('Stopping the foreground recording service failed: $e');
    }
  }

  void _handleIncidentAutoLock({
    required CameraProvider camera,
    required TelemetryProvider telemetry,
  }) {
    final detectedAt = telemetry.lastIncidentDetectedAt;
    if (!shouldAutoLockIncident(
      isRecording: camera.isRecording,
      detectedAt: detectedAt,
      lastHandledAt: _lastHandledIncidentAt,
      recordingStartedAt: camera.recordingStartedAt,
    )) {
      return;
    }

    _lastHandledIncidentAt = detectedAt;
    // Lock immediately: frames (and post-frame callbacks) stop while the app
    // is hidden or paused, but recording and incident detection continue.
    final registeredSegments = camera.lastSessionSegmentPaths.length;
    // Confirmation can come after a roll; keep the segments around the jolt.
    final protectPastSegments = autoIncidentProtectPastSegments(
      timeline: camera.lastSessionSegmentTimeline,
      joltElapsedMs: telemetry.lastIncidentJoltElapsedMs,
    );
    camera.markIncident(
      protectPastSegments: protectPastSegments,
      protectCurrentSegment: true,
      reason: 'auto-crash',
    );
    _checkpointRideIfChanged(camera);

    // Only the feedback waits for the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(HapticFeedback.heavyImpact());
      _showInAppNotice(
        incidentLockNotice(
          registeredSegments: registeredSegments,
          protectPastSegments: protectPastSegments,
          automatic: true,
        ),
      );
    });
  }

  Future<void> _initializeCamera() async {
    final settingsProvider = context.read<AppSettingsProvider>();
    final cameraProvider = context.read<CameraProvider>();
    final telemetryProvider = context.read<TelemetryProvider>();

    if (!settingsProvider.isLoaded) {
      await settingsProvider.load();
    }

    // Initialization applies every saved camera setting.
    _hasPendingCameraSettings = false;
    await cameraProvider.initializeCamera(
      resolutionPreset: cameraProvider.resolvePresetForRequestedResolution(
        settingsProvider.recordingResolution,
      ),
      recordingFps: settingsProvider.recordingFps,
      videoBitrateBps: settingsProvider.videoBitrateMbps * 1000 * 1000,
      audioEnabled: settingsProvider.audioEnabled,
      preferredCameraName: settingsProvider.selectedCameraName,
      segmentDurationSeconds: settingsProvider.segmentDurationSeconds,
      maxRollingSegments: settingsProvider.loopSegmentCount,
    );

    if (mounted) {
      setState(() {
        _cameraInitAttempted = true;
      });
    }

    telemetryProvider.setSpeedUiRefreshInterval(
      Duration(milliseconds: settingsProvider.speedRefreshMs),
    );
    telemetryProvider.setIncidentDetectionConfig(
      triggerGForce: settingsProvider.incidentTriggerGForce,
      debounce: settingsProvider.incidentDebounce,
    );

    if (!mounted) {
      return;
    }

    await telemetryProvider.initialize();
  }

  // Re-initializes the camera with the saved settings. The rider's saved
  // resolution and FPS are never overwritten with what the device
  // negotiated; the profile bar shows the applied values when they differ.
  Future<bool> _applySavedCameraSettings({
    required CameraProvider camera,
    required AppSettingsProvider settings,
  }) {
    return camera.applyRecordingSettings(
      resolutionPreset: camera.resolvePresetForRequestedResolution(
        settings.recordingResolution,
      ),
      recordingFps: settings.recordingFps,
      videoBitrateBps: settings.videoBitrateMbps * 1000 * 1000,
      audioEnabled: settings.audioEnabled,
      preferredCameraName: settings.selectedCameraName,
      segmentDurationSeconds: settings.segmentDurationSeconds,
      maxRollingSegments: settings.loopSegmentCount,
    );
  }

  Future<void> _handleBackPressWhileRecording() async {
    final enteredPip = await PipService.enterPipMode();
    if (!mounted || enteredPip) {
      return;
    }

    _showInAppNotice('Recording active. Stop first to exit.');
  }

  Future<void> _openRideHistory({required CameraProvider camera}) async {
    if (_isNavigatingHistory || camera.isRecording) {
      return;
    }

    _isNavigatingHistory = true;
    try {
      // With the landscape switch on, Ride History and playback follow the
      // orientation classifier (see _syncOrientationPin); a pin while the
      // camera is released is taken by the initialization on return.
      await camera.releaseCameraIfIdle();
      if (!mounted) {
        return;
      }
      // GPS and sensors are not needed while history is open; the
      // _initializeCamera call on return resumes tracking.
      context.read<TelemetryProvider>().pauseTracking();

      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const RidesListScreen()));

      if (!mounted || camera.isRecording) {
        return;
      }

      await _initializeCamera();
    } finally {
      _isNavigatingHistory = false;
      // The preview hides the camera-unavailable state while history is
      // open; rebuild so a failed re-initialization shows Retry.
      if (mounted) {
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<CameraProvider>(
      builder: (context, camera, _) {
        return PopScope(
          canPop: !camera.isRecording,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop || !camera.isRecording) {
              return;
            }
            unawaited(_handleBackPressWhileRecording());
          },
          child: _isInPipMode
              ? _buildPipRecordingView()
              : Scaffold(
                  backgroundColor: MotoColors.bg,
                  body: SafeArea(
                    child: Stack(
                      children: [
                        Consumer<AppSettingsProvider>(
                          builder: (context, settings, _) =>
                              Selector<TelemetryProvider, _TelemetryFlags>(
                                selector: (_, telemetry) => (
                                  incidentUnavailable:
                                      !telemetry.isIncidentDetectionAvailable,
                                  locationOff:
                                      telemetry.isTracking &&
                                      !telemetry.isLocationServiceEnabled,
                                  persistingRide: telemetry.isPersistingRide,
                                ),
                                builder: (context, flags, _) => _buildBody(
                                  camera: camera,
                                  view: _viewState(
                                    camera: camera,
                                    settings: settings,
                                    flags: flags,
                                  ),
                                ),
                              ),
                        ),
                        if (_isBlackoutMode)
                          _buildBlackoutOverlay(camera: camera),
                        // Drawn last so notices stay visible in blackout.
                        _buildInAppNoticeOverlay(),
                      ],
                    ),
                  ),
                ),
        );
      },
    );
  }

  /// One snapshot of what the widgets show, from the providers and the
  /// State's flags.
  RecordingViewState _viewState({
    required CameraProvider camera,
    required AppSettingsProvider settings,
    required _TelemetryFlags flags,
  }) {
    return RecordingViewState(
      isRecording: camera.isRecording,
      isBlackoutMode: _isBlackoutMode,
      isApplyingSettings: _isApplyingSettings,
      isStarting: _isStartingRecording || camera.isStartingRecording,
      isStopping: _isStoppingRecording || camera.isStoppingRecording,
      isPersistingRide: flags.persistingRide,
      isPreparingCamera: !camera.isRecording && camera.isInitializing,
      isSegmentLocked: camera.isRecordingSegmentLocked,
      cameraName: settings.selectedCameraName,
      requestedResolution: settings.recordingResolution,
      requestedFps: settings.recordingFps,
      appliedResolution: CameraProvider.resolutionForPreset(
        camera.resolutionPreset,
      ),
      appliedFps: camera.recordingFps,
      // Saved values are the rider's request; when the camera negotiated
      // something else, the applied value is shown next to the request.
      showApplied: camera.isInitialized && !_hasPendingCameraSettings,
      requestedBitrateMbps: settings.videoBitrateMbps,
      appliedBitrateMbps: camera.appliedVideoBitrateMbps,
      audioEnabled: settings.audioEnabled,
      segmentLabel: AppSettingsProvider.segmentDurationLabel(
        settings.segmentDurationSeconds,
      ),
      loopSegmentCount: settings.loopSegmentCount,
      incidentSensitivityName: settings.incidentSensitivity.name,
      speedRefreshMs: settings.speedRefreshMs,
      incidentDetectionUnavailable: flags.incidentUnavailable,
      locationOff: flags.locationOff,
      highIncidentSensitivity:
          settings.incidentSensitivity == IncidentSensitivity.high,
      presetWarning: _presetWarning(camera: camera, settings: settings),
      settingsPending: _hasPendingCameraSettings,
    );
  }

  /// Warning about a saved resolution known to fail on this camera, or null.
  String? _presetWarning({
    required CameraProvider camera,
    required AppSettingsProvider settings,
  }) {
    final selectedPreset = CameraProvider.presetForResolution(
      settings.recordingResolution,
    );
    final resolvedPreset = camera.resolvePresetForRequestedResolution(
      settings.recordingResolution,
    );
    final unsupportedPresets = camera.knownUnsupportedResolutionPresets;
    final isPresetUnsupported =
        !camera.isRecording && unsupportedPresets.contains(selectedPreset);
    if (!isPresetUnsupported) {
      return null;
    }
    final willAutoFallback = resolvedPreset != selectedPreset;
    final supportedResolutions = AppSettingsProvider.resolutionOptions
        .where(
          (resolution) => !unsupportedPresets.contains(
            CameraProvider.presetForResolution(resolution),
          ),
        )
        .toList();
    final suggestedResolution = supportedResolutions.isEmpty
        ? null
        : supportedResolutions.last;
    if (willAutoFallback) {
      return 'Current ${settings.recordingResolution}p is unstable on this device. Recording will auto-fallback to ${CameraProvider.resolutionForPreset(resolvedPreset)}p.';
    }
    return suggestedResolution == null
        ? 'Current ${settings.recordingResolution}p is known unstable on this device. Choose a lower resolution in Settings.'
        : 'Current ${settings.recordingResolution}p is known unstable on this device. Choose ${suggestedResolution}p or lower in Settings.';
  }

  void _onStartPressed(CameraProvider camera) {
    unawaited(
      _startRecordingFlow(
        camera: camera,
        telemetry: context.read<TelemetryProvider>(),
        messenger: ScaffoldMessenger.of(context),
      ),
    );
  }

  void _onStopPressed(CameraProvider camera) {
    unawaited(
      _stopRecordingFlow(
        camera: camera,
        telemetry: context.read<TelemetryProvider>(),
        messenger: ScaffoldMessenger.of(context),
      ),
    );
  }

  void _onBlackoutPressed(CameraProvider camera) {
    if (_isBlackoutMode) {
      unawaited(_exitBlackoutMode(camera: camera));
    } else {
      unawaited(_enterBlackoutMode(camera: camera));
    }
  }

  void _onLockPressed(CameraProvider camera) {
    final registeredSegments = camera.lastSessionSegmentPaths.length;
    camera.markIncident(
      protectPastSegments: 2,
      protectCurrentSegment: true,
      reason: 'manual-emergency',
    );
    _checkpointRideIfChanged(camera);
    unawaited(HapticFeedback.heavyImpact());
    _showInAppNotice(
      incidentLockNotice(registeredSegments: registeredSegments),
    );
  }

  Widget _buildBody({
    required CameraProvider camera,
    required RecordingViewState view,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The landscape layout needs the switch on, the UI pinned to
        // landscape and a window that has turned (wider than tall), so the
        // frame before the platform rotates keeps the portrait layout.
        final landscape =
            _pinnedToLandscape && constraints.maxWidth > constraints.maxHeight;
        final preview = _buildPreview(camera: camera);
        return landscape
            ? _buildLandscapeLayout(
                camera: camera,
                view: view,
                preview: preview,
                constraints: constraints,
              )
            : _buildPortraitLayout(
                camera: camera,
                view: view,
                preview: preview,
                constraints: constraints,
              );
      },
    );
  }

  /// The camera preview: the full Ready preview, or the small live
  /// thumbnail while recording. Its aspect ratio follows the capture
  /// orientation (see [_captureIsLandscape]), never the layout.
  Widget _buildPreview({required CameraProvider camera}) {
    final controller = camera.isInitialized ? camera.controller : null;
    return RecordingPreview(
      isBlackoutMode: _isBlackoutMode,
      controller: controller,
      mode: cameraPreviewMode(
        cameraReady: false,
        initState: camera.initState,
        initAttempted: _cameraInitAttempted,
        setupBusy:
            _isBootstrapping ||
            _isNavigatingHistory ||
            camera.isInitializing ||
            camera.isRecording,
      ),
      initFailure: camera.initFailure,
      previewKey: ValueKey(
        'camera-preview-${camera.resolutionPreset}-${camera.recordingFps}-${camera.activeCameraName}-${controller.hashCode}',
      ),
      thumbnail: camera.isRecording,
      landscape: _captureIsLandscape(camera),
      onRetry: _retryCameraSetup,
      onOpenSettings: () => unawaited(_openAppSettingsAndRetry()),
    );
  }

  Widget _buildPortraitLayout({
    required CameraProvider camera,
    required RecordingViewState view,
    required Widget preview,
    required BoxConstraints constraints,
  }) {
    final panel = RecordingDetailsPanel(
      view: view,
      deviceStatus: _deviceStatus,
      freeStorageBytes: _freeStorageBytes,
      onSettings: () => unawaited(_openSettingsSheet()),
      onPop: () => unawaited(_handleBackPressWhileRecording()),
    );
    // One Stack slot for the preview in every state: the full Ready preview,
    // or the small live thumbnail while recording. The slot keeps its
    // element across START, STOP and parking, so the preview subtree is
    // never rebuilt from scratch. While recording the speed fills the rest;
    // parked, a smaller speed sits beside the thumbnail and the details
    // panel takes the space under it.
    Widget middle({required bool parkedPanel}) => Stack(
      fit: StackFit.expand,
      children: [
        if (camera.isRecording)
          Positioned(
            top: 0,
            right: 0,
            width: _thumbnailWidth,
            height: _thumbnailHeight,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: MotoColors.hairlineStrong),
              ),
              child: preview,
            ),
          )
        else
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            left: 0,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: const BoxDecoration(),
              child: preview,
            ),
          ),
        if (camera.isRecording && !parkedPanel)
          const Positioned(
            left: 0,
            right: 0,
            top: _thumbnailHeight + MotoSize.gap,
            bottom: 0,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: RecordingSpeed(),
            ),
          ),
        if (camera.isRecording && parkedPanel) ...[
          const Positioned(
            left: 0,
            top: 0,
            right: _thumbnailWidth + MotoSize.gap,
            height: _thumbnailHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: RecordingSpeed(size: _thumbnailHeight),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: _thumbnailHeight + MotoSize.gapWide,
            bottom: 0,
            child: SingleChildScrollView(child: panel),
          ),
        ],
      ],
    );
    final header = RecordingHeader(
      view: view,
      timerStream: camera.timerStream,
      elapsed: camera.elapsedTime,
    );
    final chips = RecordingProfileBar(
      view: view,
      deviceStatus: _deviceStatus,
      freeStorageBytes: _freeStorageBytes,
      onBlackout: () => _onBlackoutPressed(camera),
    );
    // Rides moving into private storage (idle only: a run pauses while
    // recording).
    final banner = camera.isRecording
        ? null
        : RecordingsMigrationBanner(migration: camera.recordingsMigration);

    // The portrait layout needs about 640 dp of height. A shorter window
    // (split screen, or a landscape window without the landscape layout)
    // gets smaller thumb controls and scrolls.
    final compact = constraints.maxHeight < _minPortraitHeight;
    // Below the boards' 844 dp, START and LOCK give up height first, so the
    // speed keeps its room on a shorter phone.
    final bigTargetCut = compact
        ? 0.0
        : (_boardHeight - constraints.maxHeight).clamp(
            0.0,
            RecordingControls.maxBigTargetCut,
          );
    final controls = RecordingControls(
      view: view,
      compact: compact,
      bigTargetCut: bigTargetCut,
      onStart: () => _onStartPressed(camera),
      onStop: () => _onStopPressed(camera),
      onRides: () => unawaited(_openRideHistory(camera: camera)),
      onSettings: () => unawaited(_openSettingsSheet()),
      onLock: () => _onLockPressed(camera),
    );
    if (compact) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(MotoSize.gutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            const SizedBox(height: MotoSize.gapWide),
            chips,
            ?banner,
            const SizedBox(height: MotoSize.gapWide),
            _ParkedGate(
              isRecording: camera.isRecording,
              builder: (showPanel) => showPanel
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: MotoSize.gapWide),
                      child: panel,
                    )
                  : const SizedBox.shrink(),
            ),
            SizedBox(
              height: _compactMiddleHeight,
              child: middle(parkedPanel: false),
            ),
            const SizedBox(height: MotoSize.gapWide),
            controls,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(MotoSize.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: MotoSize.gapWide),
          chips,
          ?banner,
          const SizedBox(height: MotoSize.gapWide),
          Expanded(
            key: const ValueKey('recording-middle'),
            child: _ParkedGate(
              isRecording: camera.isRecording,
              builder: (showPanel) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Idle, the panel sits above the Ready preview.
                  if (showPanel && !camera.isRecording) ...[
                    Flexible(child: SingleChildScrollView(child: panel)),
                    const SizedBox(height: MotoSize.gapWide),
                  ],
                  Expanded(
                    key: const ValueKey('recording-preview-slot'),
                    child: middle(parkedPanel: showPanel && camera.isRecording),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: MotoSize.gapWide),
          controls,
        ],
      ),
    );
  }

  /// Landscape recording: whether the camera captures in landscape, so the
  /// preview and the live thumbnail take the landscape aspect ratio. During
  /// a ride that is the ride's capture orientation (taken at START);
  /// otherwise the orientation the UI is pinned to, which the idle camera
  /// locks its capture to. With the switch off both are portraitUp, so the
  /// portrait preview is unchanged.
  bool _captureIsLandscape(CameraProvider camera) =>
      widget.landscapeRecording &&
      isLandscapeOrientation(
        camera.isRecording
            ? camera.rideCaptureOrientation
            : _orientationPinner.pinned,
      );

  /// Landscape recording: whether the UI is pinned to landscape with the
  /// switch on (the landscape layout then replaces the portrait one once
  /// the window has turned).
  bool get _pinnedToLandscape =>
      widget.landscapeRecording &&
      isLandscapeOrientation(_orientationPinner.pinned);

  /// The landscape recording screen of redesign A (boards
  /// A-Land-Record-Ready and A-Land-Record-Live), shown with the
  /// MOTOCAM_LANDSCAPE switch on while the UI is pinned to landscape.
  ///
  /// A Row: the rail (Rides and Settings, idle only), the middle column
  /// and the thumb column. Idle, the middle holds the chips, the details
  /// panel and the live view filling the rest, and the thumb column the
  /// READY band above START. Recording, there is no rail: the middle holds
  /// the REC band, the chips ending in Blackout and the speed beside the
  /// live thumbnail (the details panel, with Settings and Pop-out, in place
  /// of the speed while parked), and
  /// the thumb column STOP above the big LOCK. The same view state,
  /// handlers and harness labels as the portrait layout; the flagged slots
  /// (orientation chip, write age, stalled, LOCK Undo, lock tone,
  /// hold-to-stop) stay out as there.
  Widget _buildLandscapeLayout({
    required CameraProvider camera,
    required RecordingViewState view,
    required Widget preview,
    required BoxConstraints constraints,
  }) {
    final recording = camera.isRecording;
    final panel = RecordingDetailsPanel(
      view: view,
      deviceStatus: _deviceStatus,
      freeStorageBytes: _freeStorageBytes,
      onSettings: () => unawaited(_openSettingsSheet()),
      onPop: () => unawaited(_handleBackPressWhileRecording()),
    );
    final header = RecordingHeader(
      view: view,
      timerStream: camera.timerStream,
      elapsed: camera.elapsedTime,
      showLockedBand: false,
    );
    final chips = RecordingProfileBar(
      view: view,
      deviceStatus: _deviceStatus,
      freeStorageBytes: _freeStorageBytes,
      onBlackout: () => _onBlackoutPressed(camera),
    );
    final banner = recording
        ? null
        : RecordingsMigrationBanner(migration: camera.recordingsMigration);
    // The boards' 260 dp at 844 dp wide; a narrower phone gives the middle
    // its share first.
    final thumbColumnWidth = (constraints.maxWidth * 0.31).clamp(
      200.0,
      landscapeThumbColumnWidth,
    );

    // One Stack slot for the preview in every state, as in portrait: the
    // full Ready preview, or the live thumbnail at its top right while
    // recording, so START, STOP and parking never rebuild the preview.
    Widget slot({required bool parkedPanel}) => LayoutBuilder(
      builder: (context, slotConstraints) {
        var thumbWidth = (slotConstraints.maxWidth * 0.45).clamp(
          0.0,
          _landscapeThumbnailWidth,
        );
        var thumbHeight =
            thumbWidth * _landscapeThumbnailHeight / _landscapeThumbnailWidth;
        if (thumbHeight > slotConstraints.maxHeight) {
          thumbHeight = slotConstraints.maxHeight;
          thumbWidth =
              thumbHeight *
              _landscapeThumbnailWidth /
              _landscapeThumbnailHeight;
        }
        final besideThumbnail = thumbWidth + MotoSize.gapWide;
        final underThumbnail =
            slotConstraints.maxHeight - thumbHeight - MotoSize.gap;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (recording)
              Positioned(
                top: 0,
                right: 0,
                width: thumbWidth,
                height: thumbHeight,
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: MotoColors.hairlineStrong),
                  ),
                  child: preview,
                ),
              )
            else
              Positioned(
                top: 0,
                right: 0,
                bottom: 0,
                left: 0,
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: const BoxDecoration(),
                  child: preview,
                ),
              ),
            if (recording && !parkedPanel)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                right: besideThumbnail,
                child: const Align(
                  alignment: Alignment.bottomLeft,
                  child: RecordingSpeed(size: _landscapeSpeedSize),
                ),
              ),
            if (recording && parkedPanel) ...[
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                right: besideThumbnail,
                child: SingleChildScrollView(child: panel),
              ),
              if (underThumbnail >= _landscapeParkedSpeedMinHeight)
                Positioned(
                  right: 0,
                  width: thumbWidth,
                  top: thumbHeight + MotoSize.gap,
                  bottom: 0,
                  child: const Align(
                    alignment: Alignment.bottomRight,
                    child: RecordingSpeed(size: _thumbnailHeight),
                  ),
                ),
            ],
          ],
        );
      },
    );

    final middle = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (recording) ...[header, const SizedBox(height: MotoSize.gapWide)],
        chips,
        const SizedBox(height: MotoSize.gapWide),
        Expanded(
          key: const ValueKey('recording-middle'),
          child: _ParkedGate(
            isRecording: recording,
            builder: (showPanel) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Idle, the banner and the panel sit above the Ready
                // preview and scroll in at most two fifths of the height.
                if (showPanel && !recording) ...[
                  Flexible(
                    flex: 2,
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [?banner, panel],
                      ),
                    ),
                  ),
                  const SizedBox(height: MotoSize.gapWide),
                ],
                Expanded(
                  key: const ValueKey('recording-preview-slot'),
                  flex: 3,
                  child: slot(parkedPanel: showPanel && recording),
                ),
              ],
            ),
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.all(MotoSize.gutter),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Idle only: board A-Land-Record-Live has no rail, so while
          // recording Blackout is in the chip row and Pop-out in the
          // parked details panel, as in portrait.
          if (!recording) ...[
            RecordingLandscapeRail(
              view: view,
              onRides: () => unawaited(_openRideHistory(camera: camera)),
              onSettings: () => unawaited(_openSettingsSheet()),
            ),
            const SizedBox(width: MotoSize.gapWide),
          ],
          Expanded(child: middle),
          const SizedBox(width: MotoSize.gapWide),
          SizedBox(
            width: thumbColumnWidth,
            child: RecordingLandscapeThumbColumn(
              view: view,
              band: header,
              onStart: () => _onStartPressed(camera),
              onStop: () => _onStopPressed(camera),
              onLock: () => _onLockPressed(camera),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInAppNoticeOverlay() {
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 140),
          opacity: _inAppNoticeText == null ? 0.0 : 1.0,
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: MotoColors.surfaceRaised.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: MotoColors.hairlineStrong),
            ),
            child: Text(
              _inAppNoticeText ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: MotoColors.text,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBlackoutOverlay({required CameraProvider camera}) {
    final dimTextStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.3),
      fontSize: 11,
      fontWeight: FontWeight.w600,
    );

    return Positioned.fill(
      child: Semantics(
        label: 'Blackout mode. Recording continues.',
        hint: 'Touch and hold for 2 seconds to exit blackout',
        onLongPress: () => unawaited(_exitBlackoutMode(camera: camera)),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _startBlackoutExitHold(camera: camera),
          onTapUp: (_) => _endBlackoutExitHold(),
          onTapCancel: _endBlackoutExitHold,
          child: ColoredBox(
            color: Colors.black,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.5),
                            shape: BoxShape.circle,
                          ),
                        ),
                        StreamBuilder<Duration>(
                          stream: camera.timerStream,
                          initialData: camera.elapsedTime,
                          builder: (context, snapshot) {
                            return Text(
                              'REC ${formatRecordingElapsed(snapshot.data ?? Duration.zero)}',
                              style: dimTextStyle,
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Hold 2 s anywhere to exit',
                      style: dimTextStyle.copyWith(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPipRecordingView() {
    return Scaffold(
      backgroundColor: MotoColors.bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Consumer<CameraProvider>(
              builder: (context, camera, _) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (camera.isRecording) const _BlinkingRecDot(),
                        Text(
                          camera.isRecording ? 'REC' : 'IDLE',
                          style: TextStyle(
                            color: camera.isRecording
                                ? MotoColors.rec
                                : MotoColors.dim,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    StreamBuilder<Duration>(
                      stream: camera.timerStream,
                      initialData: camera.elapsedTime,
                      builder: (context, snapshot) {
                        final text = formatRecordingElapsed(
                          snapshot.data ?? Duration.zero,
                        );
                        return Text(
                          text,
                          style: const TextStyle(
                            color: MotoColors.text,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Return to app for controls',
                      style: TextStyle(
                        color: MotoColors.dim,
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openSettingsSheet() async {
    if (_isApplyingSettings) {
      return;
    }

    final settings = context.read<AppSettingsProvider>();
    final cameraProvider = context.read<CameraProvider>();
    if (!settings.isLoaded) {
      await settings.load();
    }

    if (!mounted) {
      return;
    }

    final initialFpsOptions = await cameraProvider
        .getSupportedFpsOptionsForPreset(
          preset: cameraProvider.resolvePresetForRequestedResolution(
            settings.recordingResolution,
          ),
        );
    final initialCameraOptions = await cameraProvider.getAvailableCameras(
      refresh: true,
    );
    final initialUnsupportedPresets =
        cameraProvider.knownUnsupportedResolutionPresets;

    if (!mounted) {
      return;
    }

    final result = await showRecordingSettingsPage(
      context,
      initialFpsOptions: initialFpsOptions,
      initialCameraOptions: initialCameraOptions,
      initialUnsupportedPresets: initialUnsupportedPresets,
      settingsPending: _hasPendingCameraSettings,
    );

    if (result == null || !mounted) {
      return;
    }

    setState(() {
      _isApplyingSettings = true;
    });

    try {
      final matchedProfile = AppSettingsProvider.findMatchingQualityProfile(
        resolution: result.resolution,
        fps: result.fps,
        bitrateMbps: result.bitrateMbps,
      );
      if (matchedProfile != null) {
        await settings.updateRecordingQualityProfile(matchedProfile.id);
      } else {
        await settings.updateRecordingResolution(result.resolution);
        await settings.updateRecordingFps(result.fps);
        await settings.updateVideoBitrateMbps(result.bitrateMbps);
      }
      await settings.updateAudioEnabled(result.audioEnabled);
      await settings.updateSpeedRefreshMs(result.speedRefreshMs);
      await settings.updateSelectedCameraName(result.cameraName);
      await settings.updateSegmentDurationSeconds(
        result.segmentDurationSeconds,
      );
      await settings.updateLoopSegmentCount(result.loopSegmentCount);
      await settings.updateIncidentSensitivity(result.incidentSensitivity);
      await settings.updateExportLockedClipsToGallery(
        result.exportLockedClipsToGallery,
      );
      await settings.updateKeepScreenOnWhileRecording(
        result.keepScreenOnWhileRecording,
      );
      await settings.updateRecordingsStorageBudgetGb(
        result.recordingsStorageBudgetGb,
      );

      if (!mounted) {
        return;
      }

      // Takes effect at once for a recording in progress; the native side
      // ignores it while nothing is recording.
      if (cameraProvider.isRecording) {
        await _backgroundRecordingService.setKeepScreenOn(
          enabled: result.keepScreenOnWhileRecording,
        );
        if (!mounted) {
          return;
        }
      }

      final telemetry = context.read<TelemetryProvider>();
      telemetry.setSpeedUiRefreshInterval(
        Duration(milliseconds: result.speedRefreshMs),
      );
      telemetry.setIncidentDetectionConfig(
        triggerGForce: settings.incidentTriggerGForce,
        debounce: settings.incidentDebounce,
      );

      final camera = context.read<CameraProvider>();
      final wasRecording = camera.isRecording;
      final applied = await camera.applyRecordingSettings(
        resolutionPreset: camera.resolvePresetForRequestedResolution(
          result.resolution,
        ),
        recordingFps: result.fps,
        videoBitrateBps: result.bitrateMbps * 1000 * 1000,
        audioEnabled: result.audioEnabled,
        preferredCameraName: result.cameraName,
        segmentDurationSeconds: result.segmentDurationSeconds,
        maxRollingSegments: result.loopSegmentCount,
      );

      if (!applied && wasRecording) {
        _hasPendingCameraSettings = true;
      }

      if (!mounted) {
        return;
      }

      final appliedResolution = CameraProvider.resolutionForPreset(
        camera.resolutionPreset,
      );
      final segmentDurationLabel = AppSettingsProvider.segmentDurationLabel(
        result.segmentDurationSeconds,
      );
      final message = applied
          ? (appliedResolution != result.resolution
                ? 'Requested ${result.resolution}p is not supported on this device. Applied ${appliedResolution}p at ${camera.recordingFps} FPS, ${result.bitrateMbps}Mbps, $segmentDurationLabel, loop ${result.loopSegmentCount} segments'
                : 'Settings applied: ${appliedResolution}p, ${camera.recordingFps} FPS, ${result.bitrateMbps}Mbps, $segmentDurationLabel, loop ${result.loopSegmentCount} segments')
          : (wasRecording
                ? 'Camera settings saved. They apply to the next recording.'
                : 'Unable to initialize camera with the selected settings on this device.');

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) {
        setState(() {
          _isApplyingSettings = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _telemetryProvider?.removeListener(_onTelemetryChanged);
    _cameraProvider?.removeListener(_onCameraChanged);
    WidgetsBinding.instance.removeObserver(this);
    if (widget.landscapeRecording) {
      _orientationPinner.dispose();
    }
    _blackoutExitHoldTimer?.cancel();
    _inAppNoticeTimer?.cancel();
    unawaited(_recordingTimerSubscription?.cancel());
    unawaited(_backgroundEventSubscription?.cancel());
    unawaited(_pipModeSubscription?.cancel());
    _deviceStatusTimer?.cancel();
    _deviceStatus.dispose();
    _freeStorageBytes.dispose();
    final resumeWaiter = _resumeWaiter;
    _resumeWaiter = null;
    if (resumeWaiter != null && !resumeWaiter.isCompleted) {
      resumeWaiter.complete();
    }
    unawaited(_stopForegroundServiceSafely());
    super.dispose();
  }
}

/// Blinking red dot shown next to REC in the Picture-in-Picture view. Owns
/// its timer, so the timer stops when the dot leaves the tree.
class _BlinkingRecDot extends StatefulWidget {
  const _BlinkingRecDot();

  @override
  State<_BlinkingRecDot> createState() => _BlinkingRecDotState();
}

class _BlinkingRecDotState extends State<_BlinkingRecDot> {
  Timer? _timer;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _visible = !_visible;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1.0 : 0.25,
      duration: const Duration(milliseconds: 180),
      child: Container(
        width: 8,
        height: 8,
        margin: const EdgeInsets.only(right: 6),
        decoration: const BoxDecoration(
          color: MotoColors.rec,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

// The portrait layout's minimum height; a shorter window scrolls.
const double _minPortraitHeight = 680;

// The boards' screen height, at which START and LOCK have their full size.
const double _boardHeight = 844;

// The live thumbnail of a recording, as on the boards.
const double _thumbnailWidth = 120;
const double _thumbnailHeight = 68;

// Height of the preview and speed area when the screen scrolls.
const double _compactMiddleHeight = 220;

// The landscape layout's live thumbnail and speed, as on the
// A-Land-Record-Live board.
const double _landscapeThumbnailWidth = 196;
const double _landscapeThumbnailHeight = 110;
const double _landscapeSpeedSize = 176;

// Least room under the landscape thumbnail for the parked speed; less and
// the parked speed is left out (the details panel beside it stays).
const double _landscapeParkedSpeedMinHeight = 32;

/// Shows the details panel while parked: always while idle, and while
/// recording only below [parkedSpeedKmh]. Its [Selector] rebuilds only when
/// the rider stops or moves off, never on a speed tick.
class _ParkedGate extends StatelessWidget {
  const _ParkedGate({required this.isRecording, required this.builder});

  final bool isRecording;
  final Widget Function(bool showPanel) builder;

  @override
  Widget build(BuildContext context) {
    return Selector<TelemetryProvider, bool>(
      selector: (_, telemetry) => isParkedSpeed(telemetry.currentData.speed),
      builder: (context, parked, _) => builder(!isRecording || parked),
    );
  }
}

/// Telemetry values the recording screen's widgets show; a [Selector] on
/// them rebuilds the screen only when one changes, never on a speed tick.
typedef _TelemetryFlags = ({
  bool incidentUnavailable,
  bool locationOff,
  bool persistingRide,
});

enum _PermissionRecoveryAction { dismiss, retryRequest, openSettings }

/// What `_stopRecordingFlow` managed to save.
enum _StopOutcome {
  /// The ride JSON (telemetry sidecar) was written.
  saved,

  /// Segments were kept but no ride JSON was written, without an error.
  videoOnly,

  /// Writing the ride JSON failed; a Retry SnackBar was shown.
  saveFailed,

  /// Stopping the camera failed.
  stopFailed,

  /// The session had no segment to save.
  nothingSaved,

  /// Nothing was done: a stop was already running or nothing was recording.
  skipped,
}

// Label AppPermissionService uses for a missing battery-optimization
// exemption in PermissionAuditResult.missingRecommended.
const String _batteryOptimizationIssueLabel = 'Ignore battery optimizations';

// Warning shown when the foreground service did not start, or stopped on its
// own during a recording.
const String _backgroundProtectionUnavailableMessage =
    'Background protection unavailable: recording may stop if the app is in '
    'the background or the screen turns off.';
