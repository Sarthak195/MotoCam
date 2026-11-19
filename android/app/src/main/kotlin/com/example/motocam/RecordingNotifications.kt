package com.example.motocam

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import androidx.core.app.NotificationCompat

/**
 * Builds the two notifications of [BackgroundRecordingService]. Kept apart from
 * the service so the text, visibility and action list can be unit tested.
 *
 * Lock screen privacy: the recording notification is VISIBILITY_PRIVATE and
 * carries a public version. On a secure lock screen the system shows only the
 * public version, which has generic text (no place, speed, clip count or any
 * other ride detail). The same Stop action is attached to the public version,
 * but whether Stop shows on a redacted lock screen is unverified: SystemUI
 * renders the public version as a collapsed view, which likely has no action
 * buttons, so the rider may have to unlock to reach Stop. Stop itself is a
 * plain service PendingIntent with no unlock requirement (owner decision N3 is
 * open; a phone check with hide-sensitive on and off must come first). There
 * is no LOCK action: that feature is off, and a future one must be gated on
 * BuildConfig.NOTIFICATION_LOCK (false), the native twin of kNotificationLock.
 */
object RecordingNotifications {
    const val RECORDING_TITLE = "Recording"
    const val RECORDING_TEXT = "Designed to keep recording with the screen off"
    const val PUBLIC_TEXT = "Unlock for details."
    const val STOPPING_TITLE = "MotoCam is stopping the recording"
    const val STOPPING_TEXT = "Saving the ride - open MotoCam to check"
    const val STOP_LABEL = "Stop"

    /**
     * The ongoing recording notification. The elapsed time is rendered by the
     * system chronometer from [elapsedMs], so it is not re-posted every second.
     */
    fun recording(
        context: Context,
        channelId: String,
        elapsedMs: Long,
        openApp: PendingIntent,
        stop: PendingIntent,
    ): Notification {
        val publicVersion = base(context, channelId, openApp)
            .setContentTitle(RECORDING_TITLE)
            .setContentText(PUBLIC_TEXT)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(0, STOP_LABEL, stop)
            .build()

        return base(context, channelId, openApp)
            .setContentTitle(RECORDING_TITLE)
            .setContentText(RECORDING_TEXT)
            .setWhen(System.currentTimeMillis() - elapsedMs.coerceAtLeast(0L))
            .setShowWhen(true)
            .setUsesChronometer(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
            .addAction(0, STOP_LABEL, stop)
            .build()
    }

    /** Shown after Stop was tapped, until the ride is saved. Generic text only. */
    fun stopping(
        context: Context,
        channelId: String,
        openApp: PendingIntent,
    ): Notification =
        base(context, channelId, openApp)
            .setContentTitle(STOPPING_TITLE)
            .setContentText(STOPPING_TEXT)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()

    private fun base(
        context: Context,
        channelId: String,
        openApp: PendingIntent,
    ): NotificationCompat.Builder =
        NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_stat_recording)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(openApp)
}
