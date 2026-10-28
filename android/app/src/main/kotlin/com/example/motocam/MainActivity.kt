package com.example.motocam

import android.Manifest
import android.app.PictureInPictureParams
import android.content.BroadcastReceiver
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
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.motocam/pip"
    private val MEDIA_CHANNEL = "com.example.motocam/media"
    private val DEVICE_STATUS_CHANNEL = "com.example.motocam/device_status"
    private val BACKGROUND_RECORDING_CHANNEL = "com.example.motocam/background_recording"
    private fun internalBroadcastPermission(): String =
        "$packageName.permission.INTERNAL_BROADCAST"
    private var pipMethodChannel: MethodChannel? = null
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

    private val backgroundStopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == BackgroundRecordingService.ACTION_STOP_REQUESTED) {
                backgroundRecordingMethodChannel?.invokeMethod("onStopRequested", null)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
                        val serviceIntent = Intent(this, BackgroundRecordingService::class.java).apply {
                            action = BackgroundRecordingService.ACTION_START
                            putExtra(BackgroundRecordingService.EXTRA_ELAPSED_MS, elapsedMs)
                        }
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(serviceIntent)
                            } else {
                                startService(serviceIntent)
                            }
                            foregroundStartWallMs = System.currentTimeMillis() - elapsedMs
                            isForegroundServiceStarted = true
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
                        stopBackgroundRecordingService()
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
                    "isPipSupported" -> {
                        result.success(isPipSupported())
                    }
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
                    "scanMediaFile" -> {
                        val path = call.argument<String>("path")
                        if (path != null) {
                            MediaScannerConnection.scanFile(
                                this,
                                arrayOf(path),
                                null
                            ) { _, _ ->
                                result.success(true)
                            }
                        } else {
                            result.error("INVALID_ARGS", "Path cannot be null", null)
                        }
                    }
                    "exportVideoToGallery" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val displayName = call.argument<String>("displayName")
                        val relativePath = call.argument<String>("relativePath") ?: "Movies/MotoCam/Videos"

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

                                val exportedPath = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
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

                                    val targetFile = File(targetDir, displayName)
                                    sourceFile.inputStream().use { inStream ->
                                        FileOutputStream(targetFile).use { outStream ->
                                            inStream.copyTo(outStream)
                                        }
                                    }

                                    MediaScannerConnection.scanFile(
                                        this,
                                        arrayOf(targetFile.absolutePath),
                                        null,
                                        null
                                    )
                                    targetFile.absolutePath
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Registered for the whole activity lifetime (not onStart/onStop) so a
        // Stop tapped in the notification while the screen is off or the app
        // is in the background still reaches Dart.
        val filter = IntentFilter(BackgroundRecordingService.ACTION_STOP_REQUESTED)
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
        // outlive it.
        isRecordingActive = false
        if (isForegroundServiceStarted) {
            isForegroundServiceStarted = false
            stopBackgroundRecordingService()
        }
        super.onDestroy()
    }
}