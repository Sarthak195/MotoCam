// lib/features/recording/recording_screen.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
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
import 'widgets/recording_settings_sheet.dart';
import 'start_preflight_evaluator.dart';
import 'widgets/start_preflight_sheet.dart';

/// The app's home screen: camera preview, live telemetry and the controls
/// that start, stop and lock recordings.
///
/// It coordinates the recording session across [CameraProvider],
/// [TelemetryProvider], [AppSettingsProvider], the Android foreground
/// service and Picture-in-Picture.
class RecordingScreen extends StatefulWidget {
  /// Creates the recording screen.
  const RecordingScreen({super.key});

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
  DeviceStatusSnapshot _deviceStatus = DeviceStatusSnapshot.empty;
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
    _deviceStatusTimer?.cancel();
    _deviceStatusTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_refreshDeviceStatus());
    });
  }

  Future<void> _refreshDeviceStatus() async {
    if (_isFetchingDeviceStatus || !mounted) {
      return;
    }

    _isFetchingDeviceStatus = true;
    try {
      final snapshot = await _deviceStatusService.getBatteryAndThermalStatus();
      if (!mounted || snapshot == _deviceStatus) {
        return;
      }

      setState(() {
        _deviceStatus = snapshot;
      });
    } finally {
      _isFetchingDeviceStatus = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) {
      return;
    }

    final camera = context.read<CameraProvider>();
    if (_isBlackoutMode &&
        (state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden)) {
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
        });
        return;
      }

      setState(() {
        _isInPipMode = inPip;
      });
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
    final started = await camera.startRecording();
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

  Future<void> _enterBlackoutMode({required CameraProvider camera}) async {
    if (_isBlackoutMode || !camera.isRecording) {
      return;
    }

    try {
      await camera.controller?.pausePreview();
    } catch (e) {
      debugPrint('Blackout: pausePreview failed: $e');
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _isBlackoutMode = true;
    });
    _showInAppNotice('Blackout on. Hold 2s anywhere to exit.');
  }

  Future<void> _exitBlackoutMode({required CameraProvider camera}) async {
    if (!_isBlackoutMode) {
      return;
    }

    _blackoutExitHoldTimer?.cancel();
    _blackoutExitTriggered = false;

    try {
      await camera.controller?.resumePreview();
    } catch (e) {
      debugPrint('Blackout: resumePreview failed: $e');
    }

    if (!mounted) {
      return;
    }

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

    final hasBlockingIssue = StartPreflightEvaluator.hasBlockingIssue(checks);
    if (!startPreflightNeedsSheet(checks)) {
      return true;
    }

    final proceed =
        await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          backgroundColor: const Color(0xFF111111),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          builder: (context) {
            return StartPreflightSheet(
              checks: checks,
              hasBlockingIssue: hasBlockingIssue,
            );
          },
        ) ??
        false;

    return proceed && !hasBlockingIssue;
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
        batteryLevelPercent: _deviceStatus.batteryLevelPercent,
        batteryTemperatureC: _deviceStatus.batteryTemperatureC,
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
        try {
          await _exitBlackoutMode(camera: camera);
        } catch (e) {
          debugPrint('Leaving blackout after stop failed: $e');
        }
      }
      _isStoppingRecording = false;
      if (mounted) {
        setState(() {});
      }
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
    if (!camera.isRecording || detectedAt == null) {
      return;
    }

    if (_lastHandledIncidentAt != null &&
        !detectedAt.isAfter(_lastHandledIncidentAt!)) {
      return;
    }

    _lastHandledIncidentAt = detectedAt;
    // Lock immediately: frames (and post-frame callbacks) stop while the app
    // is hidden or paused, but recording and incident detection continue.
    final registeredSegments = camera.lastSessionSegmentPaths.length;
    camera.markIncident(
      protectPastSegments: 2,
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
                  backgroundColor: Colors.black,
                  body: SafeArea(
                    child: Stack(
                      children: [
                        Column(
                          children: [
                            _buildHeader(camera),
                            _buildActiveProfileBar(),
                            // Rides moving into private storage (idle only:
                            // a run pauses while recording).
                            if (!camera.isRecording)
                              RecordingsMigrationBanner(
                                migration: camera.recordingsMigration,
                              ),
                            Expanded(child: _buildCameraPreview()),
                            _buildTelemetryStats(),
                            _buildControls(),
                          ],
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
              color: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Text(
              _inAppNoticeText ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
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
      backgroundColor: Colors.black,
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
                                ? Colors.redAccent
                                : Colors.white70,
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
                            color: Colors.white,
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
                        color: Colors.white54,
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

  Widget _buildHeader(CameraProvider camera) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'MotoCam',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          Row(
            children: [
              IconButton(
                icon: Icon(
                  _isBlackoutMode ? Icons.light_mode : Icons.dark_mode,
                  color: camera.isRecording ? Colors.white : Colors.white30,
                ),
                tooltip: _isBlackoutMode ? 'Exit blackout' : 'Enter blackout',
                onPressed: _isApplyingSettings || !camera.isRecording
                    ? null
                    : () {
                        if (_isBlackoutMode) {
                          unawaited(_exitBlackoutMode(camera: camera));
                        } else {
                          unawaited(_enterBlackoutMode(camera: camera));
                        }
                      },
              ),
              IconButton(
                icon: const Icon(Icons.settings, color: Colors.white),
                tooltip: 'Settings',
                onPressed:
                    _isApplyingSettings ||
                        _isStartingRecording ||
                        _isStoppingRecording ||
                        camera.isStartingRecording ||
                        camera.isStoppingRecording
                    ? null
                    : _openSettingsSheet,
              ),
            ],
          ),
        ],
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

    final result = await showModalBottomSheet<RecordingSettingsFormResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return RecordingSettingsSheet(
          initialFpsOptions: initialFpsOptions,
          initialCameraOptions: initialCameraOptions,
          initialUnsupportedPresets: initialUnsupportedPresets,
        );
      },
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

  Widget _buildActiveProfileBar() {
    return Consumer2<AppSettingsProvider, CameraProvider>(
      builder: (context, settings, camera, _) {
        // Saved values are the rider's request; when the camera negotiated
        // something else, show the applied value next to the request.
        final showApplied = camera.isInitialized && !_hasPendingCameraSettings;
        final appliedResolution = CameraProvider.resolutionForPreset(
          camera.resolutionPreset,
        );
        final resolutionLabel =
            showApplied && appliedResolution != settings.recordingResolution
            ? '${appliedResolution}p (set ${settings.recordingResolution}p)'
            : '${settings.recordingResolution}p';
        final fpsLabel =
            showApplied && camera.recordingFps != settings.recordingFps
            ? '${camera.recordingFps} FPS (set ${settings.recordingFps})'
            : '${settings.recordingFps} FPS';
        final chips = <Widget>[
          if (settings.selectedCameraName.isNotEmpty)
            _buildProfileChip('Cam ${settings.selectedCameraName}'),
          _buildProfileChip(resolutionLabel),
          _buildProfileChip(fpsLabel),
          _buildProfileChip('${settings.videoBitrateMbps} Mbps'),
          _buildProfileChip(settings.audioEnabled ? 'Audio On' : 'Audio Off'),
          _buildProfileChip(
            '${AppSettingsProvider.segmentDurationLabel(settings.segmentDurationSeconds)} x ${settings.loopSegmentCount} loop',
          ),
          _buildProfileChip(
            'Incident ${settings.incidentSensitivity.name.toUpperCase()}',
          ),
          _buildProfileChip('Speed ${settings.speedRefreshMs}ms'),
        ];

        final showHighSensitivityWarning =
            settings.incidentSensitivity == IncidentSensitivity.high;

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            border: Border(
              bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 34,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: chips.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, index) => chips[index],
                ),
              ),
              Selector<TelemetryProvider, bool>(
                selector: (_, telemetry) =>
                    !telemetry.isIncidentDetectionAvailable,
                builder: (context, unavailable, _) {
                  if (!unavailable) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Incident detection unavailable (no motion sensor): '
                      'clips are not auto-locked. Use LOCK.',
                      style: TextStyle(
                        color: Colors.orange.withValues(alpha: 0.9),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                },
              ),
              Selector<TelemetryProvider, bool>(
                selector: (_, telemetry) =>
                    telemetry.isTracking && !telemetry.isLocationServiceEnabled,
                builder: (context, locationOff, _) {
                  if (!locationOff) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Location is off: no speed, distance or route is recorded.',
                      style: TextStyle(
                        color: Colors.orange.withValues(alpha: 0.9),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                },
              ),
              if (showHighSensitivityWarning)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'High incident sensitivity may increase auto-lock frequency.',
                    style: TextStyle(
                      color: Colors.orange.withValues(alpha: 0.9),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildProfileChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildCameraPreview() {
    return Consumer<CameraProvider>(
      builder: (context, camera, _) {
        if (_isBlackoutMode) {
          return const ColoredBox(color: Colors.black);
        }

        if (!camera.isInitialized || camera.controller == null) {
          final mode = cameraPreviewMode(
            cameraReady: false,
            initState: camera.initState,
            initAttempted: _cameraInitAttempted,
            setupBusy:
                _isBootstrapping ||
                _isNavigatingHistory ||
                camera.isInitializing ||
                camera.isRecording,
          );
          if (mode == CameraPreviewMode.failed) {
            return _buildCameraUnavailable(camera.initFailure);
          }
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }

        final controller = camera.controller!;
        if (!controller.value.isInitialized) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }
        final rawAspectRatio = controller.value.aspectRatio;
        final safeAspectRatio = rawAspectRatio.isFinite && rawAspectRatio > 0
            ? rawAspectRatio
            : (16 / 9);
        final portraitAspectRatio = safeAspectRatio > 1
            ? (1 / safeAspectRatio)
            : safeAspectRatio;

        return Stack(
          key: ValueKey(
            'camera-preview-${camera.resolutionPreset}-${camera.recordingFps}-${camera.activeCameraName}-${controller.hashCode}',
          ),
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: portraitAspectRatio,
                      child: CameraPreview(controller),
                    ),
                  ),
                ),
              ),
            ),
            if (camera.isRecording)
              Positioned(
                top: 12,
                left: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'REC',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (camera.isRecordingSegmentLocked) ...[
                        const SizedBox(width: 10),
                        const Icon(Icons.lock, color: Colors.white, size: 14),
                        const SizedBox(width: 4),
                        const Text(
                          'LOCKED',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildCameraUnavailable(CameraInitFailure? failure) {
    final panel = cameraInitPanelFor(failure);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, color: Colors.white54, size: 40),
            const SizedBox(height: 12),
            Text(
              panel.title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              panel.message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                if (panel.showRetry)
                  ElevatedButton(
                    onPressed: _retryCameraSetup,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: recordingStartButtonColor,
                      foregroundColor: recordingButtonLabelColor,
                    ),
                    child: const Text('Retry'),
                  ),
                if (panel.showOpenSettings)
                  OutlinedButton(
                    onPressed: () => unawaited(_openAppSettingsAndRetry()),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
                    child: const Text('Open Settings'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTelemetryStats() {
    final batteryLevel = _deviceStatus.batteryLevelPercent;
    final batteryTemp = _deviceStatus.batteryTemperatureC;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Selector<TelemetryProvider, String>(
              selector: (_, telemetry) =>
                  '${telemetry.currentData.speed.toStringAsFixed(0)} km/h',
              builder: (context, speed, _) {
                return _buildStatItem(
                  icon: Icons.speed,
                  label: 'Speed',
                  value: speed,
                  compact: true,
                );
              },
            ),
          ),
          Expanded(
            child: Consumer<CameraProvider>(
              builder: (context, camera, _) {
                return StreamBuilder<Duration>(
                  stream: camera.timerStream,
                  initialData: camera.elapsedTime,
                  builder: (context, snapshot) {
                    final formattedTime = formatRecordingElapsed(
                      snapshot.data ?? Duration.zero,
                    );

                    return _buildStatItem(
                      icon: Icons.timer,
                      label: 'Duration',
                      value: formattedTime,
                      compact: true,
                    );
                  },
                );
              },
            ),
          ),
          Expanded(
            child: Selector<TelemetryProvider, String>(
              selector: (_, telemetry) =>
                  '${telemetry.rideDistanceKm.toStringAsFixed(2)} km',
              builder: (context, distance, _) {
                return _buildStatItem(
                  icon: Icons.route,
                  label: 'Distance',
                  value: distance,
                  compact: true,
                );
              },
            ),
          ),
          Expanded(
            child: _buildStatItem(
              icon: Icons.battery_std,
              label: 'Battery',
              value: batteryLevel == null ? '--' : '$batteryLevel%',
              compact: true,
            ),
          ),
          Expanded(
            child: _buildStatItem(
              icon: Icons.device_thermostat,
              label: 'Temp',
              value: batteryTemp == null
                  ? '--'
                  : '${batteryTemp.toStringAsFixed(1)} C',
              compact: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem({
    required IconData icon,
    required String label,
    required String value,
    bool compact = false,
  }) {
    final iconSize = compact ? 20.0 : 24.0;
    final valueStyle = TextStyle(
      color: Colors.white,
      fontSize: compact ? 12 : 18,
      fontWeight: FontWeight.bold,
    );
    final labelStyle = TextStyle(
      color: Colors.grey[400],
      fontSize: compact ? 10 : 12,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.blue, size: iconSize),
        SizedBox(height: compact ? 2 : 4),
        // Scales the value down instead of ellipsizing it at large system
        // font sizes.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            maxLines: 1,
            textAlign: TextAlign.center,
            style: valueStyle,
          ),
        ),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: labelStyle,
        ),
      ],
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Selector<TelemetryProvider, bool>(
            selector: (_, telemetry) => telemetry.isPersistingRide,
            builder: (context, isPersistingRide, _) =>
                Consumer2<CameraProvider, AppSettingsProvider>(
                  builder: (context, camera, settings, _) {
                    final selectedPreset = CameraProvider.presetForResolution(
                      settings.recordingResolution,
                    );
                    final resolvedPreset = camera
                        .resolvePresetForRequestedResolution(
                          settings.recordingResolution,
                        );
                    final unsupportedPresets =
                        camera.knownUnsupportedResolutionPresets;
                    final isPresetUnsupported =
                        !camera.isRecording &&
                        unsupportedPresets.contains(selectedPreset);
                    final willAutoFallback =
                        isPresetUnsupported && resolvedPreset != selectedPreset;
                    final supportedResolutions = AppSettingsProvider
                        .resolutionOptions
                        .where(
                          (resolution) => !unsupportedPresets.contains(
                            CameraProvider.presetForResolution(resolution),
                          ),
                        )
                        .toList();
                    final isStarting =
                        _isStartingRecording || camera.isStartingRecording;
                    // A ride is still being saved (also a Retry of a failed save):
                    // START waits for it.
                    final isStopping =
                        _isStoppingRecording ||
                        camera.isStoppingRecording ||
                        (isPersistingRide && !camera.isRecording);
                    final isPreparingCamera =
                        !camera.isRecording && camera.isInitializing;
                    final isBusy =
                        _isApplyingSettings ||
                        isStarting ||
                        isStopping ||
                        isPreparingCamera;
                    final String buttonLabel;
                    if (_isApplyingSettings) {
                      buttonLabel = 'APPLYING SETTINGS...';
                    } else if (isStopping) {
                      buttonLabel = 'SAVING RECORDING...';
                    } else if (isStarting) {
                      buttonLabel = 'STARTING...';
                    } else if (isPreparingCamera) {
                      buttonLabel = 'PREPARING CAMERA...';
                    } else {
                      buttonLabel = camera.isRecording
                          ? 'STOP RECORDING'
                          : 'START RECORDING';
                    }
                    final suggestedResolution = supportedResolutions.isEmpty
                        ? null
                        : supportedResolutions.last;

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ElevatedButton(
                          onPressed: isBusy
                              ? null
                              : () async {
                                  final messenger = ScaffoldMessenger.of(
                                    context,
                                  );
                                  final telemetry = context
                                      .read<TelemetryProvider>();
                                  if (camera.isRecording) {
                                    await _stopRecordingFlow(
                                      camera: camera,
                                      telemetry: telemetry,
                                      messenger: messenger,
                                    );
                                  } else {
                                    await _startRecordingFlow(
                                      camera: camera,
                                      telemetry: telemetry,
                                      messenger: messenger,
                                    );
                                  }
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: camera.isRecording
                                ? recordingStopButtonColor
                                : recordingStartButtonColor,
                            foregroundColor: recordingButtonLabelColor,
                            disabledBackgroundColor: Colors.grey.shade800,
                            disabledForegroundColor: Colors.white70,
                            minimumSize: const Size(double.infinity, 52),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            buttonLabel,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (_isApplyingSettings)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text(
                              'Applying settings... camera controls are temporarily locked.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        if (isPresetUnsupported)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              willAutoFallback
                                  ? 'Current ${settings.recordingResolution}p is unstable on this device. Recording will auto-fallback to ${CameraProvider.resolutionForPreset(resolvedPreset)}p.'
                                  : (suggestedResolution == null
                                        ? 'Current ${settings.recordingResolution}p is known unstable on this device. Choose a lower resolution in Settings.'
                                        : 'Current ${settings.recordingResolution}p is known unstable on this device. Choose ${suggestedResolution}p or lower in Settings.'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.orange,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
          ),
          const SizedBox(height: 8),
          Consumer<CameraProvider>(
            builder: (context, camera, _) {
              final isStopping =
                  _isStoppingRecording || camera.isStoppingRecording;
              final isBusy =
                  _isApplyingSettings ||
                  _isStartingRecording ||
                  camera.isStartingRecording ||
                  isStopping;
              // While recording this button minimises into PiP instead of
              // opening history, so it says so.
              final historyLabel = camera.isRecording ? 'MINIMISE' : 'HISTORY';
              final historyIcon = camera.isRecording
                  ? Icons.picture_in_picture_alt
                  : Icons.video_library_outlined;
              return Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: isBusy
                          ? null
                          : (camera.isRecording
                                ? () {
                                    unawaited(_handleBackPressWhileRecording());
                                  }
                                : () async {
                                    await _openRideHistory(camera: camera);
                                  }),
                      icon: Icon(historyIcon, color: Colors.blue),
                      label: Text(
                        historyLabel,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.blue,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(44),
                        side: const BorderSide(color: Colors.blue),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: camera.isRecording && !isStopping
                          ? () {
                              final registeredSegments =
                                  camera.lastSessionSegmentPaths.length;
                              camera.markIncident(
                                protectPastSegments: 2,
                                protectCurrentSegment: true,
                                reason: 'manual-emergency',
                              );
                              _checkpointRideIfChanged(camera);
                              unawaited(HapticFeedback.heavyImpact());
                              _showInAppNotice(
                                incidentLockNotice(
                                  registeredSegments: registeredSegments,
                                ),
                              );
                            }
                          : null,
                      icon: const Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.orange,
                      ),
                      label: const Text(
                        'LOCK',
                        style: TextStyle(fontSize: 14, color: Colors.orange),
                      ),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(44),
                        side: BorderSide(
                          color: camera.isRecording
                              ? Colors.orange
                              : Colors.orange.withValues(alpha: 0.3),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _telemetryProvider?.removeListener(_onTelemetryChanged);
    _cameraProvider?.removeListener(_onCameraChanged);
    WidgetsBinding.instance.removeObserver(this);
    _blackoutExitHoldTimer?.cancel();
    _inAppNoticeTimer?.cancel();
    unawaited(_recordingTimerSubscription?.cancel());
    unawaited(_backgroundEventSubscription?.cancel());
    unawaited(_pipModeSubscription?.cancel());
    _deviceStatusTimer?.cancel();
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
          color: Colors.redAccent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

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
