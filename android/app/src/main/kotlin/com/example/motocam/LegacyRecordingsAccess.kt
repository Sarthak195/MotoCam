package com.example.motocam

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Storage Access Framework access to the public folder that v0.1.11 and
 * v0.1.12 recorded to (`Movies/MotoCam/Recordings`), for the import of old
 * rides (channel `com.example.motocam/legacy_recordings`, F016).
 *
 * This install usually cannot read that folder directly (another signing
 * key, scoped storage), so the rider grants it with
 * `ACTION_OPEN_DOCUMENT_TREE`. The grant is never persisted
 * (`takePersistableUriPermission` is not called): it ends with the
 * activity, so the import and the optional delete of the originals happen
 * in the same session.
 *
 * Methods:
 * - `pickRecordingsTree` opens the folder picker (on API 26+ starting in
 *   `primary:Movies/MotoCam/Recordings`) and returns the tree URI, or null
 *   when the rider cancels. Error `BUSY` while a picker is open,
 *   `NO_PICKER` when no app handles the intent.
 * - `listTree({treeUri})` returns the tree's direct children that are
 *   files: `{uri, name, size, canDelete}` (`size` -1 when unknown).
 * - `copyDocument({uri, targetPath})` streams one document into a file
 *   (1 MiB buffer, never the whole file in memory), flushes and syncs it,
 *   and returns the bytes copied. Error `CANCELLED` after
 *   `cancelCopy`, `COPY_FAILED` otherwise; a partial target is deleted.
 * - `cancelCopy` makes the copy in progress (or the next one already
 *   queued) stop at its next buffer.
 * - `deleteDocuments({uris})` deletes each document with
 *   `DocumentsContract.deleteDocument` and returns the URIs that could not
 *   be deleted.
 *
 * The picker result arrives in [onTreePicked], which [MainActivity]
 * routes here by request code. Listing, copying and deleting run on one
 * background thread; replies are posted to the main thread.
 */
class LegacyRecordingsAccess(private val activity: Activity) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.example.motocam/legacy_recordings"

        /** Request code of the folder picker (see [ActivityRequestCodes]). */
        const val REQUEST_PICK_TREE = ActivityRequestCodes.PICK_LEGACY_RECORDINGS_TREE

        private const val EXTERNAL_STORAGE_AUTHORITY =
            "com.android.externalstorage.documents"
        private const val INITIAL_DOCUMENT_ID = "primary:Movies/MotoCam/Recordings"
        private const val BUFFER_BYTES = 1024 * 1024
        private const val TAG = "MotoCam"
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val cancelRequested = AtomicBoolean(false)
    private var pendingPick: MethodChannel.Result? = null

    /** Registers the channel handler on [messenger]. */
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickRecordingsTree" -> pickTree(result)
            "listTree" -> {
                val treeUri = call.argument<String>("treeUri")
                if (treeUri.isNullOrBlank()) {
                    result.error("INVALID_ARGS", "treeUri is required", null)
                    return
                }
                runInBackground(result, "LIST_FAILED") { listTree(Uri.parse(treeUri)) }
            }
            "copyDocument" -> {
                val uri = call.argument<String>("uri")
                val targetPath = call.argument<String>("targetPath")
                if (uri.isNullOrBlank() || targetPath.isNullOrBlank()) {
                    result.error("INVALID_ARGS", "uri and targetPath are required", null)
                    return
                }
                // Reset here, on the main thread, so a cancel sent while this
                // copy waits in the queue still applies to it.
                cancelRequested.set(false)
                executor.execute {
                    try {
                        val copied = copyDocument(Uri.parse(uri), File(targetPath))
                        mainHandler.post { result.success(copied) }
                    } catch (e: CopyCancelled) {
                        mainHandler.post { result.error("CANCELLED", "copy cancelled", null) }
                    } catch (e: Exception) {
                        Log.e(TAG, "copyDocument failed", e)
                        mainHandler.post { result.error("COPY_FAILED", e.message, null) }
                    }
                }
            }
            "cancelCopy" -> {
                cancelRequested.set(true)
                result.success(true)
            }
            "deleteDocuments" -> {
                val uris = call.argument<List<String>>("uris") ?: emptyList()
                runInBackground(result, "DELETE_FAILED") { deleteDocuments(uris) }
            }
            else -> result.notImplemented()
        }
    }

    private fun pickTree(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("BUSY", "a folder picker is already open", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(
                    DocumentsContract.EXTRA_INITIAL_URI,
                    DocumentsContract.buildDocumentUri(
                        EXTERNAL_STORAGE_AUTHORITY,
                        INITIAL_DOCUMENT_ID,
                    ),
                )
            }
        }
        pendingPick = result
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, REQUEST_PICK_TREE)
        } catch (e: ActivityNotFoundException) {
            pendingPick = null
            result.error("NO_PICKER", "no app can pick a folder", null)
        }
    }

    /**
     * Answers the open picker call with the picked tree URI, or null when
     * the rider cancelled. [MainActivity] routes the [REQUEST_PICK_TREE]
     * result here on the main thread.
     */
    fun onTreePicked(resultCode: Int, data: Intent?) {
        val result = pendingPick ?: return
        pendingPick = null
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        result.success(uri?.toString())
    }

    /** Answers an open picker with null (the activity is going away). */
    fun dispose() {
        pendingPick?.success(null)
        pendingPick = null
        cancelRequested.set(true)
        executor.shutdown()
    }

    private fun listTree(treeUri: Uri): List<Map<String, Any?>> {
        val resolver = activity.contentResolver
        val parentId = DocumentsContract.getTreeDocumentId(treeUri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_FLAGS,
        )
        val documents = mutableListOf<Map<String, Any?>>()
        resolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val documentId = cursor.getString(0) ?: continue
                val name = cursor.getString(1) ?: continue
                val mimeType = cursor.getString(3)
                if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
                    continue
                }
                val size = if (cursor.isNull(2)) -1L else cursor.getLong(2)
                val flags = if (cursor.isNull(4)) 0 else cursor.getInt(4)
                documents.add(
                    mapOf(
                        "uri" to DocumentsContract.buildDocumentUriUsingTree(
                            treeUri,
                            documentId,
                        ).toString(),
                        "name" to name,
                        "size" to size,
                        "canDelete" to
                            (flags and DocumentsContract.Document.FLAG_SUPPORTS_DELETE != 0),
                    ),
                )
            }
        }
        return documents
    }

    private class CopyCancelled : Exception()

    private fun copyDocument(uri: Uri, target: File): Long {
        var copied = 0L
        try {
            val input = activity.contentResolver.openInputStream(uri)
                ?: throw IllegalStateException("cannot open $uri")
            input.use { stream ->
                FileOutputStream(target).use { output ->
                    val buffer = ByteArray(BUFFER_BYTES)
                    while (true) {
                        if (cancelRequested.get()) {
                            throw CopyCancelled()
                        }
                        val read = stream.read(buffer)
                        if (read < 0) {
                            break
                        }
                        output.write(buffer, 0, read)
                        copied += read
                    }
                    output.flush()
                    output.fd.sync()
                }
            }
        } catch (e: Exception) {
            target.delete()
            throw e
        }
        return copied
    }

    private fun deleteDocuments(uris: List<String>): List<String> {
        val failed = mutableListOf<String>()
        for (uri in uris) {
            val deleted = try {
                DocumentsContract.deleteDocument(activity.contentResolver, Uri.parse(uri))
            } catch (e: Exception) {
                Log.e(TAG, "deleteDocument failed", e)
                false
            }
            if (!deleted) {
                failed.add(uri)
            }
        }
        return failed
    }

    private fun <T> runInBackground(
        result: MethodChannel.Result,
        errorCode: String,
        work: () -> T,
    ) {
        executor.execute {
            try {
                val value = work()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                Log.e(TAG, "$errorCode", e)
                mainHandler.post { result.error(errorCode, e.message, null) }
            }
        }
    }
}

/**
 * Request codes of the activities [MainActivity] starts for a result. Each
 * is unique in the app (plugins use their own, for example
 * permission_handler 209 to 214 and geolocator 109), and below 65536.
 */
object ActivityRequestCodes {
    /** `ACTION_OPEN_DOCUMENT_TREE` for the legacy-folder import. */
    const val PICK_LEGACY_RECORDINGS_TREE = 7101

    /** The MediaStore delete prompt for gallery copies ([GalleryCopies]). */
    const val MEDIA_STORE_DELETE_REQUEST = 7102
}

/**
 * Routes `onActivityResult` to the handler registered for its request
 * code. Kept free of Android framework types other than [Intent] so the
 * routing stays trivial to extend.
 */
class ActivityResultDispatcher {
    private val handlers =
        mutableMapOf<Int, (resultCode: Int, data: Intent?) -> Unit>()

    /** Registers [handler] for [requestCode]; a second registration fails. */
    fun register(requestCode: Int, handler: (resultCode: Int, data: Intent?) -> Unit) {
        require(!handlers.containsKey(requestCode)) {
            "request code $requestCode is already registered"
        }
        handlers[requestCode] = handler
    }

    /** Calls the handler for [requestCode]; returns whether one was found. */
    fun dispatch(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val handler = handlers[requestCode] ?: return false
        handler(resultCode, data)
        return true
    }
}
