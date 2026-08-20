package com.huddlecommunity.better_native_video_player.manager

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.PlaceholderDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.NoOpCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.offline.DownloadHelper
import androidx.media3.exoplayer.offline.DownloadManager
import androidx.media3.exoplayer.scheduler.Requirements
import com.huddlecommunity.better_native_video_player.NpLog
import com.huddlecommunity.better_native_video_player.drm.OfflineWidevineLicenseManager
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

/**
 * Offline asset downloads (encrypted HLS + persistent Widevine license).
 *
 * One process-lifetime Media3 [DownloadManager] over a dedicated downloads
 * [SimpleCache] — deliberately separate from [VideoCacheManager]'s streaming
 * cache: the streaming cache is LRU-evicted scratch space, while downloads
 * must survive until explicitly removed ([NoOpCacheEvictor], app files dir).
 *
 * Runs in-process (no DownloadService in phase 1): a process kill stalls an
 * active download, and [resumeDownloads] at plugin attach resumes it on the
 * next launch.
 *
 * Exposed to Dart through the plugin-level channels
 * `better_native_video_player/downloads` (methods) and
 * `better_native_video_player/download_events` (events). License key material
 * (keySetId) stays inside the download index and never crosses the channel.
 */
@UnstableApi
object AssetDownloadManager {
    private const val TAG = "AssetDownloadManager"

    /** Subdirectory of the app files dir (NOT cacheDir — must not be evicted). */
    private const val DOWNLOAD_DIR_NAME = "bnvp_downloads"

    private const val MAX_PARALLEL_DOWNLOADS = 2
    private const val PROGRESS_INTERVAL_MS = 500L

    private val mainHandler = Handler(Looper.getMainLooper())

    // Blocking CDM/network work (offline license download/renew/release).
    private val licenseExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "bnvp-offline-license")
    }

    @Volatile
    private var downloadManager: DownloadManager? = null
    private var downloadCache: SimpleCache? = null
    private var appContext: Context? = null

    // DownloadHelpers still preparing (manifest fetch/track mapping) keyed by
    // download id, so a cancel/remove during prepare can abort them.
    private val pendingPrepares = mutableMapOf<String, DownloadHelper>()

    // Ids whose offline license fetch is in flight (they are no longer in
    // pendingPrepares at that point) and ids canceled during that window; the
    // fetch completion must not enqueue a canceled id. Main-thread only.
    private val licenseFetchesInFlight = mutableSetOf<String>()
    private val canceledDuringLicenseFetch = mutableSetOf<String>()

    private var eventSink: EventChannel.EventSink? = null

    /** StreamHandler for `better_native_video_player/download_events`. */
    val eventStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            eventSink = events
        }

        override fun onCancel(arguments: Any?) {
            eventSink = null
        }
    }

    /**
     * Creates the download manager on first use and resumes any downloads
     * interrupted by a previous process death. Must be called on the main
     * thread (the DownloadManager binds its listeners to the calling looper).
     */
    @Synchronized
    fun initialize(context: Context) {
        if (downloadManager != null) return
        val app = context.applicationContext
        appContext = app
        try {
            val databaseProvider = Media3DatabaseProvider.get(app)
            val cache = SimpleCache(
                File(app.filesDir, DOWNLOAD_DIR_NAME),
                NoOpCacheEvictor(),
                databaseProvider
            )
            downloadCache = cache
            val manager = DownloadManager(
                app,
                databaseProvider,
                cache,
                DefaultHttpDataSource.Factory(),
                Executors.newFixedThreadPool(MAX_PARALLEL_DOWNLOADS * 3)
            )
            manager.maxParallelDownloads = MAX_PARALLEL_DOWNLOADS
            manager.requirements = Requirements(Requirements.NETWORK)
            manager.addListener(downloadListener)
            downloadManager = manager
            manager.resumeDownloads()
            NpLog.d(TAG, "Download manager initialized (resuming interrupted downloads)")
        } catch (e: Exception) {
            NpLog.e(TAG, "Download manager initialization failed: ${e.message}", e)
        }
    }

    /**
     * The completed [Download] for [id], or null when the id is unknown or
     * the download has not finished.
     */
    fun getCompletedDownload(context: Context, id: String): Download? {
        initialize(context)
        val manager = downloadManager ?: return null
        return try {
            manager.downloadIndex.getDownload(id)
                ?.takeIf { it.state == Download.STATE_COMPLETED }
        } catch (e: IOException) {
            NpLog.e(TAG, "Failed to read download index: ${e.message}", e)
            null
        }
    }

    /**
     * Read-only data source factory over the downloads cache for offline
     * playback: writes are disabled and the upstream throws on open, so a
     * missing segment fails fast instead of silently reaching for the
     * network — offline playback is guaranteed to be zero-network.
     */
    fun buildOfflinePlaybackDataSourceFactory(): DataSource.Factory {
        val cache = checkNotNull(downloadCache) { "Downloads cache not initialized" }
        return CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory(DataSource.Factory { PlaceholderDataSource.INSTANCE })
            .setCacheWriteDataSinkFactory(null)
    }

    // MARK: - Method channel

    /** Handler for `better_native_video_player/downloads`. */
    fun handleMethodCall(context: Context, call: MethodCall, result: MethodChannel.Result) {
        initialize(context)
        val manager = downloadManager
        if (manager == null) {
            result.error("DOWNLOADS_UNAVAILABLE", "Download manager failed to initialize", null)
            return
        }
        val args = call.arguments as? Map<*, *>
        when (call.method) {
            "startDownload" -> handleStartDownload(context, manager, args, result)
            "cancelDownload", "removeDownload" -> handleRemoveDownload(manager, args, result)
            "getDownloads" -> handleGetDownloads(manager, result)
            "getLicenseInfo" -> handleGetLicenseInfo(manager, args, result)
            "renewLicense" -> handleRenewLicense(manager, args, result)
            else -> result.notImplemented()
        }
    }

    private fun handleStartDownload(
        context: Context,
        manager: DownloadManager,
        args: Map<*, *>?,
        result: MethodChannel.Result
    ) {
        val id = args?.get("id") as? String
        val url = args?.get("url") as? String
        if (id == null || url == null) {
            result.error("INVALID_ARGUMENT", "id and url are required", null)
            return
        }
        @Suppress("UNCHECKED_CAST")
        val headers = args["headers"] as? Map<String, String>
        val drm = args["drm"] as? Map<*, *>

        val existing = try {
            manager.downloadIndex.getDownload(id)
        } catch (e: IOException) {
            null
        }
        if (existing != null && existing.state == Download.STATE_COMPLETED) {
            sendEvent(downloadEventMap(existing))
            result.success(null)
            return
        }
        if (pendingPrepares.containsKey(id)) {
            // Prepare already in flight for this id; the original call's
            // events cover this one too.
            result.success(null)
            return
        }

        val httpFactory = DefaultHttpDataSource.Factory()
        if (headers != null) {
            httpFactory.setDefaultRequestProperties(headers)
        }
        val mediaItem = MediaItem.Builder()
            .setMediaId(id)
            .setUri(url)
            .build()

        val helper = DownloadHelper.forMediaItem(
            context.applicationContext,
            mediaItem,
            DefaultRenderersFactory(context.applicationContext),
            httpFactory
        )
        pendingPrepares[id] = helper
        sendEvent(
            mapOf(
                "id" to id,
                "status" to "queued",
                "bytesDownloaded" to 0L
            )
        )
        // The channel reply only acknowledges enqueueing; progress and the
        // terminal state stream over the event channel.
        result.success(null)

        helper.prepare(object : DownloadHelper.Callback {
            override fun onPrepared(preparedHelper: DownloadHelper) {
                if (pendingPrepares.remove(id) == null) {
                    // Canceled while preparing.
                    preparedHelper.release()
                    return
                }
                if (drm == null) {
                    manager.addDownload(preparedHelper.getDownloadRequest(id, null))
                    preparedHelper.release()
                    return
                }
                downloadLicenseAndEnqueue(manager, preparedHelper, id, drm)
            }

            override fun onPrepareError(preparedHelper: DownloadHelper, e: IOException) {
                pendingPrepares.remove(id)
                preparedHelper.release()
                NpLog.e(TAG, "Download prepare failed for $id: ${e.message}", e)
                sendEvent(
                    mapOf(
                        "id" to id,
                        "status" to "failed",
                        "bytesDownloaded" to 0L,
                        "error" to (e.message ?: "Failed to prepare download")
                    )
                )
            }
        })
    }

    /**
     * Fetches the persistent offline Widevine license for the prepared
     * download, then enqueues the segment download with the resulting
     * keySetId attached to its [androidx.media3.exoplayer.offline.DownloadRequest].
     */
    private fun downloadLicenseAndEnqueue(
        manager: DownloadManager,
        helper: DownloadHelper,
        id: String,
        drm: Map<*, *>
    ) {
        val licenseUrl = drm["licenseUrl"] as? String
        @Suppress("UNCHECKED_CAST")
        val drmHeaders = drm["headers"] as? Map<String, String>
        if (licenseUrl == null) {
            helper.release()
            sendEvent(
                mapOf(
                    "id" to id,
                    "status" to "failed",
                    "bytesDownloaded" to 0L,
                    "error" to "drm.licenseUrl is required"
                )
            )
            return
        }
        val format = firstFormatWithDrmInitData(helper)
        if (format == null) {
            helper.release()
            sendEvent(
                mapOf(
                    "id" to id,
                    "status" to "failed",
                    "bytesDownloaded" to 0L,
                    "error" to "Content has no DRM protection (no drmInitData found)"
                )
            )
            return
        }
        licenseFetchesInFlight.add(id)
        licenseExecutor.execute {
            try {
                val keySetId =
                    OfflineWidevineLicenseManager.downloadLicense(format, licenseUrl, drmHeaders)
                mainHandler.post {
                    licenseFetchesInFlight.remove(id)
                    if (canceledDuringLicenseFetch.remove(id)) {
                        // Canceled while the license was being fetched: release
                        // the license again instead of enqueueing the download.
                        helper.release()
                        licenseExecutor.execute {
                            OfflineWidevineLicenseManager.releaseLicense(keySetId)
                        }
                        return@post
                    }
                    manager.addDownload(
                        helper.getDownloadRequest(id, null).copyWithKeySetId(keySetId)
                    )
                    helper.release()
                }
            } catch (e: Exception) {
                NpLog.e(TAG, "Offline license download failed for $id: ${e.message}", e)
                mainHandler.post {
                    licenseFetchesInFlight.remove(id)
                    canceledDuringLicenseFetch.remove(id)
                    helper.release()
                    sendEvent(
                        mapOf(
                            "id" to id,
                            "status" to "failed",
                            "bytesDownloaded" to 0L,
                            "error" to "License download failed: ${e.message}"
                        )
                    )
                }
            }
        }
    }

    private fun firstFormatWithDrmInitData(helper: DownloadHelper): androidx.media3.common.Format? {
        for (periodIndex in 0 until helper.periodCount) {
            val mappedTrackInfo = helper.getMappedTrackInfo(periodIndex)
            for (rendererIndex in 0 until mappedTrackInfo.rendererCount) {
                val trackGroups = mappedTrackInfo.getTrackGroups(rendererIndex)
                for (groupIndex in 0 until trackGroups.length) {
                    val trackGroup = trackGroups[groupIndex]
                    for (formatIndex in 0 until trackGroup.length) {
                        val format = trackGroup.getFormat(formatIndex)
                        if (format.drmInitData != null) return format
                    }
                }
            }
        }
        return null
    }

    /**
     * Cancel and remove are the same operation: release the offline license,
     * drop the cached segments, forget the index entry. A cancel mid-prepare
     * additionally aborts the DownloadHelper.
     */
    private fun handleRemoveDownload(
        manager: DownloadManager,
        args: Map<*, *>?,
        result: MethodChannel.Result
    ) {
        val id = args?.get("id") as? String
        if (id == null) {
            result.error("INVALID_ARGUMENT", "id is required", null)
            return
        }
        pendingPrepares.remove(id)?.let { helper ->
            helper.release()
            sendEvent(mapOf("id" to id, "status" to "removed", "bytesDownloaded" to 0L))
        }
        if (licenseFetchesInFlight.contains(id)) {
            canceledDuringLicenseFetch.add(id)
            sendEvent(mapOf("id" to id, "status" to "removed", "bytesDownloaded" to 0L))
        }
        val keySetId = try {
            manager.downloadIndex.getDownload(id)?.request?.keySetId
        } catch (e: IOException) {
            null
        }
        if (keySetId != null) {
            licenseExecutor.execute { OfflineWidevineLicenseManager.releaseLicense(keySetId) }
        }
        manager.removeDownload(id)
        result.success(null)
    }

    private fun handleGetDownloads(manager: DownloadManager, result: MethodChannel.Result) {
        try {
            val downloads = mutableListOf<Map<String, Any?>>()
            manager.downloadIndex.getDownloads().use { cursor ->
                while (cursor.moveToNext()) {
                    downloads.add(downloadEventMap(cursor.download))
                }
            }
            result.success(downloads)
        } catch (e: IOException) {
            result.error("INDEX_ERROR", "Failed to read download index: ${e.message}", null)
        }
    }

    private fun handleGetLicenseInfo(
        manager: DownloadManager,
        args: Map<*, *>?,
        result: MethodChannel.Result
    ) {
        val id = args?.get("id") as? String
        if (id == null) {
            result.error("INVALID_ARGUMENT", "id is required", null)
            return
        }
        val keySetId = try {
            manager.downloadIndex.getDownload(id)?.request?.keySetId
        } catch (e: IOException) {
            null
        }
        if (keySetId == null) {
            result.success(mapOf("valid" to false))
            return
        }
        licenseExecutor.execute {
            val response: Map<String, Any?> = try {
                val remainingSec =
                    OfflineWidevineLicenseManager.getLicenseDurationRemainingSec(keySetId)
                mapOf(
                    "valid" to (remainingSec > 0),
                    "licenseDurationRemainingSec" to remainingSec,
                    "expiresAtMs" to if (remainingSec == Long.MAX_VALUE) {
                        null
                    } else {
                        System.currentTimeMillis() + remainingSec * 1000
                    }
                )
            } catch (e: Exception) {
                NpLog.w(TAG, "License info query failed for $id: ${e.message}")
                mapOf("valid" to false)
            }
            mainHandler.post { result.success(response) }
        }
    }

    private fun handleRenewLicense(
        manager: DownloadManager,
        args: Map<*, *>?,
        result: MethodChannel.Result
    ) {
        val id = args?.get("id") as? String
        val drm = args?.get("drm") as? Map<*, *>
        val licenseUrl = drm?.get("licenseUrl") as? String
        if (id == null || licenseUrl == null) {
            result.error("INVALID_ARGUMENT", "id and drm.licenseUrl are required", null)
            return
        }
        @Suppress("UNCHECKED_CAST")
        val drmHeaders = drm["headers"] as? Map<String, String>
        val download = try {
            manager.downloadIndex.getDownload(id)
        } catch (e: IOException) {
            null
        }
        val keySetId = download?.request?.keySetId
        if (download == null || keySetId == null) {
            result.error("NO_LICENSE", "No offline license found for download $id", null)
            return
        }
        licenseExecutor.execute {
            try {
                val renewedKeySetId =
                    OfflineWidevineLicenseManager.renewLicense(licenseUrl, drmHeaders, keySetId)
                mainHandler.post {
                    // addDownload with the same id merges the request, storing
                    // the renewed keySetId; the re-queued download re-verifies
                    // against the (fully cached) segments and completes fast.
                    manager.addDownload(download.request.copyWithKeySetId(renewedKeySetId))
                    result.success(null)
                }
            } catch (e: Exception) {
                NpLog.e(TAG, "License renewal failed for $id: ${e.message}", e)
                mainHandler.post {
                    result.error("RENEW_FAILED", "License renewal failed: ${e.message}", null)
                }
            }
        }
    }

    // MARK: - Events

    private val downloadListener = object : DownloadManager.Listener {
        override fun onDownloadChanged(
            manager: DownloadManager,
            download: Download,
            finalException: Exception?
        ) {
            sendEvent(downloadEventMap(download, finalException))
            if (download.state == Download.STATE_DOWNLOADING) {
                startProgressUpdates()
            }
        }

        override fun onDownloadRemoved(manager: DownloadManager, download: Download) {
            sendEvent(
                mapOf(
                    "id" to download.request.id,
                    "status" to "removed",
                    "bytesDownloaded" to 0L
                )
            )
        }
    }

    private var progressRunnable: Runnable? = null

    /**
     * Media3 only fires onDownloadChanged on state transitions; fraction and
     * byte progress are polled from [DownloadManager.getCurrentDownloads]
     * while anything is actively downloading.
     */
    private fun startProgressUpdates() {
        if (progressRunnable != null) return
        val runnable = object : Runnable {
            override fun run() {
                val manager = downloadManager ?: run { progressRunnable = null; return }
                val active = manager.currentDownloads
                    .filter { it.state == Download.STATE_DOWNLOADING }
                for (download in active) {
                    sendEvent(downloadEventMap(download))
                }
                if (active.isEmpty()) {
                    progressRunnable = null
                } else {
                    mainHandler.postDelayed(this, PROGRESS_INTERVAL_MS)
                }
            }
        }
        progressRunnable = runnable
        mainHandler.postDelayed(runnable, PROGRESS_INTERVAL_MS)
    }

    private fun downloadEventMap(
        download: Download,
        finalException: Exception? = null
    ): Map<String, Any?> {
        val percent = download.percentDownloaded
        return mapOf(
            "id" to download.request.id,
            "status" to statusName(download.state),
            "fraction" to if (percent == C.PERCENTAGE_UNSET.toFloat()) {
                null
            } else {
                (percent / 100f).toDouble()
            },
            "bytesDownloaded" to download.bytesDownloaded,
            "error" to finalException?.message?.takeIf { download.state == Download.STATE_FAILED }
        )
    }

    /** Maps a [Download] state to the cross-platform channel status string. */
    internal fun statusName(state: Int): String = when (state) {
        Download.STATE_DOWNLOADING -> "downloading"
        Download.STATE_COMPLETED -> "completed"
        Download.STATE_FAILED -> "failed"
        Download.STATE_REMOVING -> "removed"
        // QUEUED, STOPPED, RESTARTING: not started or waiting to (re)start.
        else -> "queued"
    }

    private fun sendEvent(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            eventSink?.success(event)
        } else {
            mainHandler.post { eventSink?.success(event) }
        }
    }
}
