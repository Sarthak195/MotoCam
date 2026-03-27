package com.example.motocam

import android.app.PictureInPictureParams
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.Settings
import android.provider.MediaStore
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.motocam/pip"
    private val MEDIA_CHANNEL = "com.example.motocam/media"
    private val BACKGROUND_RECORDING_CHANNEL = "com.example.motocam/background_recording"
    private var pipMethodChannel: MethodChannel? = null
    private var backgroundRecordingMethodChannel: MethodChannel? = null
    private var isRecordingActive = false

    private val backgroundStopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == BackgroundRecordingService.ACTION_STOP_REQUESTED) {
                backgroundRecordingMethodChannel?.invokeMethod("onStopRequested", null)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        backgroundRecordingMethodChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKGROUND_RECORDING_CHANNEL)
        backgroundRecordingMethodChannel
            ?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForegroundRecording" -> {
                        isRecordingActive = true
                        val elapsedMs = call.argument<Number>("elapsedMs")?.toLong() ?: 0L
                        val serviceIntent = Intent(this, BackgroundRecordingService::class.java).apply {
                            action = BackgroundRecordingService.ACTION_START
                            putExtra(BackgroundRecordingService.EXTRA_ELAPSED_MS, elapsedMs)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(serviceIntent)
                        } else {
                            startService(serviceIntent)
                        }
                        result.success(true)
                    }
                    "updateForegroundRecording" -> {
                        val elapsedMs = call.argument<Number>("elapsedMs")?.toLong() ?: 0L
                        val serviceIntent = Intent(this, BackgroundRecordingService::class.java).apply {
                            action = BackgroundRecordingService.ACTION_UPDATE
                            putExtra(BackgroundRecordingService.EXTRA_ELAPSED_MS, elapsedMs)
                        }
                        startService(serviceIntent)
                        result.success(true)
                    }
                    "stopForegroundRecording" -> {
                        isRecordingActive = false
                        val serviceIntent = Intent(this, BackgroundRecordingService::class.java).apply {
                            action = BackgroundRecordingService.ACTION_STOP
                        }
                        startService(serviceIntent)
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
                        result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                    }
                    "enterPipMode" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val params = PictureInPictureParams.Builder()
                                .setAspectRatio(Rational(9, 16))
                                .build()
                            enterPictureInPictureMode(params)
                            result.success(true)
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

                                    resolver.openOutputStream(itemUri)?.use { outStream ->
                                        sourceFile.inputStream().use { inStream ->
                                            inStream.copyTo(outStream)
                                        }
                                    } ?: throw IllegalStateException("Failed to open output stream")

                                    values.clear()
                                    values.put(MediaStore.Video.Media.IS_PENDING, 0)
                                    resolver.update(itemUri, values, null, null)
                                    itemUri.toString()
                                } else {
                                    val moviesDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
                                    val targetDir = File(moviesDir, "MotoCam/Videos")
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

    override fun onStart() {
        super.onStart()
        val filter = IntentFilter(BackgroundRecordingService.ACTION_STOP_REQUESTED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(backgroundStopReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(backgroundStopReceiver, filter)
        }
    }

    override fun onStop() {
        super.onStop()
        try {
            unregisterReceiver(backgroundStopReceiver)
        } catch (_: IllegalArgumentException) {
        }
    }
}