package com.example.motocam

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29])
class RecordingNotificationsTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    private fun pending(request: Int): PendingIntent =
        PendingIntent.getService(
            context,
            request,
            Intent(context, BackgroundRecordingService::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun recording(elapsedMs: Long = 61_000L): Notification =
        RecordingNotifications.recording(
            context,
            BackgroundRecordingService.CHANNEL_ID,
            elapsedMs,
            pending(0),
            pending(1),
        )

    private fun text(n: Notification, key: String): String? =
        n.extras.getCharSequence(key)?.toString()

    private fun actionTitles(n: Notification): List<String> =
        (n.actions ?: emptyArray()).map { it.title.toString() }

    @Test
    fun recordingNotificationHasTheRecordingText() {
        val n = recording()
        assertEquals("Recording", text(n, Notification.EXTRA_TITLE))
        assertEquals(RecordingNotifications.RECORDING_TEXT, text(n, Notification.EXTRA_TEXT))
        assertTrue(n.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertTrue(n.extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER))
    }

    @Test
    fun recordingNotificationIsPrivateWithAGenericPublicVersion() {
        val n = recording()
        assertEquals(NotificationCompat.VISIBILITY_PRIVATE, n.visibility)
        val publicVersion = n.publicVersion
        assertNotNull(publicVersion)
        assertEquals("Recording", text(publicVersion!!, Notification.EXTRA_TITLE))
        assertEquals("Unlock for details.", text(publicVersion, Notification.EXTRA_TEXT))
        assertFalse(publicVersion.extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER))
        assertNull(text(publicVersion, Notification.EXTRA_SUB_TEXT))
        assertNull(text(publicVersion, Notification.EXTRA_BIG_TEXT))
    }

    @Test
    fun stopStaysOnBothVersionsAndThereIsNoLockAction() {
        val n = recording()
        assertEquals(listOf("Stop"), actionTitles(n))
        assertEquals(listOf("Stop"), actionTitles(n.publicVersion!!))
        assertFalse(actionTitles(n).any { it.equals("Lock", ignoreCase = true) })
    }

    @Test
    fun stoppingNotificationIsGenericAndHasNoActions() {
        val n = RecordingNotifications.stopping(
            context,
            BackgroundRecordingService.CHANNEL_ID,
            pending(0),
        )
        assertEquals(RecordingNotifications.STOPPING_TITLE, text(n, Notification.EXTRA_TITLE))
        assertEquals(NotificationCompat.VISIBILITY_PUBLIC, n.visibility)
        assertTrue(actionTitles(n).isEmpty())
    }

}
