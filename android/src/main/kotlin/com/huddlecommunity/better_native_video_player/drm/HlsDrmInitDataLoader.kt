package com.huddlecommunity.better_native_video_player.drm

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.DrmInitData
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.UriUtil
import androidx.media3.common.util.Util
import androidx.media3.datasource.DataSourceInputStream
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.hls.playlist.HlsMediaPlaylist
import androidx.media3.exoplayer.hls.playlist.HlsMultivariantPlaylist
import androidx.media3.exoplayer.hls.playlist.HlsPlaylist
import androidx.media3.exoplayer.hls.playlist.HlsPlaylistParser
import androidx.media3.extractor.mp4.PsshAtomUtil
import com.huddlecommunity.better_native_video_player.NpLog
import java.nio.ByteBuffer

/**
 * Finds the Widevine init data of an HLS stream for offline license
 * acquisition. `DownloadHelper` only sees the multivariant playlist, which
 * carries DRM signalling solely through `EXT-X-SESSION-KEY`; without one the
 * key lives in the media playlist's `EXT-X-KEY`, or only in the init
 * segment's `pssh` boxes (packagers that signal FairPlay alone in the
 * playlist). Blocking network I/O: call off the main thread.
 */
@UnstableApi
object HlsDrmInitDataLoader {
    private const val TAG = "HlsDrmInitDataLoader"

    fun load(url: String, headers: Map<String, String>?): Format? {
        val playlist = try {
            fetchPlaylist(Uri.parse(url), headers)
        } catch (e: Exception) {
            NpLog.w(TAG, "Not an HLS playlist or failed to load $url: ${e.message}")
            return null
        }
        val media = when (playlist) {
            is HlsMediaPlaylist -> playlist
            is HlsMultivariantPlaylist -> {
                val mediaUrl = playlist.mediaPlaylistUrls.firstOrNull() ?: return null
                fetchPlaylist(mediaUrl, headers) as? HlsMediaPlaylist ?: return null
            }
            else -> return null
        }

        widevineFromPlaylist(media)?.let { return formatWith(it, "EXT-X-KEY") }

        val initSegment = media.segments.firstOrNull()?.initializationSegment ?: return null
        val initUri = UriUtil.resolveToUri(media.baseUri, initSegment.url)
        val pssh = widevinePsshFromInitSegment(fetchBytes(initUri, headers)) ?: return null
        return formatWith(
            DrmInitData(DrmInitData.SchemeData(C.WIDEVINE_UUID, MimeTypes.VIDEO_MP4, pssh)),
            "init segment pssh"
        )
    }

    private fun widevineFromPlaylist(playlist: HlsMediaPlaylist): DrmInitData? {
        val candidates = listOfNotNull(playlist.protectionSchemes) +
            playlist.segments.mapNotNull { it.drmInitData }
        for (drmInitData in candidates) {
            for (i in 0 until drmInitData.schemeDataCount) {
                val schemeData = drmInitData.get(i)
                if (schemeData.matches(C.WIDEVINE_UUID) && schemeData.hasData()) {
                    return DrmInitData(schemeData)
                }
            }
        }
        return null
    }

    /** Walks the top-level boxes and `moov`, returning the first Widevine `pssh` box. */
    private fun widevinePsshFromInitSegment(bytes: ByteArray): ByteArray? {
        fun scan(start: Int, end: Int): ByteArray? {
            var offset = start
            while (offset + 8 <= end) {
                val buffer = ByteBuffer.wrap(bytes, offset, end - offset)
                var size = buffer.int.toLong() and 0xFFFFFFFFL
                val type = String(bytes, offset + 4, 4, Charsets.US_ASCII)
                var header = 8
                if (size == 1L) {
                    if (offset + 16 > end) return null
                    size = buffer.long
                    header = 16
                } else if (size == 0L) {
                    size = (end - offset).toLong()
                }
                if (size < header || offset + size > end) return null
                val boxEnd = offset + size.toInt()
                when (type) {
                    "moov" -> scan(offset + header, boxEnd)?.let { return it }
                    "pssh" -> {
                        val atom = bytes.copyOfRange(offset, boxEnd)
                        if (PsshAtomUtil.parseUuid(atom) == C.WIDEVINE_UUID) return atom
                    }
                }
                offset = boxEnd
            }
            return null
        }
        return scan(0, bytes.size)
    }

    private fun formatWith(drmInitData: DrmInitData, source: String): Format {
        NpLog.d(TAG, "Widevine init data found in $source")
        return Format.Builder()
            .setSampleMimeType(MimeTypes.AUDIO_AAC)
            .setDrmInitData(drmInitData)
            .build()
    }

    private fun fetchPlaylist(uri: Uri, headers: Map<String, String>?): HlsPlaylist =
        HlsPlaylistParser().parse(uri, fetchBytes(uri, headers).inputStream())

    private fun fetchBytes(uri: Uri, headers: Map<String, String>?): ByteArray {
        val factory = DefaultHttpDataSource.Factory()
        if (headers != null) factory.setDefaultRequestProperties(headers)
        DataSourceInputStream(factory.createDataSource(), DataSpec(uri)).use { stream ->
            return Util.toByteArray(stream)
        }
    }
}
