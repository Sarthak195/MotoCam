// lib/features/recording/recording_screen.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/providers/app_settings_provider.dart';
import '../../core/services/app_permission_service.dart';
import '../../core/services/background_recording_service.dart';
import '../../core/services/device_status_service.dart';
import '../../core/services/pip_service.dart';
import '../camera/providers/camera_provider.dart';
import '../telemetry/providers/telemetry_provider.dart';
import '../history/rides_list_screen.dart';

class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key});

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen>
    with WidgetsBindingObserver {
  static const Duration _stallRecoveryBackgroundThreshold =
      Duration(seconds: 8);

  DateTime? _lastHandledIncidentAt;
  DateTime? _lastBackgroundedAt;
  final BackgroundRecordingService _backgroundRecordingService =
      BackgroundRecordingService.instance;
  final PipService _pipService = PipService.instance;
  final AppPermissionService _permissionService = const AppPermissionService();
  final DeviceStatusService _deviceStatusService = DeviceStatusService();
  StreamSubscription<BackgroundRecordingEvent>? _backgroundEventSubscription;
  StreamSubscription<Duration>? _recordingTimerSubscription;
  StreamSubscription<bool>? _pipModeSubscription;
  Timer? _deviceStatusTimer;
  bool _isStoppingRecording = false;
  bool _isApplyingSettings = false;
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
  final Stream<int> _pipBlinkStream = Stream<int>.periodic(
    const Duration(milliseconds: 700),
    (tick) => tick,
  ).asBroadcastStream();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializePipBridge();
    _initializeBackgroundRecordingBridge();
    _startDeviceStatusPolling();
    unawaited(_bootstrapRuntimePrerequisites());
  }

  Future<void> _bootstrapRuntimePrerequisites() async {
    final settings = context.read<AppSettingsProvider>();
    if (!settings.isLoaded) {
      await settings.load();
    }

    final permissionAudit = await _permissionService.ensureRequiredPermissions(
      audioEnabled: settings.audioEnabled,
    );
    if (!mounted) {
      return;
    }

    final resolvedAudit = await _handlePermissionAuditResult(
      permissionAudit,
      audioEnabled: settings.audioEnabled,
    );
    if (!mounted || resolvedAudit.hasBlockingIssues) {
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
              ? '\n\nSome permissions are permanently denied. Use Open Settings to enable them.'
              : '';
          return AlertDialog(
            title: const Text('Permissions Required'),
            content: Text(
              'Recording cannot start until these permissions are granted:\n$missing$permanentNote',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext)
                    .pop(_PermissionRecoveryAction.dismiss),
                child: const Text('Later'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext)
                    .pop(_PermissionRecoveryAction.retryRequest),
                child: const Text('Request Again'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext)
                    .pop(_PermissionRecoveryAction.openSettings),
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
          await openAppSettings();
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

    final issues = <String>[
      ...resolvedAudit.missingRequired,
      ...resolvedAudit.missingRecommended,
    ];
    final message = resolvedAudit.hasBlockingIssues
        ? 'Required permissions missing: ${resolvedAudit.missingRequired.join(', ')}'
        : 'Recommended for reliable background recording: ${issues.join(', ')}';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 4),
      ),
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
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (_isBlackoutMode) {
        unawaited(_exitBlackoutMode(camera: camera));
      }
      if (camera.isRecording) {
        _lastBackgroundedAt = DateTime.now();
      }
      return;
    }

    if (state != AppLifecycleState.resumed || !camera.isRecording) {
      return;
    }

    final backgroundedAt = _lastBackgroundedAt;
    _lastBackgroundedAt = null;
    if (backgroundedAt == null) {
      return;
    }

    final backgroundDuration = DateTime.now().difference(backgroundedAt);
    if (backgroundDuration < _stallRecoveryBackgroundThreshold) {
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
      return;
    }

    _isRecoveringFromStall = true;
    final messenger = ScaffoldMessenger.of(context);
    final camera = context.read<CameraProvider>();

    try {
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
              'Video feed may have stalled while screen was off. Recording was auto-recovered after ${backgroundDuration.inSeconds}s in background.',
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

  Future<void> _initializePipBridge() async {
    await _pipService.initialize();
    _isInPipMode = _pipService.isInPipMode;
    _pipModeSubscription?.cancel();
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
    _backgroundEventSubscription?.cancel();
    _backgroundEventSubscription =
        _backgroundRecordingService.events.listen((event) async {
      if (event != BackgroundRecordingEvent.stopRequested || !mounted) {
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
    final settings = context.read<AppSettingsProvider>();
    final permissionAudit = await _permissionService.ensureRequiredPermissions(
      audioEnabled: settings.audioEnabled,
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

    final started = await camera.startRecording();
    if (started && camera.isRecording) {
      if (!mounted) {
        return;
      }
      await _syncSettingsWithCameraCapabilities(
        settings: settings,
        camera: camera,
      );

      telemetry.startRideSession();
      await _backgroundRecordingService.startForegroundRecording(
        elapsed: Duration.zero,
      );
      _recordingTimerSubscription?.cancel();
      _recordingTimerSubscription = camera.timerStream.listen((elapsed) {
        _backgroundRecordingService.updateForegroundRecording(elapsed: elapsed);
      });
    }

    if (!mounted) {
      return;
    }

    _showInAppNotice(
      started ? 'REC started' : 'Start failed. Try lower quality.',
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

  Future<void> _enterBlackoutMode({
    required CameraProvider camera,
  }) async {
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

  Future<void> _exitBlackoutMode({
    required CameraProvider camera,
  }) async {
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

    final hasBlockingIssue = checks.any(
      (check) =>
          check.isBlocking && check.status == _StartPreflightStatus.failed,
    );
    final allRequirementsMet = checks.every(
      (check) => check.status == _StartPreflightStatus.ok,
    );
    if (allRequirementsMet && !hasBlockingIssue) {
      return true;
    }

    final proceed = await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          backgroundColor: const Color(0xFF111111),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          builder: (context) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Ready To Record?',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hasBlockingIssue
                          ? 'Fix blocking checks before recording.'
                          : 'Preflight checks look good. Start when ready.',
                      style: TextStyle(
                        color: hasBlockingIssue
                            ? Colors.redAccent
                            : Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 14),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 340),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: checks.length,
                        separatorBuilder: (_, __) => Divider(
                          color: Colors.white.withValues(alpha: 0.08),
                          height: 1,
                        ),
                        itemBuilder: (context, index) {
                          final check = checks[index];
                          final color = _preflightStatusColor(check.status);
                          return ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            leading: Icon(
                              _preflightStatusIcon(check.status),
                              color: color,
                            ),
                            title: Text(
                              check.title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              check.detail,
                              style: TextStyle(
                                  color: color.withValues(alpha: 0.95)),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.25),
                              ),
                            ),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: hasBlockingIssue
                                ? null
                                : () => Navigator.of(context).pop(true),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                              disabledBackgroundColor: Colors.grey.shade800,
                            ),
                            child: const Text('Start Recording'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ) ??
        false;

    return proceed && !hasBlockingIssue;
  }

  Future<List<_StartPreflightCheck>> _buildStartPreflightChecks({
    required CameraProvider camera,
    required AppSettingsProvider settings,
  }) async {
    if (!camera.isInitialized && !camera.isRecording) {
      await _initializeCamera();
    }

    final checks = <_StartPreflightCheck>[];

    final cameraPermissionStatus = await Permission.camera.status;
    final hasCameraPermission =
        cameraPermissionStatus.isGranted || cameraPermissionStatus.isLimited;
    checks.add(
      _StartPreflightCheck(
        title: 'Camera Permission',
        detail:
            hasCameraPermission ? 'Granted' : 'Camera permission is required',
        status: hasCameraPermission
            ? _StartPreflightStatus.ok
            : _StartPreflightStatus.failed,
        isBlocking: true,
      ),
    );

    if (settings.audioEnabled) {
      final micStatus = await Permission.microphone.status;
      final micGranted = micStatus.isGranted || micStatus.isLimited;
      checks.add(
        _StartPreflightCheck(
          title: 'Microphone Permission',
          detail: micGranted ? 'Granted' : 'Microphone is required for audio',
          status: micGranted
              ? _StartPreflightStatus.ok
              : _StartPreflightStatus.failed,
          isBlocking: true,
        ),
      );
    }

    final locationPermissionStatus = await Permission.locationWhenInUse.status;
    final hasLocationPermission = locationPermissionStatus.isGranted ||
        locationPermissionStatus.isLimited;
    checks.add(
      _StartPreflightCheck(
        title: 'Location Permission',
        detail: hasLocationPermission
            ? 'Granted'
            : 'Required for speed, distance, and route telemetry',
        status: hasLocationPermission
            ? _StartPreflightStatus.ok
            : _StartPreflightStatus.failed,
        isBlocking: true,
      ),
    );

    final locationEnabled = await Geolocator.isLocationServiceEnabled();
    checks.add(
      _StartPreflightCheck(
        title: 'Location Services',
        detail: locationEnabled
            ? 'Enabled'
            : 'Turn ON location services in system settings',
        status: locationEnabled
            ? _StartPreflightStatus.ok
            : _StartPreflightStatus.failed,
        isBlocking: true,
      ),
    );

    final cameraReady = camera.isInitialized &&
        camera.controller != null &&
        camera.controller!.value.isInitialized;
    checks.add(
      _StartPreflightCheck(
        title: 'Camera Ready',
        detail: cameraReady
            ? 'Preview and encoder are initialized'
            : 'Camera initialization failed, retry from Recording screen',
        status: cameraReady
            ? _StartPreflightStatus.ok
            : _StartPreflightStatus.failed,
        isBlocking: true,
      ),
    );

    final canWriteMedia = await _verifyRecordingDirectoryWritable(camera);
    checks.add(
      _StartPreflightCheck(
        title: 'Media Write Access',
        detail: canWriteMedia
            ? 'App recording storage is writable'
            : 'Unable to write to app recording storage',
        status: canWriteMedia
            ? _StartPreflightStatus.ok
            : _StartPreflightStatus.failed,
        isBlocking: true,
      ),
    );

    if (Platform.isAndroid) {
      final notificationsGranted =
          (await Permission.notification.status).isGranted;
      checks.add(
        _StartPreflightCheck(
          title: 'Foreground Notification',
          detail: notificationsGranted
              ? 'Allowed'
              : 'Recommended so background recording status stays visible',
          status: notificationsGranted
              ? _StartPreflightStatus.ok
              : _StartPreflightStatus.warning,
          isBlocking: false,
        ),
      );

      final ignoresBatteryOptimization =
          await _backgroundRecordingService.isIgnoringBatteryOptimizations();
      checks.add(
        _StartPreflightCheck(
          title: 'Battery Optimization Exemption',
          detail: ignoresBatteryOptimization
              ? 'Enabled'
              : 'Recommended for stable screen-off recording',
          status: ignoresBatteryOptimization
              ? _StartPreflightStatus.ok
              : _StartPreflightStatus.warning,
          isBlocking: false,
        ),
      );
    }

    final batteryLevel = _deviceStatus.batteryLevelPercent;
    if (batteryLevel != null) {
      final lowBattery = batteryLevel < 15;
      checks.add(
        _StartPreflightCheck(
          title: 'Battery Level',
          detail: '$batteryLevel%${lowBattery ? ' (low for long rides)' : ''}',
          status: lowBattery
              ? _StartPreflightStatus.warning
              : _StartPreflightStatus.ok,
          isBlocking: false,
        ),
      );
    }

    final batteryTemp = _deviceStatus.batteryTemperatureC;
    if (batteryTemp != null) {
      final hotDevice = batteryTemp >= 43.0;
      checks.add(
        _StartPreflightCheck(
          title: 'Device Temperature',
          detail:
              '${batteryTemp.toStringAsFixed(1)} C${hotDevice ? ' (high temperature)' : ''}',
          status: hotDevice
              ? _StartPreflightStatus.warning
              : _StartPreflightStatus.ok,
          isBlocking: false,
        ),
      );
    }

    return checks;
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

  IconData _preflightStatusIcon(_StartPreflightStatus status) {
    switch (status) {
      case _StartPreflightStatus.ok:
        return Icons.check_circle;
      case _StartPreflightStatus.warning:
        return Icons.warning_amber_rounded;
      case _StartPreflightStatus.failed:
        return Icons.cancel;
    }
  }

  Color _preflightStatusColor(_StartPreflightStatus status) {
    switch (status) {
      case _StartPreflightStatus.ok:
        return Colors.lightGreenAccent;
      case _StartPreflightStatus.warning:
        return Colors.orangeAccent;
      case _StartPreflightStatus.failed:
        return Colors.redAccent;
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

    final shouldOpenSettings = await showDialog<bool>(
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

    await Geolocator.openLocationSettings();
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

  Future<void> _stopRecordingFlow({
    required CameraProvider camera,
    required TelemetryProvider telemetry,
    required ScaffoldMessengerState messenger,
    bool showSuccessMessage = true,
  }) async {
    if (_isStoppingRecording) {
      return;
    }

    _isStoppingRecording = true;
    try {
      final settings = context.read<AppSettingsProvider>();
      final recordingSettings = <String, dynamic>{
        'requestedResolution': settings.recordingResolution,
        'requestedFps': settings.recordingFps,
        'requestedBitrateMbps': settings.videoBitrateMbps,
        'requestedSegmentDurationSeconds': settings.segmentDurationSeconds,
        'requestedLoopSegmentCount': settings.loopSegmentCount,
        'requestedAudioEnabled': settings.audioEnabled,
        'requestedCameraName': settings.selectedCameraName,
        'requestedIncidentSensitivity': settings.incidentSensitivity.name,
        'requestedSpeedRefreshMs': settings.speedRefreshMs,
        'appliedResolution':
            AppSettingsProvider.fromResolutionPreset(camera.resolutionPreset),
        'appliedFps': camera.recordingFps,
        'appliedBitrateMbps': camera.videoBitrateMbps,
        'appliedAudioEnabled': camera.audioEnabled,
        'appliedSegmentDurationSeconds': camera.segmentDurationSeconds,
        'appliedLoopSegmentCount': camera.maxRollingSegments,
        'appliedCameraName': camera.activeCameraName,
      };

      _recordingTimerSubscription?.cancel();
      _recordingTimerSubscription = null;
      await _backgroundRecordingService.stopForegroundRecording();

      final videoPath = await camera.stopRecording();
      final sessionSegmentPaths = camera.lastSessionSegmentPaths;
      final resolvedVideoPath = videoPath ??
          (sessionSegmentPaths.isNotEmpty ? sessionSegmentPaths.last : null);
      if (!mounted) {
        return;
      }

      if (resolvedVideoPath != null) {
        final telemetryPath = await telemetry.stopRideSessionAndPersist(
          resolvedVideoPath,
          segmentPaths: sessionSegmentPaths,
          lockedSegmentPaths: camera.lockedSegmentPaths,
          segmentTimeline: camera.lastSessionSegmentTimeline,
          recordingSettings: recordingSettings,
        );
        if (!mounted || !showSuccessMessage) {
          return;
        }

        _showInAppNotice(
          telemetryPath == null ? 'Recording saved' : 'Recording + telemetry saved',
        );
      } else {
        telemetry.cancelRideSession();
      }

      if (_isBlackoutMode) {
        await _exitBlackoutMode(camera: camera);
      }
    } finally {
      _isStoppingRecording = false;
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !camera.isRecording) {
        return;
      }

      camera.markIncident(
        protectPastSegments: 2,
        protectCurrentSegment: true,
        reason: 'auto-crash',
      );
      _showInAppNotice('Incident detected. Segments locked.');
    });
  }

  Future<void> _initializeCamera() async {
    final settingsProvider = context.read<AppSettingsProvider>();
    final cameraProvider = context.read<CameraProvider>();
    final telemetryProvider = context.read<TelemetryProvider>();

    if (!settingsProvider.isLoaded) {
      await settingsProvider.load();
    }

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

    await _syncSettingsWithCameraCapabilities(
      settings: settingsProvider,
      camera: cameraProvider,
    );

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

  Future<void> _syncSettingsWithCameraCapabilities({
    required AppSettingsProvider settings,
    required CameraProvider camera,
  }) async {
    if (!camera.isInitialized) {
      return;
    }

    final activeResolution =
        AppSettingsProvider.fromResolutionPreset(camera.resolutionPreset);
    if (settings.recordingResolution != activeResolution) {
      await settings.updateRecordingResolution(activeResolution);
    }
    if (settings.recordingFps != camera.recordingFps) {
      await settings.updateRecordingFps(camera.recordingFps);
    }
  }

  Future<void> _handleBackPressWhileRecording() async {
    final enteredPip = await PipService.enterPipMode();
    if (!mounted || enteredPip) {
      return;
    }

    _showInAppNotice('Recording active. Stop first to exit.');
  }

  Future<void> _openRideHistory({
    required CameraProvider camera,
  }) async {
    if (_isNavigatingHistory || camera.isRecording) {
      return;
    }

    _isNavigatingHistory = true;
    try {
      await camera.releaseCameraIfIdle();
      if (!mounted) {
        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const RidesListScreen(),
        ),
      );

      if (!mounted || camera.isRecording) {
        return;
      }

      await _initializeCamera();
    } finally {
      _isNavigatingHistory = false;
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
                            Expanded(child: _buildCameraPreview()),
                            _buildTelemetryStats(),
                            _buildControls(),
                          ],
                        ),
                        _buildInAppNoticeOverlay(),
                        if (_isBlackoutMode)
                          _buildBlackoutOverlay(camera: camera),
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

  Widget _buildBlackoutOverlay({
    required CameraProvider camera,
  }) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _startBlackoutExitHold(camera: camera),
        onTapUp: (_) => _endBlackoutExitHold(),
        onTapCancel: _endBlackoutExitHold,
        child: Container(
          color: Colors.black,
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
            child: Consumer2<CameraProvider, TelemetryProvider>(
              builder: (context, camera, telemetry, _) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (camera.isRecording)
                          StreamBuilder<int>(
                            stream: _pipBlinkStream,
                            builder: (context, snapshot) {
                              final tick = snapshot.data ?? 0;
                              final opacity = tick.isEven ? 1.0 : 0.25;
                              return AnimatedOpacity(
                                opacity: opacity,
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
                            },
                          ),
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
                        final duration = snapshot.data ?? Duration.zero;
                        final hours = duration.inHours;
                        final minutes = duration.inMinutes.remainder(60);
                        final seconds = duration.inSeconds.remainder(60);
                        final text =
                            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
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
                onPressed: _isApplyingSettings ? null : _openSettingsSheet,
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

    final initialFpsOptions =
        await cameraProvider.getSupportedFpsOptionsForPreset(
      preset: cameraProvider.resolvePresetForRequestedResolution(
        settings.recordingResolution,
      ),
    );
    final initialCameraOptions =
        await cameraProvider.getAvailableCameras(refresh: true);
    final initialUnsupportedPresets =
        cameraProvider.knownUnsupportedResolutionPresets;

    if (!mounted) {
      return;
    }

    final result = await showModalBottomSheet<_SettingsFormResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        int selectedResolution = settings.recordingResolution;
        int selectedFps = settings.recordingFps;
        int selectedBitrateMbps = settings.videoBitrateMbps;
        String selectedQualityProfileId = settings.qualityProfileId;
        QualityPresetTier selectedPresetTier =
            AppSettingsProvider.profileById(settings.qualityProfileId)?.tier ??
                QualityPresetTier.balanced;
        bool audioEnabled = settings.audioEnabled;
        int speedRefreshMs = settings.speedRefreshMs;
        int segmentDurationSeconds = settings.segmentDurationSeconds;
        int loopSegmentCount = settings.loopSegmentCount;
        IncidentSensitivity incidentSensitivity = settings.incidentSensitivity;
        List<int> availableFps = List<int>.from(initialFpsOptions);
        final unsupportedResolutionPresets =
            Set<ResolutionPreset>.from(initialUnsupportedPresets);
        final cameraOptions =
            List<CameraDescription>.from(initialCameraOptions);
        String selectedCameraName = settings.selectedCameraName;
        if (selectedCameraName.isEmpty) {
          selectedCameraName = cameraProvider.activeCameraName;
        }
        if (selectedCameraName.isEmpty && cameraOptions.isNotEmpty) {
          selectedCameraName = cameraOptions.first.name;
        }
        final resolutionIsUnsupported = unsupportedResolutionPresets.contains(
          CameraProvider.presetForResolution(selectedResolution),
        );
        if (resolutionIsUnsupported) {
          final fallbackResolutions = AppSettingsProvider.resolutionOptions
              .where(
                (resolution) => !unsupportedResolutionPresets.contains(
                  CameraProvider.presetForResolution(resolution),
                ),
              )
              .toList();
          if (fallbackResolutions.isNotEmpty) {
            selectedResolution = fallbackResolutions.last;
            selectedQualityProfileId =
                AppSettingsProvider.customQualityProfileId;
          }
        }

        return StatefulBuilder(
          builder: (context, setModalState) {
            final maxSheetHeight = MediaQuery.of(context).size.height * 0.88;
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxSheetHeight),
                child: Padding(
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 16,
                    bottom: MediaQuery.of(context).viewInsets.bottom + 12,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Recording Settings',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _buildSettingsLabel('Quality group'),
                        DropdownButtonFormField<QualityPresetTier>(
                          initialValue: selectedPresetTier,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: QualityPresetTier.values
                              .map(
                                (tier) => DropdownMenuItem<QualityPresetTier>(
                                  value: tier,
                                  child: Text(
                                      AppSettingsProvider.qualityTierLabel(
                                          tier)),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;

                            final tierProfiles =
                                AppSettingsProvider.qualityProfilesForTier(
                                    value);
                            if (tierProfiles.isEmpty) {
                              return;
                            }

                            final selectedProfile = tierProfiles.first;
                            setModalState(() {
                              selectedPresetTier = value;
                              selectedQualityProfileId = selectedProfile.id;
                            });

                            () async {
                              final fpsOptions = await cameraProvider
                                  .getSupportedFpsOptionsForPreset(
                                preset: CameraProvider.presetForResolution(
                                  selectedProfile.resolution,
                                ),
                              );
                              if (!mounted) {
                                return;
                              }
                              setModalState(() {
                                selectedResolution = selectedProfile.resolution;
                                selectedBitrateMbps =
                                    selectedProfile.bitrateMbps;
                                availableFps = List<int>.from(fpsOptions);
                                if (availableFps
                                    .contains(selectedProfile.fps)) {
                                  selectedFps = selectedProfile.fps;
                                } else {
                                  selectedFps = availableFps.last;
                                  selectedQualityProfileId = AppSettingsProvider
                                      .customQualityProfileId;
                                }
                              });
                            }();
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildSettingsLabel('Recording quality preset'),
                        DropdownButtonFormField<String>(
                          initialValue: selectedQualityProfileId,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: [
                            const DropdownMenuItem<String>(
                              value: AppSettingsProvider.customQualityProfileId,
                              child: Text('Custom'),
                            ),
                            ...AppSettingsProvider.qualityProfilesForTier(
                                    selectedPresetTier)
                                .map(
                              (profile) => DropdownMenuItem<String>(
                                value: profile.id,
                                child: Text(profile.label),
                              ),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setModalState(
                                () => selectedQualityProfileId = value);

                            if (value ==
                                AppSettingsProvider.customQualityProfileId) {
                              return;
                            }

                            final profile =
                                AppSettingsProvider.profileById(value);
                            if (profile == null) {
                              return;
                            }

                            setModalState(
                                () => selectedPresetTier = profile.tier);

                            () async {
                              final fpsOptions = await cameraProvider
                                  .getSupportedFpsOptionsForPreset(
                                preset: CameraProvider.presetForResolution(
                                  profile.resolution,
                                ),
                              );
                              if (!mounted) {
                                return;
                              }
                              setModalState(() {
                                selectedResolution = profile.resolution;
                                selectedBitrateMbps = profile.bitrateMbps;
                                availableFps = List<int>.from(fpsOptions);
                                if (availableFps.contains(profile.fps)) {
                                  selectedFps = profile.fps;
                                } else {
                                  selectedFps = availableFps.last;
                                  selectedQualityProfileId = AppSettingsProvider
                                      .customQualityProfileId;
                                }
                              });
                            }();
                          },
                        ),
                        const SizedBox(height: 12),
                        if (cameraOptions.isNotEmpty) ...[
                          _buildSettingsLabel('Camera lens'),
                          DropdownButtonFormField<String>(
                            initialValue: cameraOptions.any((camera) =>
                                    camera.name == selectedCameraName)
                                ? selectedCameraName
                                : cameraOptions.first.name,
                            dropdownColor: const Color(0xFF1B1B1B),
                            decoration: _settingsInputDecoration(),
                            items: cameraOptions
                                .map(
                                  (camera) => DropdownMenuItem<String>(
                                    value: camera.name,
                                    child: Text(
                                        cameraProvider.cameraLabel(camera)),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              if (value == null) return;
                              setModalState(() => selectedCameraName = value);
                            },
                          ),
                          const SizedBox(height: 12),
                        ],
                        _buildSettingsLabel('Recording resolution'),
                        DropdownButtonFormField<int>(
                          initialValue: selectedResolution,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: AppSettingsProvider.resolutionOptions.map(
                            (resolution) {
                              final isUnsupported =
                                  unsupportedResolutionPresets.contains(
                                CameraProvider.presetForResolution(
                                  resolution,
                                ),
                              );
                              final label = AppSettingsProvider.resolutionLabel(
                                  resolution);
                              return DropdownMenuItem<int>(
                                value: resolution,
                                enabled: !isUnsupported,
                                child: Text(
                                  isUnsupported
                                      ? '$label (unsupported)'
                                      : label,
                                  style: TextStyle(
                                    color: isUnsupported
                                        ? Colors.white38
                                        : Colors.white,
                                  ),
                                ),
                              );
                            },
                          ).toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setModalState(() {
                              selectedResolution = value;
                              selectedQualityProfileId =
                                  AppSettingsProvider.customQualityProfileId;
                            });

                            () async {
                              final fpsOptions = await cameraProvider
                                  .getSupportedFpsOptionsForPreset(
                                preset:
                                    CameraProvider.presetForResolution(value),
                              );
                              if (!mounted) {
                                return;
                              }
                              setModalState(() {
                                availableFps = List<int>.from(fpsOptions);
                                if (!availableFps.contains(selectedFps)) {
                                  selectedFps = availableFps.last;
                                }
                              });
                            }();
                          },
                        ),
                        if (unsupportedResolutionPresets.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Known unsupported on this device: ${AppSettingsProvider.resolutionOptions.where((resolution) => unsupportedResolutionPresets.contains(CameraProvider.presetForResolution(resolution))).map(AppSettingsProvider.resolutionLabel).join(', ')}',
                            style: const TextStyle(
                              color: Colors.orange,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        _buildSettingsLabel('Frame rate (FPS)'),
                        DropdownButtonFormField<int>(
                          initialValue: selectedFps,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: availableFps
                              .map(
                                (fps) => DropdownMenuItem<int>(
                                  value: fps,
                                  child: Text('$fps FPS'),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setModalState(() {
                              selectedFps = value;
                              selectedQualityProfileId =
                                  AppSettingsProvider.customQualityProfileId;
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildSettingsLabel('Video bitrate'),
                        DropdownButtonFormField<int>(
                          initialValue: selectedBitrateMbps,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: AppSettingsProvider.bitrateOptionsMbps
                              .map(
                                (mbps) => DropdownMenuItem<int>(
                                  value: mbps,
                                  child: Text('$mbps Mbps'),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setModalState(() {
                              selectedBitrateMbps = value;
                              selectedQualityProfileId =
                                  AppSettingsProvider.customQualityProfileId;
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildSettingsLabel('Segment length'),
                        DropdownButtonFormField<int>(
                          initialValue: segmentDurationSeconds,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: AppSettingsProvider
                              .segmentDurationOptionsSeconds
                              .map(
                                (seconds) => DropdownMenuItem<int>(
                                  value: seconds,
                                  child: Text(
                                    AppSettingsProvider.segmentDurationLabel(
                                      seconds,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setModalState(() => segmentDurationSeconds = value);
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildSettingsLabel('Loop buffer size'),
                        DropdownButtonFormField<int>(
                          initialValue: loopSegmentCount,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: AppSettingsProvider.loopSegmentCountOptions
                              .map(
                                (segments) => DropdownMenuItem<int>(
                                  value: segments,
                                  child: Text('$segments segments'),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setModalState(() => loopSegmentCount = value);
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildSettingsLabel('Speed UI refresh'),
                        DropdownButtonFormField<int>(
                          initialValue: speedRefreshMs,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: const [100, 200, 300, 500]
                              .map(
                                (ms) => DropdownMenuItem<int>(
                                  value: ms,
                                  child: Text('$ms ms'),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setModalState(() => speedRefreshMs = value);
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildSettingsLabel('Incident sensitivity'),
                        DropdownButtonFormField<IncidentSensitivity>(
                          initialValue: incidentSensitivity,
                          dropdownColor: const Color(0xFF1B1B1B),
                          decoration: _settingsInputDecoration(),
                          items: IncidentSensitivity.values
                              .map(
                                (sensitivity) =>
                                    DropdownMenuItem<IncidentSensitivity>(
                                  value: sensitivity,
                                  child: Text(AppSettingsProvider
                                      .incidentSensitivityLabel(sensitivity)),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setModalState(() => incidentSensitivity = value);
                          },
                        ),
                        const SizedBox(height: 8),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          activeThumbColor: Colors.blue,
                          activeTrackColor: Colors.blue.withValues(alpha: 0.35),
                          value: audioEnabled,
                          title: const Text(
                            'Record audio',
                            style: TextStyle(color: Colors.white),
                          ),
                          subtitle: const Text(
                            'Disable for lower CPU and storage usage',
                            style: TextStyle(color: Colors.white70),
                          ),
                          onChanged: (value) {
                            setModalState(() => audioEnabled = value);
                          },
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () {
                              Navigator.of(context).pop(
                                _SettingsFormResult(
                                  resolution: selectedResolution,
                                  fps: selectedFps,
                                  bitrateMbps: selectedBitrateMbps,
                                  audioEnabled: audioEnabled,
                                  speedRefreshMs: speedRefreshMs,
                                  cameraName: selectedCameraName,
                                  segmentDurationSeconds:
                                      segmentDurationSeconds,
                                  loopSegmentCount: loopSegmentCount,
                                  incidentSensitivity: incidentSensitivity,
                                ),
                              );
                            },
                            style: ElevatedButton.styleFrom(
                              minimumSize: const Size(double.infinity, 52),
                              backgroundColor: Colors.blue,
                            ),
                            child: const Text(
                              'SAVE SETTINGS',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
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

      if (!mounted) {
        return;
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
        resolutionPreset:
            camera.resolvePresetForRequestedResolution(result.resolution),
        recordingFps: result.fps,
        videoBitrateBps: result.bitrateMbps * 1000 * 1000,
        audioEnabled: result.audioEnabled,
        preferredCameraName: result.cameraName,
        segmentDurationSeconds: result.segmentDurationSeconds,
        maxRollingSegments: result.loopSegmentCount,
      );

      if (applied) {
        await _syncSettingsWithCameraCapabilities(
          settings: settings,
          camera: camera,
        );
      }

      if (!mounted) {
        return;
      }

      final appliedResolution =
          AppSettingsProvider.fromResolutionPreset(camera.resolutionPreset);
      final segmentDurationLabel = AppSettingsProvider.segmentDurationLabel(
        result.segmentDurationSeconds,
      );
      final message = applied
          ? (appliedResolution != result.resolution
              ? 'Requested ${result.resolution}p is not supported on this device. Applied ${appliedResolution}p at ${camera.recordingFps} FPS, ${result.bitrateMbps}Mbps, $segmentDurationLabel, loop ${result.loopSegmentCount} segments'
              : 'Settings applied: ${appliedResolution}p, ${camera.recordingFps} FPS, ${result.bitrateMbps}Mbps, $segmentDurationLabel, loop ${result.loopSegmentCount} segments')
          : (wasRecording
              ? 'Stop recording first to apply camera settings'
              : 'Unable to initialize camera with the selected settings on this device.');

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isApplyingSettings = false;
        });
      }
    }
  }

  Widget _buildActiveProfileBar() {
    return Consumer<AppSettingsProvider>(
      builder: (context, settings, _) {
        final chips = <Widget>[
          if (settings.selectedCameraName.isNotEmpty)
            _buildProfileChip('Cam ${settings.selectedCameraName}'),
          _buildProfileChip('${settings.recordingResolution}p'),
          _buildProfileChip('${settings.recordingFps} FPS'),
          _buildProfileChip('${settings.videoBitrateMbps} Mbps'),
          _buildProfileChip(settings.audioEnabled ? 'Audio On' : 'Audio Off'),
          _buildProfileChip(
              '${AppSettingsProvider.segmentDurationLabel(settings.segmentDurationSeconds)} x ${settings.loopSegmentCount} loop'),
          _buildProfileChip(
              'Incident ${settings.incidentSensitivity.name.toUpperCase()}'),
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
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, index) => chips[index],
                ),
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

  InputDecoration _settingsInputDecoration() {
    return InputDecoration(
      filled: true,
      fillColor: const Color(0xFF1B1B1B),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _buildSettingsLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 13,
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
        final portraitAspectRatio =
            safeAspectRatio > 1 ? (1 / safeAspectRatio) : safeAspectRatio;

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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                    ],
                  ),
                ),
              ),
          ],
        );
      },
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
                    final duration = snapshot.data ?? Duration.zero;
                    final hours = duration.inHours;
                    final minutes = duration.inMinutes.remainder(60);
                    final seconds = duration.inSeconds.remainder(60);
                    final formattedTime =
                        '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';

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
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: valueStyle,
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
          Consumer3<CameraProvider, TelemetryProvider, AppSettingsProvider>(
            builder: (context, camera, telemetry, settings, _) {
              _handleIncidentAutoLock(camera: camera, telemetry: telemetry);
              final selectedPreset = CameraProvider.presetForResolution(
                settings.recordingResolution,
              );
              final resolvedPreset = camera.resolvePresetForRequestedResolution(
                settings.recordingResolution,
              );
              final isPresetUnsupported = !camera.isRecording &&
                  camera.knownUnsupportedResolutionPresets.contains(
                    selectedPreset,
                  );
              final willAutoFallback =
                  isPresetUnsupported && resolvedPreset != selectedPreset;
              final supportedResolutions = AppSettingsProvider.resolutionOptions
                  .where(
                    (resolution) =>
                        !camera.knownUnsupportedResolutionPresets.contains(
                      CameraProvider.presetForResolution(resolution),
                    ),
                  )
                  .toList();
              final suggestedResolution = supportedResolutions.isEmpty
                  ? null
                  : supportedResolutions.last;

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton(
                    onPressed: _isApplyingSettings
                        ? null
                        : () async {
                            final messenger = ScaffoldMessenger.of(context);
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
                      backgroundColor:
                          camera.isRecording ? Colors.red : Colors.blue,
                      disabledBackgroundColor: Colors.grey.shade800,
                      minimumSize: const Size(double.infinity, 52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      _isApplyingSettings
                          ? 'APPLYING SETTINGS...'
                          : (camera.isRecording
                              ? 'STOP RECORDING'
                              : 'START RECORDING'),
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
          const SizedBox(height: 8),
          Consumer<CameraProvider>(
            builder: (context, camera, _) {
              return Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isApplyingSettings
                          ? null
                          : (camera.isRecording
                              ? () {
                                  unawaited(_handleBackPressWhileRecording());
                                }
                              : () async {
                                  await _openRideHistory(camera: camera);
                                }),
                      icon: const Icon(Icons.video_library_outlined,
                          color: Colors.blue),
                      label: const Text(
                        'HISTORY',
                        style: TextStyle(fontSize: 14, color: Colors.blue),
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
                      onPressed: camera.isRecording
                          ? () {
                              camera.markIncident(
                                protectPastSegments: 2,
                                protectCurrentSegment: true,
                                reason: 'manual-emergency',
                              );
                              _showInAppNotice(
                                'Emergency lock enabled (${camera.lockedSegmentCount})',
                              );
                            }
                          : null,
                      icon: const Icon(Icons.warning_amber_rounded,
                          color: Colors.orange),
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
    WidgetsBinding.instance.removeObserver(this);
    _blackoutExitHoldTimer?.cancel();
    _inAppNoticeTimer?.cancel();
    _recordingTimerSubscription?.cancel();
    _backgroundEventSubscription?.cancel();
    _pipModeSubscription?.cancel();
    _deviceStatusTimer?.cancel();
    _backgroundRecordingService.stopForegroundRecording();
    super.dispose();
  }
}

class _SettingsFormResult {
  const _SettingsFormResult({
    required this.resolution,
    required this.fps,
    required this.bitrateMbps,
    required this.audioEnabled,
    required this.speedRefreshMs,
    required this.cameraName,
    required this.segmentDurationSeconds,
    required this.loopSegmentCount,
    required this.incidentSensitivity,
  });

  final int resolution;
  final int fps;
  final int bitrateMbps;
  final bool audioEnabled;
  final int speedRefreshMs;
  final String cameraName;
  final int segmentDurationSeconds;
  final int loopSegmentCount;
  final IncidentSensitivity incidentSensitivity;
}

enum _PermissionRecoveryAction { dismiss, retryRequest, openSettings }

enum _StartPreflightStatus { ok, warning, failed }

class _StartPreflightCheck {
  const _StartPreflightCheck({
    required this.title,
    required this.detail,
    required this.status,
    required this.isBlocking,
  });

  final String title;
  final String detail;
  final _StartPreflightStatus status;
  final bool isBlocking;
}
