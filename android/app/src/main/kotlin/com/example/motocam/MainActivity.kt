package com.example.motocam

import android.app.PictureInPictureParams
import android.content.ContentValues
import android.content.res.Configuration
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
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
}