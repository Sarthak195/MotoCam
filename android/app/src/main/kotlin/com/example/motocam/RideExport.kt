package com.example.motocam

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.database.Cursor
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.system.Os
import android.system.OsConstants
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Ride export (channel `com.example.motocam/ride_export`, roadmap T0-1):
 * copies of a ride's private files into a folder the rider picks with the
 * Storage Access Framework, each checked by reading it back, plus hashing
 * and the share sheet for a share. Dart side:
 * `lib/core/services/ride_export_channel.dart`; contract: ride export
 * design, sections 11.8 and 13.1.
 *
 * The picked tree grant is never persisted (`takePersistableUriPermission`
 * is not called): a killed export is run again with a new pick, and files
 * already copied are skipped.
 *
 * Methods (every SHA-256 is lowercase hex, every `bytes` an int):
 * - `pickExportFolder()` opens `ACTION_OPEN_DOCUMENT_TREE` (read and
 *   write grants, no initial folder) and returns the tree URI, or null when
 *   the rider cancels. Errors `BUSY` (a picker is already open),
 *   `NO_PICKER` (no app handles the intent).
 * - `prepareFolder({treeUri, name, expectedNames})` returns the document
 *   URI of the export folder: the picked tree itself when its display name
 *   is `name`, else its direct child directory named exactly `name`, else
 *   a new child directory. Refuses a folder holding a file whose name is
 *   not in `expectedNames`, then deletes an old `manifest.json` and
 *   `MOTOCAM-EXPORT.txt` there. Errors `NAME_CONFLICT` (the provider gave
 *   the new folder another name; it is deleted), `FOLDER_NOT_EMPTY`,
 *   `NOT_WRITABLE` (the tree does not support creating documents, or
 *   creating returned nothing), `WRITE_FAILED`, `INVALID_ARGS`.
 * - `exportFile({folderUri, sourcePath, name, mimeType, replace})` copies
 *   the private file `sourcePath` into the folder as `name` and returns
 *   `{bytes, sourceSha256, copySha256, skipped, synced}`. A file of that
 *   name already there with the same content is skipped (`skipped` true,
 *   nothing written); a shorter one is a partial copy from a killed run
 *   and is replaced; a longer one, or one of the same size but other
 *   content, is never touched (`EXISTS_DIFFERENT`): it may be the only
 *   intact copy of a clip that changed on the phone. A size the provider does not report counts as
 *   the byte count read from the existing file. A new copy is synced when
 *   it is a regular file (`synced` true); a pipe, a socket, another file
 *   type or a failed `fstat` gives `synced` false. The copy is then read
 *   back and its bytes and hash must equal the source's. Errors
 *   `CANCELLED`, `SOURCE_NOT_FOUND`, `EXISTS_DIFFERENT`, `NAME_CONFLICT`,
 *   `NOT_WRITABLE`, `WRITE_FAILED` (also a source read failure or a lost
 *   grant), `COPY_MISMATCH`, `INVALID_ARGS`. On any error the document
 *   this call created is deleted; an existing one is kept. With `replace`
 *   true (default false; used for trimmed copies, which differ on every
 *   run) an existing file of that name is deleted and the file copied
 *   fresh, without the size and hash comparison.
 * - `hashFile({path})` returns `{bytes, sha256}` of a private file.
 *   Errors `CANCELLED`, `SOURCE_NOT_FOUND`, `READ_FAILED`, `INVALID_ARGS`.
 * - `trimClip({sourcePath, targetPath, startUs, endUs})` writes the part
 *   of the private clip `sourcePath` from `startUs` to `endUs` (source
 *   microseconds) to `targetPath` with MediaExtractor and MediaMuxer,
 *   without re-encoding: the first video and audio tracks are copied, the
 *   start snaps back to the video keyframe at or before `startUs`,
 *   timestamps are rebased so that keyframe is 0 (samples before it are
 *   dropped), each track stops after `endUs`, and the source rotation is
 *   kept. Returns `{bytes, firstUs, lastUs}`: `firstUs` is the source time
 *   of the first video keyframe written, `lastUs` the source time of the
 *   last sample written (either track). The target must be under
 *   `<cacheDir>/ride_export/`; a partial target is deleted on any error.
 *   Errors `CANCELLED`, `SOURCE_NOT_FOUND`, `TRIM_FAILED` (no video track,
 *   an extractor or muxer failure; message kept), `INVALID_ARGS`.
 * - `cancel()` makes the `exportFile`, `hashFile` or `trimClip` in
 *   progress (or the next one already queued) stop at its next buffer or
 *   sample; returns true. The flag is reset when `exportFile`, `hashFile`
 *   or `trimClip` is called.
 * - `shareFiles({paths, mimeTypes, subject})` opens the share sheet
 *   (`ACTION_SEND_MULTIPLE` through `Intent.createChooser`) with read-only
 *   `content://` URIs from the app's FileProvider and returns true. The
 *   type is the one MIME type all files share, else the wildcard type
 *   (any type). Errors
 *   `NOT_SHAREABLE` (a path outside the provider roots in
 *   `res/xml/export_file_paths.xml`), `NO_TARGET` (the chooser could not
 *   be started), `INVALID_ARGS`.
 * - `setKeepScreenOn({enabled})` keeps the screen on while an export runs
 *   (through [onKeepScreenOn]); returns null.
 *
 * The picker result arrives in [onTreePicked], which [MainActivity] routes
 * here by request code. Folder work and hashing run on this class's own
 * background thread (never the legacy import's); replies are posted to the
 * main thread.
 */
class RideExport(
    private val activity: Activity,
    private val onKeepScreenOn: (Boolean) -> Unit,
) : MethodChannel.MethodCallHandler {

    companion object {
        /** The channel name. */
        const val CHANNEL = "com.example.motocam/ride_export"

        /** Request code of the folder picker (see [ActivityRequestCodes]). */
        const val REQUEST_PICK_TREE = ActivityRequestCodes.PICK_EXPORT_TREE

        private const val BUFFER_BYTES = 1024 * 1024

        /** The [trimClip] sample buffer when no track reports its largest sample. */
        private const val TRIM_FALLBACK_SAMPLE_BYTES = 8 * 1024 * 1024

        /** The cache folder every [trimClip] target must be under. */
        private const val EXPORT_CACHE_DIR = "ride_export"
        private const val MANIFEST_NAME = "manifest.json"
        private const val README_NAME = "MOTOCAM-EXPORT.txt"
        private const val TAG = "MotoCam"
        private const val HEX_DIGITS = "0123456789abcdef"

        private val DOCUMENT_PROJECTION = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_FLAGS,
        )
    }

    /** A failure carrying the channel error [code]. */
    private class ExportError(val code: String, message: String) : Exception(message)

    /** Bytes read by [digest] and their SHA-256 (lowercase hex). */
    private class Digested(val bytes: Long, val sha256: String)

    /** One row of a document query. [size] is null when not reported. */
    private class Document(
        val uri: Uri,
        val name: String?,
        val mimeType: String?,
        val size: Long?,
        val flags: Int,
    ) {
        /** Whether this document is a directory. */
        val isDirectory: Boolean
            get() = mimeType == DocumentsContract.Document.MIME_TYPE_DIR
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
            "pickExportFolder" -> pickFolder(result)
            "prepareFolder" -> {
                val treeUri = call.argument<String>("treeUri")
                val name = call.argument<String>("name")
                val expectedNames = call.argument<List<String>>("expectedNames")
                if (treeUri.isNullOrBlank() || name.isNullOrBlank() || expectedNames == null) {
                    result.error("INVALID_ARGS", "treeUri, name and expectedNames are required", null)
                    return
                }
                runInBackground(result, "WRITE_FAILED") {
                    prepareFolder(Uri.parse(treeUri), name, expectedNames.toSet())
                }
            }
            "exportFile" -> {
                val folderUri = call.argument<String>("folderUri")
                val sourcePath = call.argument<String>("sourcePath")
                val name = call.argument<String>("name")
                val mimeType = call.argument<String>("mimeType")
                val replace = call.argument<Boolean>("replace") ?: false
                if (folderUri.isNullOrBlank() || sourcePath.isNullOrBlank() ||
                    name.isNullOrBlank() || mimeType.isNullOrBlank()
                ) {
                    result.error(
                        "INVALID_ARGS",
                        "folderUri, sourcePath, name and mimeType are required",
                        null,
                    )
                    return
                }
                // Reset here, on the main thread, so a cancel sent while this
                // call waits in the queue still applies to it.
                cancelRequested.set(false)
                runInBackground(result, "WRITE_FAILED") {
                    exportFile(Uri.parse(folderUri), File(sourcePath), name, mimeType, replace)
                }
            }
            "trimClip" -> {
                val sourcePath = call.argument<String>("sourcePath")
                val targetPath = call.argument<String>("targetPath")
                // A Dart int arrives as an Integer or a Long, by its size.
                val startUs = call.argument<Number>("startUs")?.toLong()
                val endUs = call.argument<Number>("endUs")?.toLong()
                if (sourcePath.isNullOrBlank() || targetPath.isNullOrBlank() ||
                    startUs == null || endUs == null || startUs < 0 || endUs <= startUs
                ) {
                    result.error(
                        "INVALID_ARGS",
                        "sourcePath, targetPath and 0 <= startUs < endUs are required",
                        null,
                    )
                    return
                }
                cancelRequested.set(false)
                runInBackground(result, "TRIM_FAILED") {
                    trimClip(File(sourcePath), File(targetPath), startUs, endUs)
                }
            }
            "hashFile" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("INVALID_ARGS", "path is required", null)
                    return
                }
                cancelRequested.set(false)
                runInBackground(result, "READ_FAILED") { hashFile(File(path)) }
            }
            "cancel" -> {
                cancelRequested.set(true)
                result.success(true)
            }
            "shareFiles" -> {
                val paths = call.argument<List<String>>("paths")
                val mimeTypes = call.argument<List<String>>("mimeTypes")
                val subject = call.argument<String>("subject") ?: ""
                if (paths.isNullOrEmpty() || mimeTypes == null || mimeTypes.size != paths.size) {
                    result.error("INVALID_ARGS", "paths and one mimeType per path are required", null)
                    return
                }
                try {
                    result.success(shareFiles(paths, mimeTypes, subject))
                } catch (e: ExportError) {
                    result.error(e.code, e.message, null)
                } catch (e: Exception) {
                    Log.e(TAG, "ride export share failed", e)
                    result.error("NO_TARGET", e.message, null)
                }
            }
            "setKeepScreenOn" -> {
                onKeepScreenOn(call.argument<Boolean>("enabled") ?: false)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun pickFolder(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("BUSY", "a folder picker is already open", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
        pendingPick = result
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, REQUEST_PICK_TREE)
        } catch (e: Exception) {
            // ActivityNotFoundException, or a SecurityException and the
            // like from the system: the picker never opened.
            Log.w(TAG, "ride export folder picker failed", e)
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

    /**
     * Answers an open picker with null, stops the copy in progress and
     * shuts the background thread down (the activity is going away).
     */
    fun dispose() {
        val result = pendingPick
        pendingPick = null
        result?.success(null)
        cancelRequested.set(true)
        executor.shutdown()
    }

    /**
     * Finds or creates the export folder [name] in [treeUri], refuses it
     * when it holds a file not in [expectedNames], deletes an old manifest
     * and README there, and returns its document URI.
     */
    private fun prepareFolder(treeUri: Uri, name: String, expectedNames: Set<String>): String {
        val rootUri = DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )
        val root = queryDocument(rootUri)
            ?: throw ExportError("WRITE_FAILED", "cannot read the picked folder")
        val folderUri = if (root.name == name) {
            rootUri
        } else {
            listChildren(rootUri).firstOrNull { it.isDirectory && it.name == name }?.uri
                ?: createChecked(root, DocumentsContract.Document.MIME_TYPE_DIR, name)
        }
        val files = listChildren(folderUri).filter { !it.isDirectory }
        val stranger = files.firstOrNull { it.name == null || it.name !in expectedNames }
        if (stranger != null) {
            throw ExportError("FOLDER_NOT_EMPTY", "the folder holds ${stranger.name}")
        }
        for (file in files) {
            if (file.name == MANIFEST_NAME || file.name == README_NAME) {
                if (!deleteDocument(file.uri)) {
                    throw ExportError("WRITE_FAILED", "cannot delete the old ${file.name}")
                }
            }
        }
        return folderUri.toString()
    }

    /**
     * Copies [source] into the folder [folderUri] as [name], or skips it
     * when an equal file is there (never with [replace]); see the class
     * comment.
     */
    private fun exportFile(
        folderUri: Uri,
        source: File,
        name: String,
        mimeType: String,
        replace: Boolean,
    ): Map<String, Any> {
        if (!source.isFile) {
            throw ExportError("SOURCE_NOT_FOUND", "source file not found")
        }
        val folder = queryDocument(folderUri)
            ?: throw ExportError("WRITE_FAILED", "cannot read the export folder")
        val existing = listChildren(folderUri).firstOrNull { !it.isDirectory && it.name == name }
        if (existing != null) {
            if (!replace) {
                val sourceLength = source.length()
                val knownSize = existing.size
                if (knownSize == null || knownSize >= sourceLength) {
                    val copy = hashDocument(existing.uri)
                    if (copy.bytes == sourceLength) {
                        val sourceDigest = hashSource(source)
                        if (sourceDigest.bytes == copy.bytes && sourceDigest.sha256 == copy.sha256) {
                            return mapOf(
                                "bytes" to sourceDigest.bytes,
                                "sourceSha256" to sourceDigest.sha256,
                                "copySha256" to copy.sha256,
                                "skipped" to true,
                                "synced" to true,
                            )
                        }
                        throw ExportError("EXISTS_DIFFERENT", "a different $name is already in the folder")
                    }
                    // A killed run only ever leaves a shorter copy. A longer one
                    // may be the only intact copy of a clip that has changed on
                    // the phone since: never replace it.
                    if (copy.bytes > sourceLength) {
                        throw ExportError("EXISTS_DIFFERENT", "a longer $name is already in the folder")
                    }
                }
            }
            // Shorter than the source (a partial copy left by a killed
            // run), or a trimmed copy made again ([replace]).
            if (!deleteDocument(existing.uri)) {
                throw ExportError("WRITE_FAILED", "cannot replace the existing $name")
            }
        }
        val input = openSource(source)
        val created = try {
            createChecked(folder, mimeType, name)
        } catch (e: Exception) {
            closeQuietly(input)
            throw e
        }
        return try {
            val (written, synced) = input.use { writeDocument(created, it) }
            val copy = hashDocument(created)
            if (copy.bytes != written.bytes || copy.sha256 != written.sha256) {
                throw ExportError(
                    "COPY_MISMATCH",
                    "the copy of $name read back as ${copy.bytes} bytes, ${copy.sha256}",
                )
            }
            mapOf(
                "bytes" to written.bytes,
                "sourceSha256" to written.sha256,
                "copySha256" to copy.sha256,
                "skipped" to false,
                "synced" to synced,
            )
        } catch (e: Exception) {
            deleteDocument(created)
            throw e
        }
    }

    /**
     * Streams [input] into the new document [target], flushes and (for a
     * regular file) syncs it, and closes it. Returns the source digest and
     * whether the copy was synced.
     */
    private fun writeDocument(target: Uri, input: InputStream): Pair<Digested, Boolean> {
        val descriptor = activity.contentResolver.openFileDescriptor(target, "w")
            ?: throw ExportError("WRITE_FAILED", "cannot open the copy for writing")
        val outcome = try {
            // Does not own the descriptor; closing it is left to [descriptor].
            val output = FileOutputStream(descriptor.fileDescriptor)
            val written = digest(input, output)
            output.flush()
            Pair(written, syncIfRegular(descriptor))
        } catch (e: Exception) {
            closeQuietly(descriptor)
            throw e
        }
        try {
            descriptor.close()
        } catch (e: Exception) {
            throw ExportError("WRITE_FAILED", "closing the copy failed: ${e.message}")
        }
        return outcome
    }

    /**
     * Syncs [descriptor] when it is a regular file and returns true; returns
     * false for a pipe, a socket or any other type, or when `fstat` fails.
     * A failed sync of a regular file is `WRITE_FAILED`.
     */
    private fun syncIfRegular(descriptor: ParcelFileDescriptor): Boolean {
        val mode = try {
            Os.fstat(descriptor.fileDescriptor).st_mode
        } catch (e: Exception) {
            Log.w(TAG, "ride export fstat failed", e)
            return false
        }
        if (!OsConstants.S_ISREG(mode)) {
            return false
        }
        try {
            descriptor.fileDescriptor.sync()
        } catch (e: Exception) {
            throw ExportError("WRITE_FAILED", "sync failed: ${e.message}")
        }
        return true
    }

    /**
     * Writes [source] from [startUs] to [endUs] into [target] without
     * re-encoding and returns `{bytes, firstUs, lastUs}`; see the class
     * comment.
     */
    private fun trimClip(source: File, target: File, startUs: Long, endUs: Long): Map<String, Any> {
        val exportRoot = File(activity.cacheDir, EXPORT_CACHE_DIR).canonicalFile
        val output = target.canonicalFile
        if (!output.path.startsWith(exportRoot.path + File.separator)) {
            throw ExportError("INVALID_ARGS", "targetPath must be under the export cache")
        }
        if (!source.isFile) {
            throw ExportError("SOURCE_NOT_FOUND", "source file not found")
        }
        output.parentFile?.mkdirs()
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        var started = false
        var finished = false
        var firstUs = -1L
        var lastUs = -1L
        try {
            extractor.setDataSource(source.path)
            var videoTrack = -1
            var audioTrack = -1
            for (track in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(track).getString(MediaFormat.KEY_MIME) ?: continue
                if (videoTrack < 0 && mime.startsWith("video/")) {
                    videoTrack = track
                } else if (audioTrack < 0 && mime.startsWith("audio/")) {
                    audioTrack = track
                }
            }
            if (videoTrack < 0) {
                throw ExportError("TRIM_FAILED", "the clip has no video track")
            }
            val tracks = if (audioTrack < 0) listOf(videoTrack) else listOf(videoTrack, audioTrack)

            // The keyframe first, with only the video selected; then the
            // audio from that keyframe, not from startUs.
            extractor.selectTrack(videoTrack)
            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            firstUs = extractor.sampleTime
            if (firstUs < 0 || firstUs > endUs) {
                throw ExportError("TRIM_FAILED", "no video keyframe before $endUs us")
            }
            if (audioTrack >= 0) {
                extractor.selectTrack(audioTrack)
                extractor.seekTo(firstUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            }

            val rotation = readRotation(source)
            val mux = MediaMuxer(output.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = mux
            if (rotation == 90 || rotation == 180 || rotation == 270) {
                mux.setOrientationHint(rotation)
            }
            val muxTracks = IntArray(extractor.trackCount) { -1 }
            var largestSample = 0
            var sizeUnreported = false
            for (track in tracks) {
                val format = extractor.getTrackFormat(track)
                muxTracks[track] = mux.addTrack(format)
                if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                    largestSample = maxOf(largestSample, format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
                } else {
                    sizeUnreported = true
                }
            }
            // A 4K keyframe can exceed 1 MiB and a too small buffer fails the
            // read, so any track without a reported size gets the fallback.
            val buffer = ByteBuffer.allocate(
                maxOf(largestSample, BUFFER_BYTES, if (sizeUnreported) TRIM_FALLBACK_SAMPLE_BYTES else 0),
            )
            mux.start()
            started = true

            val info = MediaCodec.BufferInfo()
            val ended = BooleanArray(extractor.trackCount)
            var open = tracks.size
            lastUs = firstUs
            while (open > 0) {
                if (cancelRequested.get()) {
                    throw ExportError("CANCELLED", "export cancelled")
                }
                val track = extractor.sampleTrackIndex
                if (track < 0) {
                    break
                }
                val timeUs = extractor.sampleTime
                if (ended[track]) {
                    // Still delivered after unselectTrack: skip it.
                    extractor.advance()
                    continue
                }
                if (timeUs > endUs) {
                    ended[track] = true
                    open--
                    extractor.unselectTrack(track)
                    continue
                }
                // Samples before the keyframe (audio, or leading frames of an
                // open GOP) are dropped, so no rebased time is negative.
                if (timeUs >= firstUs) {
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0) {
                        break
                    }
                    val keyFrame = extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0
                    info.set(
                        0,
                        size,
                        timeUs - firstUs,
                        if (keyFrame) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0,
                    )
                    mux.writeSampleData(muxTracks[track], buffer, info)
                    if (timeUs > lastUs) {
                        lastUs = timeUs
                    }
                }
                extractor.advance()
            }
            mux.stop()
            finished = true
        } finally {
            releaseQuietly("extractor") { extractor.release() }
            muxer?.let { mux ->
                // After a cancel or error the muxer is still started, and
                // release() would call stop() itself: a throwing stop() there
                // skips the native release. Stop it first, on its own.
                if (started && !finished) {
                    releaseQuietly("muxer stop") { mux.stop() }
                }
                releaseQuietly("muxer") { mux.release() }
            }
            if (!finished) {
                output.delete()
            }
        }
        return mapOf("bytes" to output.length(), "firstUs" to firstUs, "lastUs" to lastUs)
    }

    /** The video rotation of [source] in degrees (0 when not reported). */
    private fun readRotation(source: File): Int {
        // release(), not close(): close() exists only from API 29.
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(source.path)
            return retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toIntOrNull() ?: 0
        } finally {
            releaseQuietly("retriever") { retriever.release() }
        }
    }

    /** Runs [release], logging a failure (cleanup must not mask the result). */
    private inline fun releaseQuietly(what: String, release: () -> Unit) {
        try {
            release()
        } catch (e: Exception) {
            Log.w(TAG, "ride export $what release failed", e)
        }
    }

    /** Returns `{bytes, sha256}` of the private file [file]. */
    private fun hashFile(file: File): Map<String, Any> {
        if (!file.isFile) {
            throw ExportError("SOURCE_NOT_FOUND", "file not found")
        }
        val digested = hashSource(file)
        return mapOf("bytes" to digested.bytes, "sha256" to digested.sha256)
    }

    /** Hashes the private file [file] (cancellable). */
    private fun hashSource(file: File): Digested = openSource(file).use { digest(it, null) }

    /** Opens [file] for reading; a missing file is `SOURCE_NOT_FOUND`. */
    private fun openSource(file: File): FileInputStream = try {
        FileInputStream(file)
    } catch (e: FileNotFoundException) {
        throw ExportError("SOURCE_NOT_FOUND", "source file not found")
    }

    /** Reads the document [uri] back through the resolver and hashes it. */
    private fun hashDocument(uri: Uri): Digested {
        val input = activity.contentResolver.openInputStream(uri)
            ?: throw ExportError("WRITE_FAILED", "cannot read the copy back")
        return input.use { digest(it, null) }
    }

    /**
     * The one read loop of ride export: reads [input] to its end in 1 MiB
     * buffers, writes each buffer to [output] when given, and digests it
     * with SHA-256. The cancel flag is checked before every buffer
     * (`CANCELLED`).
     */
    private fun digest(input: InputStream, output: OutputStream?): Digested {
        val sha256 = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(BUFFER_BYTES)
        var total = 0L
        while (true) {
            if (cancelRequested.get()) {
                throw ExportError("CANCELLED", "export cancelled")
            }
            val read = input.read(buffer)
            if (read < 0) {
                break
            }
            sha256.update(buffer, 0, read)
            output?.write(buffer, 0, read)
            total += read
        }
        return Digested(total, toHex(sha256.digest()))
    }

    /**
     * Creates the document [name] of [mimeType] in [parent] and checks that
     * the provider kept the name exactly (a provider renames on a clash).
     */
    private fun createChecked(parent: Document, mimeType: String, name: String): Uri {
        if (parent.flags and DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE == 0) {
            throw ExportError("NOT_WRITABLE", "the folder does not accept new files")
        }
        val created = DocumentsContract.createDocument(
            activity.contentResolver,
            parent.uri,
            mimeType,
            name,
        ) ?: throw ExportError("NOT_WRITABLE", "the folder app did not create $name")
        val createdName = try {
            queryDocument(created)?.name
        } catch (e: Exception) {
            deleteDocument(created)
            throw e
        }
        if (createdName != name) {
            deleteDocument(created)
            throw ExportError("NAME_CONFLICT", "the folder app named $name as $createdName")
        }
        return created
    }

    /** The document [uri] itself, or null when the provider returns no row. */
    private fun queryDocument(uri: Uri): Document? {
        activity.contentResolver.query(uri, DOCUMENT_PROJECTION, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                return readDocument(cursor, uri)
            }
        }
        return null
    }

    /** The direct children of the directory document [folderUri]. */
    private fun listChildren(folderUri: Uri): List<Document> {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            folderUri,
            DocumentsContract.getDocumentId(folderUri),
        )
        val cursor = activity.contentResolver.query(
            childrenUri,
            DOCUMENT_PROJECTION,
            null,
            null,
            null,
        ) ?: throw ExportError("WRITE_FAILED", "cannot list the folder")
        val children = mutableListOf<Document>()
        cursor.use {
            while (it.moveToNext()) {
                val documentId = it.getString(0) ?: continue
                children.add(
                    readDocument(
                        it,
                        DocumentsContract.buildDocumentUriUsingTree(folderUri, documentId),
                    ),
                )
            }
        }
        return children
    }

    /** Reads the current row of a [DOCUMENT_PROJECTION] cursor. */
    private fun readDocument(cursor: Cursor, uri: Uri): Document = Document(
        uri = uri,
        name = cursor.getString(1),
        mimeType = cursor.getString(2),
        size = if (cursor.isNull(3)) null else cursor.getLong(3),
        flags = if (cursor.isNull(4)) 0 else cursor.getInt(4),
    )

    /** Deletes the document [uri]; returns false (and logs) on failure. */
    private fun deleteDocument(uri: Uri): Boolean = try {
        DocumentsContract.deleteDocument(activity.contentResolver, uri)
    } catch (e: Exception) {
        Log.w(TAG, "ride export deleteDocument failed", e)
        false
    }

    /**
     * Opens the share sheet with [paths] as FileProvider URIs; see the
     * class comment. Runs on the main thread.
     */
    private fun shareFiles(paths: List<String>, mimeTypes: List<String>, subject: String): Boolean {
        val authority = activity.packageName + ".fileprovider"
        val uris = ArrayList<Uri>()
        for (path in paths) {
            val uri = try {
                FileProvider.getUriForFile(activity, authority, File(path))
            } catch (e: IllegalArgumentException) {
                throw ExportError("NOT_SHAREABLE", "$path is outside the shareable folders")
            }
            uris.add(uri)
        }
        val shareType = mimeTypes.distinct().singleOrNull() ?: "*/*"
        val clip = ClipData.newRawUri(subject, uris[0])
        for (uri in uris.drop(1)) {
            clip.addItem(ClipData.Item(uri))
        }
        val send = Intent(Intent.ACTION_SEND_MULTIPLE).apply {
            setType(shareType)
            putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
            putExtra(Intent.EXTRA_SUBJECT, subject)
            clipData = clip
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            activity.startActivity(Intent.createChooser(send, null))
        } catch (e: ActivityNotFoundException) {
            throw ExportError("NO_TARGET", "no app can receive the files")
        }
        return true
    }

    /** Lowercase hex of [bytes], independent of the locale. */
    private fun toHex(bytes: ByteArray): String {
        val out = StringBuilder(bytes.size * 2)
        for (byte in bytes) {
            val value = byte.toInt() and 0xff
            out.append(HEX_DIGITS[value ushr 4])
            out.append(HEX_DIGITS[value and 0x0f])
        }
        return out.toString()
    }

    /** Closes [closeable], ignoring a failure (an error path is running). */
    private fun closeQuietly(closeable: java.io.Closeable) {
        try {
            closeable.close()
        } catch (_: Exception) {
        }
    }

    /**
     * Runs [work] on the export thread and posts its value to the main
     * thread; an [ExportError] keeps its code, any other failure gets
     * [fallbackCode] with its message.
     */
    private fun runInBackground(
        result: MethodChannel.Result,
        fallbackCode: String,
        work: () -> Any?,
    ) {
        // Every path answers [result] exactly once: an Error (for example
        // OutOfMemoryError) too, and a call refused after [dispose].
        try {
            executor.execute {
                try {
                    val value = work()
                    mainHandler.post { result.success(value) }
                } catch (e: ExportError) {
                    if (e.code != "CANCELLED") {
                        Log.w(TAG, "ride export ${e.code}: ${e.message}")
                    }
                    mainHandler.post { result.error(e.code, e.message, null) }
                } catch (e: Throwable) {
                    Log.e(TAG, "ride export $fallbackCode", e)
                    mainHandler.post { result.error(fallbackCode, e.message, null) }
                }
            }
        } catch (e: RejectedExecutionException) {
            Log.w(TAG, "ride export $fallbackCode: the export thread is shut down")
            result.error(fallbackCode, "the export thread is shut down", null)
        }
    }
}
