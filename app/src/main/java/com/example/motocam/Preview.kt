package com.example.motocam

import androidx.compose.runtime.Composable
import androidx.compose.ui.tooling.preview.Preview

@Preview(showBackground = true)
@Composable
fun CameraScreenPreview() {
    CameraScreen(speed = 10.0, isRecording = true, onVideoCaptureReady = {})
}