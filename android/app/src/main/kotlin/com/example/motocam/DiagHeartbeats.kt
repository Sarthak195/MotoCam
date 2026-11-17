package com.example.motocam

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

/**
 * Debug builds only (MainActivity creates it when BuildConfig.DEBUG): roll
 * stall diagnostics. Two 100 ms heartbeats, one on the main looper and one on
 * a background HandlerThread, record each tick more than 50 ms late in
 * files/diag/native.jsonl. All file I/O runs on the background thread; the
 * main heartbeat only posts its record there. The "controlStall" call of the
 * com.example.motocam/diag channel blocks the main thread on purpose (a
 * positive control) and records its start and end.
 */
class DiagHeartbeats(filesDir: File) {
    companion object {
        const val CHANNEL = "com.example.motocam/diag"
        private const val TAG = "MotoCamDiag"
        private const val PERIOD_MS = 100L
        private const val LATE_THRESHOLD_MS = 50L
        private const val FLUSH_MS = 2000L
        private const val MAX_BYTES = 5L * 1024 * 1024
        private const val MAX_STALL_MS = 5000L
    }

    private val directory = File(filesDir, "diag")
    private val file = File(directory, "native.jsonl")
    private val mainHandler = Handler(Looper.getMainLooper())
    private var thread: HandlerThread? = null
    private var bgHandler: Handler? = null

    // Owned by the background thread.
    private val pending = StringBuilder()
    private var bytes = 0L
    private var capped = false
    private var disabled = false

    @Volatile
    private var running = false
    private var mainLast = 0L
    private var bgLast = 0L

    private val mainTick = object : Runnable {
        override fun run() {
            if (!running) return
            val now = SystemClock.uptimeMillis()
            val late = now - mainLast - PERIOD_MS
            mainLast = now
            if (late > LATE_THRESHOLD_MS) {
                val epoch = System.currentTimeMillis()
                bgHandler?.post { recordLate(epoch, "main", late) }
            }
            mainHandler.postDelayed(this, PERIOD_MS)
        }
    }

    private val bgTick = object : Runnable {
        override fun run() {
            if (!running) return
            val now = SystemClock.uptimeMillis()
            val late = now - bgLast - PERIOD_MS
            bgLast = now
            if (late > LATE_THRESHOLD_MS) {
                recordLate(System.currentTimeMillis(), "bg", late)
            }
            bgHandler?.postDelayed(this, PERIOD_MS)
        }
    }

    private val flushTick = object : Runnable {
        override fun run() {
            flush()
            if (running) bgHandler?.postDelayed(this, FLUSH_MS)
        }
    }

    /** Starts both heartbeats. Call on the main thread (onCreate). */
    fun start() {
        if (running) return
        val t = HandlerThread("MotoCamDiag")
        t.start()
        val handler = Handler(t.looper)
        thread = t
        bgHandler = handler
        running = true
        val startEpoch = System.currentTimeMillis()
        handler.post {
            openFile()
            append(
                "{\"e\":\"start\",\"ms\":$startEpoch,\"pid\":${Process.myPid()}," +
                    "\"periodMs\":$PERIOD_MS,\"lateMs\":$LATE_THRESHOLD_MS}"
            )
            bgLast = SystemClock.uptimeMillis()
            handler.postDelayed(bgTick, PERIOD_MS)
            handler.postDelayed(flushTick, FLUSH_MS)
        }
        mainLast = SystemClock.uptimeMillis()
        mainHandler.postDelayed(mainTick, PERIOD_MS)
    }

    /** Stops both heartbeats, flushes and quits the thread. Never blocks. */
    fun stop() {
        if (!running) return
        running = false
        mainHandler.removeCallbacks(mainTick)
        val handler = bgHandler
        val t = thread
        bgHandler = null
        thread = null
        val stopEpoch = System.currentTimeMillis()
        handler?.removeCallbacks(bgTick)
        handler?.removeCallbacks(flushTick)
        handler?.post {
            append("{\"e\":\"stop\",\"ms\":$stopEpoch}", force = true)
            flush()
        }
        t?.quitSafely()
    }

    /** Registers the debug-only channel. */
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "controlStall" -> {
                    val requested = (call.argument<Number>("ms")?.toLong() ?: 1500L)
                        .coerceIn(0L, MAX_STALL_MS)
                    result.success(controlStall(requested))
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Blocks the calling (main) thread for [ms] milliseconds on purpose and
     * returns its start and end (epoch ms).
     */
    fun controlStall(ms: Long): Map<String, Any> {
        val start = System.currentTimeMillis()
        Log.w(TAG, "control stall: blocking the main thread for $ms ms")
        try {
            Thread.sleep(ms)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        val end = System.currentTimeMillis()
        Log.w(TAG, "control stall: done")
        bgHandler?.post {
            append(
                "{\"e\":\"controlStall\",\"ms\":$end,\"startMs\":$start," +
                    "\"endMs\":$end,\"requestMs\":$ms}"
            )
        }
        return mapOf("startMs" to start, "endMs" to end)
    }

    // Background thread only from here on.

    private fun recordLate(epoch: Long, src: String, late: Long) {
        if (late >= 500) {
            Log.w(TAG, "$src heartbeat $late ms late")
        }
        append("{\"e\":\"late\",\"ms\":$epoch,\"src\":\"$src\",\"lateMs\":$late}")
    }

    // Keeps one previous file: an existing one over the cap is moved aside so
    // each app start has room.
    private fun openFile() {
        try {
            directory.mkdirs()
            if (file.length() > MAX_BYTES) {
                val previous = File(directory, "native.prev.jsonl")
                previous.delete()
                if (!file.renameTo(previous)) file.delete()
            }
            bytes = file.length()
        } catch (e: Exception) {
            disable(e)
        }
    }

    private fun append(line: String, force: Boolean = false) {
        if (disabled || (capped && !force)) return
        val text = line + "\n"
        if (!force && bytes + text.length > MAX_BYTES) {
            capped = true
            val note = "{\"e\":\"capped\",\"ms\":${System.currentTimeMillis()}}\n"
            bytes += note.length
            pending.append(note)
            return
        }
        bytes += text.length
        pending.append(text)
    }

    private fun flush() {
        if (disabled || pending.isEmpty()) return
        try {
            FileOutputStream(file, true).use { it.write(pending.toString().toByteArray()) }
        } catch (e: Exception) {
            disable(e)
        }
        pending.setLength(0)
    }

    private fun disable(e: Exception) {
        if (disabled) return
        disabled = true
        pending.setLength(0)
        Log.w(TAG, "native diag log disabled: $e")
    }
}
