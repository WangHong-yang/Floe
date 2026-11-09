package com.floe.android.core
import android.content.Context
class FloePreferences(context: Context) {
    private val prefs = context.getSharedPreferences("floe", Context.MODE_PRIVATE)
    var liveInsertion: Boolean
        get() = prefs.getBoolean("live_insertion", true)
        set(value) { prefs.edit().putBoolean("live_insertion", value).apply() }
    var overlayPosition: Pair<Float, Float>?
        get() = if (prefs.contains("overlay_x")) prefs.getFloat("overlay_x", 0f) to prefs.getFloat("overlay_y", 0f) else null
        set(value) { prefs.edit().apply {
            if (value == null) { remove("overlay_x"); remove("overlay_y") }
            else { putFloat("overlay_x", value.first); putFloat("overlay_y", value.second) }
        }.apply() }
}
