package com.huddlecommunity.better_native_video_player.drm

import androidx.media3.common.Format
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.drm.DrmSessionEventListener
import androidx.media3.exoplayer.drm.OfflineLicenseHelper
import com.huddlecommunity.better_native_video_player.NpLog

/**
 * Offline Widevine license operations for downloaded assets.
 *
 * The license key material never leaves the platform: [downloadLicense]
 * returns a `keySetId` (an opaque CDM handle, not the keys themselves) that
 * is persisted inside the Media3 download index via
 * `DownloadRequest.copyWithKeySetId`, and restored at playback with
 * `DefaultDrmSessionManager.MODE_PLAYBACK`.
 *
 * All methods block on CDM and/or network work — call from a background
 * thread, never from main.
 */
@UnstableApi
object OfflineWidevineLicenseManager {
    private const val TAG = "OfflineWidevineLicense"

    /**
     * Requests a persistent offline license for [format] (which must carry
     * `drmInitData`) from [licenseUrl] and returns the resulting keySetId.
     *
     * [headers] are applied to the license HTTP request — for DoveRunner/
     * PallyCon this is where `pallycon-customdata-v2` (carrying the
     * persistence policy token) rides.
     */
    fun downloadLicense(
        format: Format,
        licenseUrl: String,
        headers: Map<String, String>?
    ): ByteArray {
        val helper = newHelper(licenseUrl, headers)
        try {
            val keySetId = helper.downloadLicense(format)
            NpLog.d(TAG, "Downloaded offline license (${keySetId.size} byte keySetId)")
            return keySetId
        } finally {
            helper.release()
        }
    }

    /**
     * Renews the offline license identified by [keySetId] and returns the
     * replacement keySetId. The caller must persist the new id (the old one
     * is invalidated by the CDM as part of renewal).
     */
    fun renewLicense(
        licenseUrl: String,
        headers: Map<String, String>?,
        keySetId: ByteArray
    ): ByteArray {
        val helper = newHelper(licenseUrl, headers)
        try {
            val renewed = helper.renewLicense(keySetId)
            NpLog.d(TAG, "Renewed offline license (${renewed.size} byte keySetId)")
            return renewed
        } finally {
            helper.release()
        }
    }

    /**
     * Releases the offline license identified by [keySetId] (called when a
     * download is removed). Failures are logged and swallowed — a stale CDM
     * entry must not block removing the downloaded segments.
     */
    fun releaseLicense(keySetId: ByteArray) {
        val helper = newHelper(licenseUrl = "", headers = null)
        try {
            helper.releaseLicense(keySetId)
            NpLog.d(TAG, "Released offline license")
        } catch (e: Exception) {
            NpLog.w(TAG, "Failed to release offline license: ${e.message}")
        } finally {
            helper.release()
        }
    }

    /**
     * Remaining license validity in seconds for [keySetId], or `Long.MAX_VALUE`
     * when the license has no time restriction. Queries the CDM locally — no
     * network.
     */
    fun getLicenseDurationRemainingSec(keySetId: ByteArray): Long {
        val helper = newHelper(licenseUrl = "", headers = null)
        return try {
            // Pair of (license duration, playback duration) remaining; the
            // effective validity is the smaller of the two.
            val remaining = helper.getLicenseDurationRemainingSec(keySetId)
            minOf(remaining.first, remaining.second)
        } finally {
            helper.release()
        }
    }

    private fun newHelper(
        licenseUrl: String,
        headers: Map<String, String>?
    ): OfflineLicenseHelper {
        val httpFactory = DefaultHttpDataSource.Factory()
        if (headers != null) {
            httpFactory.setDefaultRequestProperties(headers)
        }
        return OfflineLicenseHelper.newWidevineInstance(
            licenseUrl,
            /* forceDefaultLicenseUrl= */ false,
            httpFactory,
            DrmSessionEventListener.EventDispatcher()
        )
    }
}
