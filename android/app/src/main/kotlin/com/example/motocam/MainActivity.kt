package com.example.motocam

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.media.MediaScannerConnection
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
                    else -> result.notImplemented()
                }
            }
    }
}