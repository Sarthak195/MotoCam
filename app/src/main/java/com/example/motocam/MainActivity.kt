package com.example.motocam

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.view.View
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalInspectionMode
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import java.io.File

class MainActivity : ComponentActivity(), LocationListener {

    private lateinit var locationManager: LocationManager
    private var isRecording = false
    private val speedLimit = 1.0
    private var isRecordingState by mutableStateOf(false)


    private var videoCapture: VideoCapture<Recorder>? = null
    private var recording: Recording? = null

    private var currentSpeed by mutableStateOf(0.0)

    private val permissionLauncher =
        registerForActivityResult(
            ActivityResultContracts.RequestMultiplePermissions()
        ) { permissions ->
            if (permissions[Manifest.permission.ACCESS_FINE_LOCATION] == true) {
                startLocationUpdates()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        permissionLauncher.launch(
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.CAMERA,
                Manifest.permission.RECORD_AUDIO
            )
        )

        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    CameraScreen(
                        speed = currentSpeed,
                        isRecording = isRecordingState,
                        onVideoCaptureReady = { capture ->
                            videoCapture = capture
                        }
                    )
                }
            }
        }
    }

    private fun startLocationUpdates() {
        locationManager =
            getSystemService(Context.LOCATION_SERVICE) as LocationManager

        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) return

        locationManager.requestLocationUpdates(
            LocationManager.GPS_PROVIDER,
            3000L,   // 3 seconds interval (battery friendly)
            5f,      // 5 meters distance
            this
        )
    }

    override fun onLocationChanged(location: Location) {
        val speedKmph = location.speed * 3.6
        currentSpeed = speedKmph

        if (speedKmph > speedLimit && !isRecording) {
            startRecording()
        } else if (speedKmph <= speedLimit && isRecording) {
            stopRecording()
        }
    }

    private fun startRecording() {
        val capture = videoCapture ?: return

        val file = File(
            getExternalFilesDir(null),
            "${System.currentTimeMillis()}.mp4"
        )

        val options = FileOutputOptions.Builder(file).build()

        val prepare = capture.output
            .prepareRecording(this, options)

        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO)
            == PackageManager.PERMISSION_GRANTED
        ) {
            prepare.withAudioEnabled()
        }

        recording = prepare.start(
            ContextCompat.getMainExecutor(this)
        ) {}

        isRecording = true
        isRecordingState = true


    }

    private fun stopRecording() {
        recording?.stop()
        recording = null
        isRecording = false
        isRecordingState = false

    }
}

@Composable
fun CameraScreen(
    speed: Double,

    isRecording: Boolean,
    onVideoCaptureReady: (VideoCapture<Recorder>) -> Unit

) {
    val context = LocalContext.current
    // Check if we are in a preview environment
    val isInPreview = LocalInspectionMode.current

    Box(modifier = Modifier.fillMaxSize()) {

        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                if (isInPreview) {
                    // In preview mode, return a simple placeholder View
                    FrameLayout(ctx).apply {
                        // Optionally, add a Text or other composable here to indicate it's a preview
                        // For instance: addView(TextView(ctx).apply { text = "Camera Preview Placeholder" })
                    }
                } else {
                    // In actual runtime, initialize CameraX
                    val previewView = PreviewView(ctx)

                    val cameraProviderFuture =
                        ProcessCameraProvider.getInstance(ctx)

                    cameraProviderFuture.addListener({
                        val cameraProvider = cameraProviderFuture.get()

                        val preview = Preview.Builder().build()
                        preview.setSurfaceProvider(previewView.surfaceProvider)

                        val recorder = Recorder.Builder()
                            .setQualitySelector(
                                QualitySelector.from(Quality.HD)
                            )
                            .build()

                        val capture = VideoCapture.withOutput(recorder)

                        onVideoCaptureReady(capture)

                        cameraProvider.unbindAll()
                        cameraProvider.bindToLifecycle(
                            context as ComponentActivity,
                            CameraSelector.DEFAULT_BACK_CAMERA,
                            preview,
                            capture
                        )
                    }, ContextCompat.getMainExecutor(ctx))

                    previewView
                }
            }
        )

        // Speed Overlay
        Text(
            text = "${speed.toInt()} km/h",
            color = Color.White,
            fontSize = 28.sp,
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(16.dp)
        )
        if (isRecording) {
            Text(
                text = "● REC",
                color = Color.Red,
                fontSize = 22.sp,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(16.dp)
            )
        }
    }
}
