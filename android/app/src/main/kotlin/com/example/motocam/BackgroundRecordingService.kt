package com.example.motocam

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
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
        private const val TAG = "MotoCamRecordingService"
        private const val WAKE_LOCK_TAG = "MotoCam:RecordingWakeLock"
        private const val WAKE_LOCK_TIMEOUT_MS = 12 * 60 * 60 * 1000L

        // If the notification's Stop request is not answered by Dart's
        // stopForegroundRecording (ACTION_STOP) within this time, the service
        // tears itself down so the ongoing notification cannot outlive the app.
        // Dart sends ACTION_STOP only after the final segment is saved and the
        // ride JSON (with every segment's SHA-256) is written, which can take
        // minutes for a long ride, so the fallback must not fire before that.
        private const val STOP_REQUEST_TIMEOUT_MS = 10 * 60 * 1000L

        /**
         * Foreground-service types whose runtime prerequisites are currently
         * granted (camera, location, microphone). The two-argument
         * startForeground would apply every type declared in the manifest, and
         * on API 34+ a type whose permission is missing (for example microphone
         * when audio recording is off) throws a SecurityException. Returns 0
         * below API 30, where the manifest types are used instead.
         */
        fun grantedForegroundServiceTypes(context: Context): Int {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                return 0
            }
            fun granted(permission: String) =
                context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

            var types = 0
            if (granted(Manifest.permission.CAMERA)) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            }
            if (granted(Manifest.permission.ACCESS_FINE_LOCATION) ||
                granted(Manifest.permission.ACCESS_COARSE_LOCATION)
            ) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
            }
            if (granted(Manifest.permission.RECORD_AUDIO)) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            return types
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var isForegroundActive = false

    // Set once the notification's Stop was relayed to Dart, so a late
    // ACTION_UPDATE cannot replace the "stopping" notification with the
    // recording one (and its Stop action) again.
    private var isStopRequested = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private val stopRequestTimeout = Runnable { tearDown() }

    private val openAppPendingIntent: PendingIntent by lazy {
        val launchIntent =
            packageManager.getLaunchIntentForPackage(packageName)
                ?.apply { flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP }

        PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private val stopPendingIntent: PendingIntent by lazy {
        val stopIntent = Intent(this, BackgroundRecordingService::class.java).apply {
            action = ACTION_STOP_FROM_NOTIFICATION
        }
        PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun internalBroadcastPermission(): String =
        "$packageName.permission.INTERNAL_BROADCAST"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannelIfNeeded()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val elapsedMs = intent.getLongExtra(EXTRA_ELAPSED_MS, 0L)
                mainHandler.removeCallbacks(stopRequestTimeout)
                isStopRequested = false
                acquireWakeLockIfNeeded()
                try {
                    val notification = buildNotification(elapsedMs)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        startForeground(
                            NOTIFICATION_ID,
                            notification,
                            grantedForegroundServiceTypes(this),
                        )
                    } else {
                        startForeground(NOTIFICATION_ID, notification)
                    }
                    isForegroundActive = true
                } catch (e: Exception) {
                    // Last resort: MainActivity only starts the service when a
                    // permitted type exists, so this should not happen.
                    Log.e(TAG, "startForeground failed", e)
                    tearDown()
                }
            }
            ACTION_UPDATE -> {
                if (!isForegroundActive) {
                    // Never re-post the recording notification from a service
                    // that is not (or no longer) in the foreground. The start
                    // id keeps a later queued ACTION_START alive.
                    stopSelf(startId)
                    return START_NOT_STICKY
                }
                if (isStopRequested) {
                    return START_NOT_STICKY
                }
                val elapsedMs = intent.getLongExtra(EXTRA_ELAPSED_MS, 0L)
                val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.notify(NOTIFICATION_ID, buildNotification(elapsedMs))
            }
            ACTION_STOP -> {
                tearDown()
            }
            ACTION_STOP_FROM_NOTIFICATION -> {
                if (!isForegroundActive) {
                    tearDown()
                    return START_NOT_STICKY
                }
                // Only request the stop. The foreground service and wake lock
                // stay up until Dart has stopped the recording and calls
                // stopForegroundRecording (ACTION_STOP).
                isStopRequested = true
                sendBroadcast(
                    Intent(ACTION_STOP_REQUESTED).setPackage(packageName),
                    internalBroadcastPermission(),
                )
                val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.notify(NOTIFICATION_ID, buildStoppingNotification())
                mainHandler.removeCallbacks(stopRequestTimeout)
                mainHandler.postDelayed(stopRequestTimeout, STOP_REQUEST_TIMEOUT_MS)
            }
            else -> {
                if (!isForegroundActive) {
                    stopSelf(startId)
                }
            }
        }

        // A restarted service has no recorder to protect, so never restart it.
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // The activity, and with it the Flutter engine and camera, is gone.
        tearDown()
        super.onTaskRemoved(rootIntent)
    }

    private fun tearDown() {
        mainHandler.removeCallbacks(stopRequestTimeout)
        releaseWakeLockIfHeld()
        isForegroundActive = false
        isStopRequested = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * Builds the ongoing recording notification. The elapsed time is rendered
     * by the system chronometer from [elapsedMs], so it does not need to be
     * re-posted every second.
     */
    private fun buildNotification(elapsedMs: Long): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_recording)
            .setContentTitle("MotoCam recording in progress")
            .setContentText("Recording - screen can be off")
            .setWhen(System.currentTimeMillis() - elapsedMs.coerceAtLeast(0L))
            .setShowWhen(true)
            .setUsesChronometer(true)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(openAppPendingIntent)
            .addAction(0, "Stop", stopPendingIntent)
            .build()
    }

    private fun buildStoppingNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_recording)
            .setContentTitle("MotoCam is stopping the recording")
            .setContentText("Saving the ride - open MotoCam to check")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(openAppPendingIntent)
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
        mainHandler.removeCallbacks(stopRequestTimeout)
        releaseWakeLockIfHeld()
        isForegroundActive = false
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
}
