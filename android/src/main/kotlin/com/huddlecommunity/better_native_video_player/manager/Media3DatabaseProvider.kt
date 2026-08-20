package com.huddlecommunity.better_native_video_player.manager

import android.content.Context
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider

/**
 * Process-wide [StandaloneDatabaseProvider] shared by every Media3 component
 * in the plugin (streaming cache, downloads cache, download index).
 *
 * StandaloneDatabaseProvider always opens the same underlying database file
 * (`exoplayer_internal.db`); handing each component its own provider would
 * mean multiple SQLite connections to that file and lock contention between
 * an active download and cached playback.
 */
@UnstableApi
object Media3DatabaseProvider {
    @Volatile
    private var instance: StandaloneDatabaseProvider? = null

    @Synchronized
    fun get(context: Context): StandaloneDatabaseProvider {
        instance?.let { return it }
        return StandaloneDatabaseProvider(context.applicationContext).also { instance = it }
    }
}
