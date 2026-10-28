package com.example.motocam

import android.Manifest
import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.IntentSender
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The gallery copies MotoCam made with `exportVideoToGallery` (channel
 * `com.example.motocam/gallery`, F045): checking that they exist and
 * removing them.
 *
 * Methods (every one takes `uris`, a list of content URIs):
 * - `galleryItemsExist` returns the URIs that still have a MediaStore row.
 * - `deleteGalleryItems` deletes each URI with `ContentResolver.delete`,
 *   without any prompt (the app owns the media it inserted), and returns
 *   `{uri: status}`: `deleted`; `missing` (the copy is already gone);
 *   `needsConsent` (a `SecurityException` on API 29+, for
 *   `requestDeleteGalleryItems`); `needsPermission` (API 24-28 without
 *   `WRITE_EXTERNAL_STORAGE`, or a `SecurityException` there); `failed`.
 * - `requestDeleteGalleryItems` asks the rider: on API 30+ one
 *   `MediaStore.createDeleteRequest` prompt for all URIs; on API 29 the
 *   `RecoverableSecurityException` action of each URI in turn, deleting it
 *   again once allowed. Returns `{uri: status}` with `deleted`, `missing`,
 *   `denied` (prompt declined) or `failed` (also every URI below API 29,
 *   where no such prompt exists). Error `BUSY` while a request is open.
 *
 * Prompts are started with request code [REQUEST_DELETE] and their results
 * arrive in [onDeleteRequestResult], which [MainActivity] routes here
 * through its activity-result dispatcher. MediaStore work runs on one
 * background thread; replies are posted to the main thread.
 */
class GalleryCopies(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.example.motocam/gallery"

        /** Request code of the delete prompts (see [ActivityRequestCodes]). */
        const val REQUEST_DELETE = ActivityRequestCodes.MEDIA_STORE_DELETE_REQUEST

        private const val TAG = "MotoCam"
        private const val DELETED = "deleted"
        private const val MISSING = "missing"
        private const val NEEDS_CONSENT = "needsConsent"
        private const val NEEDS_PERMISSION = "needsPermission"
        private const val DENIED = "denied"
        private const val FAILED = "failed"
    }

    /** An open `requestDeleteGalleryItems` call. */
    private class PendingRequest(
        val result: MethodChannel.Result,
        val statuses: MutableMap<String, String>,
        // API 29: the URIs still to ask about, in order; API 30+: empty.
        val queue: ArrayDeque<String>,
        // API 29: the URI whose prompt is showing; API 30+: null.
        var current: String?,
    )

    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pending: PendingRequest? = null

    /** Registers the channel handler on [messenger]. */
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val uris = call.argument<List<String>>("uris") ?: emptyList()
        when (call.method) {
            "galleryItemsExist" -> runInBackground(result, "QUERY_FAILED") {
                uris.filter { exists(it) }
            }
            "deleteGalleryItems" -> runInBackground(result, "DELETE_FAILED") {
                uris.associateWith { deleteQuietly(it) }
            }
            "requestDeleteGalleryItems" -> requestDelete(uris, result)
            else -> result.notImplemented()
        }
    }

    private fun parse(uri: String): Uri? =
        Uri.parse(uri).takeIf { it.scheme == "content" }

    /** Whether [uri] still has a MediaStore row this app can see. */
    private fun exists(uri: String): Boolean {
        val parsed = parse(uri) ?: return false
        return try {
            activity.contentResolver
                .query(parsed, arrayOf(MediaStore.MediaColumns._ID), null, null, null)
                ?.use { it.count > 0 } ?: false
        } catch (e: Exception) {
            // Treated as present: a copy is never reported removed when
            // it could not be checked.
            Log.w(TAG, "gallery item query failed", e)
            true
        }
    }

    private fun hasLegacyWritePermission(): Boolean =
        activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED

    /** Deletes [uri] without a prompt; see the class comment for statuses. */
    private fun deleteQuietly(uri: String): String {
        val parsed = parse(uri) ?: return FAILED
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && !hasLegacyWritePermission()) {
            return NEEDS_PERMISSION
        }
        return try {
            val rows = activity.contentResolver.delete(parsed, null, null)
            when {
                rows > 0 -> DELETED
                !exists(uri) -> MISSING
                else -> FAILED
            }
        } catch (e: SecurityException) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) NEEDS_CONSENT else NEEDS_PERMISSION
        } catch (e: Exception) {
            Log.w(TAG, "gallery item delete failed", e)
            if (!exists(uri)) MISSING else FAILED
        }
    }

    private fun requestDelete(uris: List<String>, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("BUSY", "a delete request is already open", null)
            return
        }
        val statuses = uris.associateWith { FAILED }.toMutableMap()
        if (uris.isEmpty() || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(statuses)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val parsed = uris.mapNotNull { parse(it) }
            if (parsed.isEmpty()) {
                result.success(statuses)
                return
            }
            val request = PendingRequest(result, statuses, ArrayDeque(), null)
            pending = request
            try {
                val intent = MediaStore.createDeleteRequest(activity.contentResolver, parsed)
                startPrompt(intent.intentSender)
            } catch (e: Exception) {
                Log.e(TAG, "createDeleteRequest failed", e)
                finish(request)
            }
            return
        }
        // API 29: one prompt per copy.
        val request = PendingRequest(result, statuses, ArrayDeque(uris), null)
        pending = request
        askNext(request)
    }

    @Suppress("DEPRECATION")
    private fun startPrompt(sender: IntentSender) {
        activity.startIntentSenderForResult(sender, REQUEST_DELETE, null, 0, 0, 0)
    }

    /** API 29: deletes the next URI, asking the rider when MediaStore refuses. */
    private fun askNext(request: PendingRequest) {
        val uri = request.queue.removeFirstOrNull()
        if (uri == null) {
            finish(request)
            return
        }
        executor.execute {
            val parsed = parse(uri)
            var sender: IntentSender? = null
            val status = if (parsed == null) {
                FAILED
            } else {
                try {
                    val rows = activity.contentResolver.delete(parsed, null, null)
                    if (rows > 0) DELETED else if (!exists(uri)) MISSING else FAILED
                } catch (e: SecurityException) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                        e is RecoverableSecurityException
                    ) {
                        sender = e.userAction.actionIntent.intentSender
                    }
                    FAILED
                } catch (e: Exception) {
                    if (!exists(uri)) MISSING else FAILED
                }
            }
            mainHandler.post {
                if (pending !== request) {
                    return@post
                }
                request.statuses[uri] = status
                val prompt = sender
                if (prompt == null) {
                    askNext(request)
                    return@post
                }
                request.current = uri
                try {
                    startPrompt(prompt)
                } catch (e: Exception) {
                    Log.e(TAG, "delete prompt failed", e)
                    request.current = null
                    askNext(request)
                }
            }
        }
    }

    /**
     * The result of a delete prompt, routed by [MainActivity] on the main
     * thread for [REQUEST_DELETE].
     */
    fun onDeleteRequestResult(resultCode: Int) {
        val request = pending ?: return
        val allowed = resultCode == Activity.RESULT_OK
        val current = request.current
        if (current != null) {
            // API 29: delete the allowed copy again, then the next one.
            request.current = null
            if (!allowed) {
                request.statuses[current] = DENIED
                askNext(request)
                return
            }
            executor.execute {
                val status = deleteQuietly(current)
                mainHandler.post {
                    if (pending !== request) {
                        return@post
                    }
                    request.statuses[current] = when (status) {
                        DELETED, MISSING -> status
                        else -> FAILED
                    }
                    askNext(request)
                }
            }
            return
        }
        // API 30+: the system deleted the copies itself when allowed.
        val uris = request.statuses.keys.toList()
        executor.execute {
            val updated = uris.associateWith { uri ->
                when {
                    !exists(uri) -> if (allowed) DELETED else MISSING
                    allowed -> FAILED
                    else -> DENIED
                }
            }
            mainHandler.post {
                if (pending !== request) {
                    return@post
                }
                request.statuses.putAll(updated)
                finish(request)
            }
        }
    }

    private fun finish(request: PendingRequest) {
        if (pending === request) {
            pending = null
        }
        request.result.success(HashMap(request.statuses))
    }

    /** Answers an open request (the activity is going away). */
    fun dispose() {
        pending?.let { request ->
            request.statuses.replaceAll { _, status ->
                if (status == DELETED || status == MISSING) status else DENIED
            }
            finish(request)
        }
        executor.shutdown()
    }

    private fun runInBackground(
        result: MethodChannel.Result,
        errorCode: String,
        work: () -> Any?,
    ) {
        executor.execute {
            try {
                val value = work()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                Log.e(TAG, errorCode, e)
                mainHandler.post { result.error(errorCode, e.message, null) }
            }
        }
    }
}
