package com.example.motocam

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

class BackgroundRecordingService : Service() {
    companion object {
        const val CHANNEL_ID = "motocam_recording_channel"
        const val NOTIFICATION_ID = 4001

        const val ACTION_START = "com.example.motocam.action.START_RECORDING_FOREGROUND"
        const val ACTION_UPDATE = "com.example.motocam.action.UPDATE_RECORDING_FOREGROUND"
        const val ACTION_STOP = "com.example.motocam.action.STOP_RECORDING_FOREGROUND"
        const val ACTION_STOP_FROM_NOTIFICATION = "com.example.motocam.action.STOP_FROM_NOTIFICATION"
        const val ACTION_STOP_REQUESTED = "com.example.motocam.action.STOP_REQUESTED"

        const val EXTRA_ELAPSED_MS = "elapsedMs"
        private const val WAKE_LOCK_TAG = "MotoCam:RecordingWakeLock"
        private const val WAKE_LOCK_TIMEOUT_MS = 12 * 60 * 60 * 1000L
    }

    private var wakeLock: PowerManager.WakeLock? = null

    private fun internalBroadcastPermission(): String =
        "$packageName.permission.INTERNAL_BROADCAST"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val elapsedMs = intent.getLongExtra(EXTRA_ELAPSED_MS, 0L)
                acquireWakeLockIfNeeded()
                startForeground(NOTIFICATION_ID, buildNotification(elapsedMs))
            }
            ACTION_UPDATE -> {
                val elapsedMs = intent.getLongExtra(EXTRA_ELAPSED_MS, 0L)
                val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.notify(NOTIFICATION_ID, buildNotification(elapsedMs))
            }
            ACTION_STOP -> {
                releaseWakeLockIfHeld()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            ACTION_STOP_FROM_NOTIFICATION -> {
                sendBroadcast(
                    Intent(ACTION_STOP_REQUESTED).setPackage(packageName),
                    internalBroadcastPermission(),
                )
                releaseWakeLockIfHeld()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }

        return START_STICKY
    }

    private fun buildNotification(elapsedMs: Long): Notification {
        createNotificationChannelIfNeeded()

        val launchIntent =
            packageManager.getLaunchIntentForPackage(packageName)
                ?.apply { flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP }

        val openAppPendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val stopIntent = Intent(this, BackgroundRecordingService::class.java).apply {
            action = ACTION_STOP_FROM_NOTIFICATION
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("MotoCam recording in progress")
            .setContentText("Elapsed: ${formatElapsed(elapsedMs)} - screen can be off")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(openAppPendingIntent)
            .addAction(0, "Stop", stopPendingIntent)
            .build()
    }

    private fun acquireWakeLockIfNeeded() {
        val existing = wakeLock
        if (existing?.isHeld == true) {
            return
        }

        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG).apply {
            setReferenceCounted(false)
            acquire(WAKE_LOCK_TIMEOUT_MS)
        }
    }

    private fun releaseWakeLockIfHeld() {
        val lock = wakeLock
        if (lock != null && lock.isHeld) {
            lock.release()
        }
        wakeLock = null
    }

    override fun onDestroy() {
        releaseWakeLockIfHeld()
        super.onDestroy()
    }

    private fun createNotificationChannelIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) {
            return
        }

        val channel = NotificationChannel(
            CHANNEL_ID,
            "MotoCam Recording",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shows active recording controls and elapsed time"
            setShowBadge(false)
        }

        manager.createNotificationChannel(channel)
    }

    private fun formatElapsed(elapsedMs: Long): String {
        val totalSeconds = (elapsedMs / 1000).coerceAtLeast(0)
        val hours = totalSeconds / 3600
        val minutes = (totalSeconds % 3600) / 60
        val seconds = totalSeconds % 60
        return String.format("%02d:%02d:%02d", hours, minutes, seconds)
    }
}
