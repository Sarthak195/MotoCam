package com.example.motocam

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Native side of the diagnostic log (`lib/core/diagnostics/`, channel
 * `com.example.motocam/diagnostics`).
 *
 * - [installCrashHandler] sets a process-wide default uncaught exception
 *   handler that appends the exception and its stack, synchronously, to
 *   `<filesDir>/diagnostics/app.log` (the Dart log's file, same line format
 *   and 1 MiB rotation to `app.log.1`), then hands the exception to the
 *   handler that was there before (which kills the process as usual).
 * - `getSessionInfo` returns `{versionName, versionCode, manufacturer, model,
 *   release, sdkInt}` for the session header.
 * - `takeExitReasons` returns, on Android 11 (API 30) and later, every
 *   process exit the system recorded after the newest one returned before,
 *   oldest first: `{timestamp, reason, status, importance, description}`
 *   plus `trace` (a bounded part of the trace, from the main thread) for an
 *   ANR. The newest timestamp is kept in SharedPreferences. Below API 30 it
 *   returns an empty list. The work runs on a background thread.
 *
 * Nothing here logs a position, speed or route.
 */
object Diagnostics {
    const val CHANNEL = "com.example.motocam/diagnostics"

    private const val DIRECTORY = "diagnostics"
    private const val FILE_NAME = "app.log"
    private const val ROTATED_FILE_NAME = "app.log.1"
    private const val MAX_BYTES = 1024L * 1024L
    private const val MAX_MESSAGE_CHARS = 8000
    private const val MAX_TRACE_CHARS = 4000
    private const val MAX_TRACE_SCAN_BYTES = 512 * 1024
    private const val PREFS = "motocam_diagnostics"
    private const val KEY_LAST_EXIT = "lastExitTimestamp"

    private val WEB_ADDRESS =
        Regex("""(https?|wss?)://([^/\s?#'"<>]+)[^\s'"<>)\]]*""", RegexOption.IGNORE_CASE)

    private val writeLock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var logDirectory: File? = null

    private var installed = false

    /**
     * Installs the crash handler once per process; later calls (activity
     * recreated, service started) do nothing, so it never chains to itself.
     */
    @Synchronized
    fun installCrashHandler(context: Context) {
        if (installed) {
            return
        }
        installed = true
        logDirectory = File(context.applicationContext.filesDir, DIRECTORY)
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                append(
                    "ERROR",
                    "native",
                    "Uncaught exception in thread ${thread.name}: ${stackTraceOf(error)}",
                )
            } catch (_: Throwable) {
                // The log is never worth hiding the crash.
            }
            if (previous != null) {
                previous.uncaughtException(thread, error)
            } else {
                android.os.Process.killProcess(android.os.Process.myPid())
                System.exit(10)
            }
        }
    }

    /** Registers the method channel on [messenger]. */
    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSessionInfo" -> result.success(sessionInfo(app))
                "takeExitReasons" -> Thread {
                    val exits = try {
                        takeExitReasons(app)
                    } catch (_: Throwable) {
                        emptyList()
                    }
                    mainHandler.post { result.success(exits) }
                }.start()
                else -> result.notImplemented()
            }
        }
    }

    /** Appends one line to the log, rotating it first past [MAX_BYTES]. */
    private fun append(level: String, source: String, message: String) {
        val directory = logDirectory ?: return
        val bytes = (formatLine(level, source, message) + "\n").toByteArray(Charsets.UTF_8)
        synchronized(writeLock) {
            directory.mkdirs()
            val file = File(directory, FILE_NAME)
            val size = file.length()
            if (size > 0 && size + bytes.size > MAX_BYTES) {
                val rotated = File(directory, ROTATED_FILE_NAME)
                rotated.delete()
                file.renameTo(rotated)
            }
            FileOutputStream(file, true).use { out ->
                out.write(bytes)
                out.fd.sync()
            }
        }
    }

    /** The Dart line format: `<UTC time> <LEVEL> [<source>] <message>`. */
    private fun formatLine(level: String, source: String, message: String): String {
        // SimpleDateFormat, not java.time (API 26); one per call, as it is
        // not thread-safe.
        val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        format.timeZone = TimeZone.getTimeZone("UTC")
        var text = WEB_ADDRESS.replace(message) { match ->
            val origin = "${match.groupValues[1]}://${match.groupValues[2]}"
            if (match.value.length > origin.length) "$origin/..." else origin
        }
            .replace("\r\n", "\n")
            .replace("\r", "\n")
            .replace("\n", "\\n")
        if (text.length > MAX_MESSAGE_CHARS) {
            text = text.substring(0, MAX_MESSAGE_CHARS) + " [truncated]"
        }
        return "${format.format(Date())} $level [$source] $text"
    }

    /**
     * The stack trace of [error] with its causes. Not
     * Log.getStackTraceString, which returns "" for an UnknownHostException
     * anywhere in the chain.
     */
    private fun stackTraceOf(error: Throwable): String {
        val writer = StringWriter()
        PrintWriter(writer).use { error.printStackTrace(it) }
        return writer.toString()
    }

    private fun sessionInfo(context: Context): Map<String, Any?> {
        val info = mutableMapOf<String, Any?>(
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "release" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
        )
        try {
            val packageInfo = packageInfoOf(context)
            info["versionName"] = packageInfo.versionName
            info["versionCode"] = versionCodeOf(packageInfo)
        } catch (_: Exception) {
            // The header shows "?" for the version.
        }
        return info
    }

    private fun packageInfoOf(context: Context): PackageInfo {
        val manager = context.packageManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            manager.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            legacyPackageInfoOf(manager, context.packageName)
        }
    }

    @Suppress("DEPRECATION")
    private fun legacyPackageInfoOf(manager: PackageManager, packageName: String): PackageInfo =
        manager.getPackageInfo(packageName, 0)

    @Suppress("DEPRECATION")
    private fun versionCodeOf(packageInfo: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.longVersionCode
        } else {
            packageInfo.versionCode.toLong()
        }

    private fun takeExitReasons(context: Context): List<Map<String, Any?>> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            exitReasonsSinceLastCheck(context)
        } else {
            emptyList()
        }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun exitReasonsSinceLastCheck(context: Context): List<Map<String, Any?>> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val lastSeen = prefs.getLong(KEY_LAST_EXIT, 0L)
        val manager = context.getSystemService(ActivityManager::class.java) ?: return emptyList()
        // Newest first from the system; 0, 0 is every pid and the most kept.
        val exits = manager.getHistoricalProcessExitReasons(context.packageName, 0, 0)
            .filter { it.timestamp > lastSeen }
            .sortedBy { it.timestamp }
        if (exits.isEmpty()) {
            return emptyList()
        }
        prefs.edit().putLong(KEY_LAST_EXIT, exits.last().timestamp).apply()
        return exits.map { exitToMap(it) }
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun exitToMap(exit: ApplicationExitInfo): Map<String, Any?> {
        val map = mutableMapOf<String, Any?>(
            "timestamp" to exit.timestamp,
            "reason" to reasonName(exit.reason),
            "status" to exit.status,
            "importance" to exit.importance,
            "description" to exit.description,
        )
        // A native crash's trace is a binary tombstone (API 31+): not read.
        if (exit.reason == ApplicationExitInfo.REASON_ANR) {
            map["trace"] = anrTraceOf(exit)
        }
        return map
    }

    /**
     * Up to [MAX_TRACE_CHARS] of the ANR trace, from the main thread's stack
     * when it is in the first [MAX_TRACE_SCAN_BYTES]; null when unreadable.
     */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun anrTraceOf(exit: ApplicationExitInfo): String? = try {
        exit.traceInputStream?.use { stream ->
            val buffer = ByteArray(MAX_TRACE_SCAN_BYTES)
            var read = 0
            while (read < buffer.size) {
                val count = stream.read(buffer, read, buffer.size - read)
                if (count < 0) {
                    break
                }
                read += count
            }
            val text = String(buffer, 0, read, Charsets.UTF_8)
            val main = text.indexOf("\"main\"")
            val start = if (main >= 0) main else 0
            text.substring(start, minOf(text.length, start + MAX_TRACE_CHARS))
        }
    } catch (_: Exception) {
        null
    }

    /** The `ApplicationExitInfo.REASON_*` name without the prefix. */
    private fun reasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_UNKNOWN -> "UNKNOWN"
        ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        ApplicationExitInfo.REASON_CRASH -> "CRASH"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
        ApplicationExitInfo.REASON_ANR -> "ANR"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        ApplicationExitInfo.REASON_OTHER -> "OTHER"
        // Added in API 33 and 34; the values are fixed.
        14 -> "FREEZER"
        15 -> "PACKAGE_STATE_CHANGE"
        16 -> "PACKAGE_UPDATED"
        else -> "REASON_$reason"
    }
}
