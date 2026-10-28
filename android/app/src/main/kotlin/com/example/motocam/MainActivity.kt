package com.example.motocam

import android.Manifest
import android.app.PictureInPictureParams
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.PowerManager
import android.provider.Settings
import android.provider.MediaStore
import android.util.Log
import android.util.Rational
import android.view.WindowManager
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleRegistry
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.motocam/pip"
    private val MEDIA_CHANNEL = "com.example.motocam/media"
    private val DEVICE_STATUS_CHANNEL = "com.example.motocam/device_status"
    private val BACKGROUND_RECORDING_CHANNEL = "com.example.motocam/background_recording"
    private fun internalBroadcastPermission(): String =
        "$packageName.permission.INTERNAL_BROADCAST"
    private var pipMethodChannel: MethodChannel? = null
    private var legacyRecordingsAccess: LegacyRecordingsAccess? = null
    private var galleryCopies: GalleryCopies? = null

    // Every startActivityForResult of this activity is answered through
    // this dispatcher, by request code (see ActivityRequestCodes).
    private val activityResults = ActivityResultDispatcher()
    private var backgroundRecordingMethodChannel: MethodChannel? = null
    private var isRecordingActive = false

    // Wall-clock start time implied by the last elapsed value sent to the
    // foreground service. The notification renders the elapsed time with a
    // chronometer, so updates are only forwarded when Dart's clock drifts.
    private var foregroundStartWallMs = 0L

    // True only after the foreground service was actually asked to start for
    // the current recording. isRecordingActive alone also covers a recording
    // whose service could not start, which must not get update intents (each
    // would create a plain, non-foreground service).
    private var isForegroundServiceStarted = false

    // Rider's keep-screen-on choice for the current recording (Dart's
    // setKeepScreenOn). FLAG_KEEP_SCREEN_ON is set only while it and
    // isRecordingActive are both true; see applyKeepScreenOn.
    private var keepScreenOnRequested = false

    // ---- Camera lifecycle hold (F004) ----
    //
    // camera_android_camerax (0.7.2) binds every CameraX use case, and
    // observes its LiveData, with the attached activity as LifecycleOwner
    // (ProxyApiRegistrar.getLifecycleOwner returns the activity). CameraX
    // closes the camera when that lifecycle drops below STARTED, so with
    // FlutterActivity's own lifecycle every screen timeout, power-button
    // lock or Home press without PiP stopped capture, although the
    // camera-typed foreground service kept running.
    //
    // MainActivity therefore exposes recordingLifecycle as its lifecycle. It
    // mirrors FlutterActivity's registry, except that while the hold is
    // engaged (a recording whose foreground service was started) it does
    // not drop below STARTED, so CameraX keeps the camera open with the
    // screen off. ON_DESTROY is always forwarded, so the hold never outlives
    // the activity. FlutterActivity dispatches its own events to its private
    // registry, so only external callers see the mirror: the engine's
    // plugin binding (FlutterActivityAndFragmentDelegate passes
    // host.getLifecycle() to every plugin) and CameraX through the camera
    // plugin. Of the app's plugins only camera_android_camerax observes the
    // activity lifecycle. This relies on the camera plugin binding to the
    // activity lifecycle: re-check it on every camera plugin upgrade.
    // Everything here runs on the main thread.
    private val recordingLifecycle = LifecycleRegistry(this)
    private var isCameraHoldEngaged = false

    // Token of the engaged hold, sent with ACTION_START and echoed by the
    // service when it stops, so a late stop of an earlier service instance
    // cannot release a newer recording's hold.
    private var cameraHoldToken = 0L
    private var nextCameraHoldToken = 1L

    init {
        super.lifecycle.addObserver(
            LifecycleEventObserver { _, _ -> syncRecordingLifecycle() },
        )
    }

    /**
     * The lifecycle plugins and CameraX see: FlutterActivity's lifecycle,
     * held at STARTED while a recording's foreground service runs (see
     * [recordingLifecycle]).
     */
    override val lifecycle: Lifecycle
        get() = recordingLifecycle

    /**
     * Moves [recordingLifecycle] to FlutterActivity's real state, except
     * that an engaged hold keeps it at STARTED instead of letting it fall to
     * CREATED. The hold never raises it: if it is not STARTED already (the
     * activity was stopped when the hold was engaged) it follows the real
     * state. DESTROYED is always forwarded.
     */
    private fun syncRecordingLifecycle() {
        val real = super.lifecycle.currentState
        val target = if (
            isCameraHoldEngaged &&
            real == Lifecycle.State.CREATED &&
            recordingLifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
        ) {
            Lifecycle.State.STARTED
        } else {
            real
        }
        if (recordingLifecycle.currentState != target) {
            recordingLifecycle.currentState = target
        }
    }

    private fun engageCameraHold(token: Long) {
        cameraHoldToken = token
        isCameraHoldEngaged = true
        syncRecordingLifecycle()
    }

    /**
     * Releases the hold. When the activity is stopped (screen off, app in
     * the background) the mirrored lifecycle falls to CREATED and CameraX
     * closes the camera.
     */
    private fun releaseCameraHold() {
        cameraHoldToken = 0L
        if (!isCameraHoldEngaged) {
            return
        }
        isCameraHoldEngaged = false
        syncRecordingLifecycle()
    }

    private fun applyKeepScreenOn() {
        if (isRecordingActive && keepScreenOnRequested) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    private val backgroundStopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                BackgroundRecordingService.ACTION_STOP_REQUESTED -> {
                    backgroundRecordingMethodChannel?.invokeMethod("onStopRequested", null)
                }
                BackgroundRecordingService.ACTION_FOREGROUND_STOPPED -> {
                    // The service stopped on its own (start failure, Stop
                    // timeout, system stop): it no longer backs the camera,
                    // so the hold ends with it. Stopping the recording is
                    // up to Dart; the keep-screen-on flag stays. Dart is
                    // told, so the rider is warned that the recording is no
                    // longer protected.
                    val token = intent.getLongExtra(
                        BackgroundRecordingService.EXTRA_HOLD_TOKEN,
                        0L,
                    )
                    if (token != 0L && token == cameraHoldToken) {
                        isForegroundServiceStarted = false
                        releaseCameraHold()
                        if (isRecordingActive) {
                            try {
                                backgroundRecordingMethodChannel
                                    ?.invokeMethod("onForegroundStopped", null)
                            } catch (e: Exception) {
                                Log.e("MotoCam", "onForegroundStopped failed", e)
                            }
                        }
                    }
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        RideSigner.register(flutterEngine.dartExecutor.binaryMessenger)

        if (legacyRecordingsAccess == null) {
            val access = LegacyRecordingsAccess(this)
            legacyRecordingsAccess = access
            activityResults.register(LegacyRecordingsAccess.REQUEST_PICK_TREE) { resultCode, data ->
                access.onTreePicked(resultCode, data)
            }
        }
        legacyRecordingsAccess?.register(flutterEngine.dartExecutor.binaryMessenger)

        if (galleryCopies == null) {
            val copies = GalleryCopies(this)
            galleryCopies = copies
            activityResults.register(GalleryCopies.REQUEST_DELETE) { resultCode, _ ->
                copies.onDeleteRequestResult(resultCode)
            }
        }
        galleryCopies?.register(flutterEngine.dartExecutor.binaryMessenger)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_STATUS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getBatteryStatus" -> {
                        result.success(readBatteryStatus())
                    }
                    else -> result.notImplemented()
                }
            }

        backgroundRecordingMethodChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKGROUND_RECORDING_CHANNEL)
        backgroundRecordingMethodChannel
            ?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForegroundRecording" -> {
                        isRecordingActive = true
                        applyKeepScreenOn()
                        val elapsedMs = call.argument<Number>("elapsedMs")?.toLong() ?: 0L
                        // On API 34+ a foreground service must start with at
                        // least one type whose permission is granted; starting
                        // without one would crash the app inside the service.
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
                            BackgroundRecordingService.grantedForegroundServiceTypes(this) == 0
                        ) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val holdToken = nextCameraHoldToken++
                        val serviceIntent = Intent(this, BackgroundRecordingService::class.java).apply {
                            action = BackgroundRecordingService.ACTION_START
                            putExtra(BackgroundRecordingService.EXTRA_ELAPSED_MS, elapsedMs)
                            putExtra(BackgroundRecordingService.EXTRA_HOLD_TOKEN, holdToken)
                        }
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(serviceIntent)
                            } else {
                                startService(serviceIntent)
                            }
                            foregroundStartWallMs = System.currentTimeMillis() - elapsedMs
                            isForegroundServiceStarted = true
                            // Only once the service start was accepted: a
                            // refused or failed start leaves the hold off.
                            engageCameraHold(holdToken)
                            result.success(true)
                        } catch (e: Exception) {
                            // e.g. ForegroundServiceStartNotAllowedException (API 31+)
                            // when the app is not in the foreground.
                            Log.e("MotoCam", "startForegroundService failed", e)
                            result.success(false)
                        }
                    }
                    "updateForegroundRecording" -> {
                        val elapsedMs = call.argument<Number>("elapsedMs")?.toLong() ?: 0L
                        val impliedStartWallMs = System.currentTimeMillis() - elapsedMs
                        if (!isRecordingActive ||
                            !isForegroundServiceStarted ||
                            Math.abs(impliedStartWallMs - foregroundStartWallMs) <= 2000L
                        ) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        val serviceIntent = Intent(this, BackgroundRecordingService::class.java).apply {
                            action = BackgroundRecordingService.ACTION_UPDATE
                            putExtra(BackgroundRecordingService.EXTRA_ELAPSED_MS, elapsedMs)
                        }
                        try {
                            startService(serviceIntent)
                            foregroundStartWallMs = impliedStartWallMs
                            result.success(true)
                        } catch (_: Exception) {
                            // Background start restrictions (API 26+).
                            result.success(false)
                        }
                    }
                    "stopForegroundRecording" -> {
                        isRecordingActive = false
                        isForegroundServiceStarted = false
                        keepScreenOnRequested = false
                        applyKeepScreenOn()
                        releaseCameraHold()
                        stopBackgroundRecordingService()
                        result.success(true)
                    }
                    "releaseCameraHold" -> {
                        // Capture has stopped; the service and wake lock stay
                        // up until stopForegroundRecording, while the ride is
                        // saved, but the camera no longer needs to stay open.
                        releaseCameraHold()
                        result.success(true)
                    }
                    "setKeepScreenOn" -> {
                        keepScreenOnRequested = call.argument<Boolean>("enabled") ?: false
                        applyKeepScreenOn()
                        result.success(true)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(powerManager.isIgnoringBatteryOptimizations(packageName))
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                            result.success(true)
                            return@setMethodCallHandler
                        }

                        try {
                            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        
        pipMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        pipMethodChannel
            ?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "enterPipMode" -> {
                        if (isPipSupported()) {
                            val params = PictureInPictureParams.Builder()
                                .setAspectRatio(Rational(9, 16))
                                .build()
                            // false when the system refuses PiP, for example
                            // when the rider has turned PiP off for the app.
                            val entered = try {
                                enterPictureInPictureMode(params)
                            } catch (_: Exception) {
                                false
                            }
                            result.success(entered)
                        } else {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAvailableStorageBytes" -> {
                        // Free bytes on the volume holding the recordings
                        // directory (Dart's low-storage check before START
                        // and at each segment roll).
                        val path = call.argument<String>("path")
                        try {
                            val target = if (path.isNullOrBlank()) filesDir.path else path
                            result.success(android.os.StatFs(target).availableBytes)
                        } catch (e: Exception) {
                            result.error("STORAGE_QUERY_FAILED", e.message, null)
                        }
                    }
                    "exportVideoToGallery" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val displayName = call.argument<String>("displayName")
                        val relativePath = call.argument<String>("relativePath") ?: "Movies/MotoCam/Videos"
                        // Optional (default false): link a finished copy of
                        // the same name and size instead of copying again.
                        val reuseExisting = call.argument<Boolean>("reuseExisting") ?: false

                        if (sourcePath.isNullOrBlank() || displayName.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "sourcePath and displayName are required", null)
                            return@setMethodCallHandler
                        }

                        // Below API 29 the public Movies directory is written
                        // directly, which needs WRITE_EXTERNAL_STORAGE.
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
                            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            result.error("PERMISSION_DENIED", "Storage permission not granted", null)
                            return@setMethodCallHandler
                        }

                        Thread {
                            try {
                                val sourceFile = File(sourcePath)
                                if (!sourceFile.exists()) {
                                    runOnUiThread {
                                        result.error("SOURCE_NOT_FOUND", "Source file not found", null)
                                    }
                                    return@Thread
                                }

                                val existingUri = if (reuseExisting) {
                                    findExistingGalleryCopy(sourceFile, displayName, relativePath)
                                } else {
                                    null
                                }
                                val exportedPath = if (existingUri != null) {
                                    existingUri
                                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                    val values = ContentValues().apply {
                                        put(MediaStore.Video.Media.DISPLAY_NAME, displayName)
                                        put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                                        put(MediaStore.Video.Media.RELATIVE_PATH, relativePath)
                                        put(MediaStore.Video.Media.IS_PENDING, 1)
                                    }

                                    val resolver = contentResolver
                                    val collection = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                                    val itemUri = resolver.insert(collection, values)
                                        ?: throw IllegalStateException("Failed to create MediaStore item")

                                    try {
                                        resolver.openOutputStream(itemUri)?.use { outStream ->
                                            sourceFile.inputStream().use { inStream ->
                                                inStream.copyTo(outStream)
                                            }
                                        } ?: throw IllegalStateException("Failed to open output stream")

                                        values.clear()
                                        values.put(MediaStore.Video.Media.IS_PENDING, 0)
                                        resolver.update(itemUri, values, null, null)
                                    } catch (e: Exception) {
                                        // Do not leave a partial pending item behind.
                                        try {
                                            resolver.delete(itemUri, null, null)
                                        } catch (_: Exception) {
                                        }
                                        throw e
                                    }
                                    itemUri.toString()
                                } else {
                                    // Same relative path as the MediaStore branch,
                                    // resolved against the shared storage root.
                                    @Suppress("DEPRECATION")
                                    val storageRoot = Environment.getExternalStorageDirectory()
                                    val targetDir = File(storageRoot, relativePath)
                                    if (!targetDir.exists()) {
                                        targetDir.mkdirs()
                                    }

                                    // Never over another file: a name in use
                                    // gets a numbered suffix.
                                    val targetFile = uniqueTarget(targetDir, displayName)
                                    try {
                                        sourceFile.inputStream().use { inStream ->
                                            FileOutputStream(targetFile).use { outStream ->
                                                inStream.copyTo(outStream)
                                                outStream.fd.sync()
                                            }
                                        }
                                        // Only the public copy is scanned, never
                                        // the private source; the scan gives the
                                        // copy's content URI.
                                        scanForUri(targetFile)
                                            ?: throw IllegalStateException("Media scan gave no URI")
                                    } catch (e: Exception) {
                                        targetFile.delete()
                                        throw e
                                    }
                                }

                                runOnUiThread {
                                    result.success(exportedPath)
                                }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("EXPORT_FAILED", e.message, null)
                                }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * The content URI of a finished gallery copy of [source] named
     * [displayName] in [relativePath] with the same size (one a killed
     * process made before Dart could record it), or null. On API 29+ the
     * query sees only media this app inserted; below it, the public file is
     * checked and scanned.
     */
    private fun findExistingGalleryCopy(
        source: File,
        displayName: String,
        relativePath: String,
    ): String? {
        val size = source.length()
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val collection = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                val folder = relativePath.trimEnd('/') + "/"
                contentResolver.query(
                    collection,
                    arrayOf(MediaStore.Video.Media._ID, MediaStore.Video.Media.SIZE),
                    "${MediaStore.Video.Media.DISPLAY_NAME}=? AND " +
                        "${MediaStore.Video.Media.RELATIVE_PATH}=?",
                    arrayOf(displayName, folder),
                    null,
                )?.use { cursor ->
                    var found: String? = null
                    while (found == null && cursor.moveToNext()) {
                        if (cursor.getLong(1) == size) {
                            found = ContentUris.withAppendedId(collection, cursor.getLong(0))
                                .toString()
                        }
                    }
                    found
                }
            } else {
                @Suppress("DEPRECATION")
                val folder = File(Environment.getExternalStorageDirectory(), relativePath)
                val target = File(folder, displayName)
                if (target.isFile && target.length() == size) scanForUri(target) else null
            }
        } catch (e: Exception) {
            Log.w("MotoCam", "existing gallery copy lookup failed", e)
            null
        }
    }

    /** [displayName] in [dir], or `name_1.ext`, `name_2.ext`, ... if taken. */
    private fun uniqueTarget(dir: File, displayName: String): File {
        val dot = displayName.lastIndexOf('.')
        val base = if (dot > 0) displayName.substring(0, dot) else displayName
        val extension = if (dot > 0) displayName.substring(dot) else ""
        var candidate = File(dir, displayName)
        var suffix = 1
        while (candidate.exists()) {
            candidate = File(dir, "${base}_$suffix$extension")
            suffix++
        }
        return candidate
    }

    /**
     * Scans [file] (a public gallery copy, never a private file) and waits
     * up to 15 s for its MediaStore content URI. Call off the main thread.
     */
    private fun scanForUri(file: File): String? {
        val latch = CountDownLatch(1)
        var scanned: Uri? = null
        MediaScannerConnection.scanFile(
            this,
            arrayOf(file.absolutePath),
            arrayOf("video/mp4"),
        ) { _, uri ->
            scanned = uri
            latch.countDown()
        }
        latch.await(15, TimeUnit.SECONDS)
        return scanned?.toString()
    }

    private fun readBatteryStatus(): Map<String, Any?> {
        val batteryIntent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val batteryLevelPercent = batteryIntent
            ?.let {
                val level = it.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = it.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                if (level >= 0 && scale > 0) {
                    ((level * 100.0) / scale).toInt()
                } else {
                    null
                }
            }

        val batteryTemperatureC = batteryIntent
            ?.let {
                val tempTenthsC = it.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
                // Signed tenths of a degree C: 0 and below are valid readings.
                if (tempTenthsC != Int.MIN_VALUE) {
                    tempTenthsC / 10.0
                } else {
                    null
                }
            }

        val thermalStatus = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            thermalStatusLabel(powerManager.currentThermalStatus)
        } else {
            "unsupported"
        }

        return mapOf(
            "batteryLevelPercent" to batteryLevelPercent,
            "batteryTemperatureC" to batteryTemperatureC,
            "thermalStatus" to thermalStatus,
            // Optional key: lets Dart request legacy storage permission for
            // gallery export only on Android 9 and lower.
            "sdkInt" to Build.VERSION.SDK_INT,
        )
    }

    private fun thermalStatusLabel(status: Int): String {
        return when (status) {
            PowerManager.THERMAL_STATUS_NONE -> "none"
            PowerManager.THERMAL_STATUS_LIGHT -> "light"
            PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
            PowerManager.THERMAL_STATUS_SEVERE -> "severe"
            PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
            PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
            PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
            else -> "unknown"
        }
    }

    private fun isPipSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    /**
     * Stops the recording foreground service. ACTION_STOP is queued behind any
     * pending ACTION_START so startForeground always runs first; stopService
     * is the fallback when a background start restriction rejects startService.
     */
    private fun stopBackgroundRecordingService() {
        val serviceIntent = Intent(this, BackgroundRecordingService::class.java).apply {
            action = BackgroundRecordingService.ACTION_STOP
        }
        try {
            startService(serviceIntent)
        } catch (_: Exception) {
            stopService(Intent(this, BackgroundRecordingService::class.java))
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipMethodChannel?.invokeMethod("onPipModeChanged", isInPictureInPictureMode)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        maybeEnterRecordingPip()
    }

    override fun onPause() {
        super.onPause()
        maybeEnterRecordingPip()
    }

    private fun maybeEnterRecordingPip() {
        if (!isRecordingActive) {
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        if (isInPictureInPictureMode) {
            return
        }

        try {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(9, 16))
                .build()
            enterPictureInPictureMode(params)
        } catch (_: Exception) {
        }
    }

    // FlutterActivity is not a ComponentActivity, so there is no Activity
    // Result API: results come here and go to the handler of their code.
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // Always first: plugins receive their results through FlutterActivity.
        super.onActivityResult(requestCode, resultCode, data)
        activityResults.dispatch(requestCode, resultCode, data)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Registered for the whole activity lifetime (not onStart/onStop) so a
        // Stop tapped in the notification while the screen is off or the app
        // is in the background still reaches Dart.
        val filter = IntentFilter(BackgroundRecordingService.ACTION_STOP_REQUESTED).apply {
            addAction(BackgroundRecordingService.ACTION_FOREGROUND_STOPPED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(
                backgroundStopReceiver,
                filter,
                internalBroadcastPermission(),
                null,
                RECEIVER_NOT_EXPORTED,
            )
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(
                backgroundStopReceiver,
                filter,
                internalBroadcastPermission(),
                null,
            )
        }
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(backgroundStopReceiver)
        } catch (_: IllegalArgumentException) {
        }
        // The Flutter engine and the camera go away with this activity, so the
        // foreground service (wake lock and ongoing notification) must not
        // outlive it. Releasing the hold first lets CameraX close the camera
        // (ON_STOP) before the engine detaches; ON_DESTROY follows from
        // super.onDestroy either way.
        legacyRecordingsAccess?.dispose()
        legacyRecordingsAccess = null
        galleryCopies?.dispose()
        galleryCopies = null
        isRecordingActive = false
        keepScreenOnRequested = false
        applyKeepScreenOn()
        releaseCameraHold()
        if (isForegroundServiceStarted) {
            isForegroundServiceStarted = false
            stopBackgroundRecordingService()
        }
        super.onDestroy()
    }
}