package com.floe.android.core

/** Main-thread session intent, independent of asynchronous microphone startup. */
class CaptureIntent {
    enum class Stage { IDLE, LOADING, RECORDING, FINISHING }
    var stage = Stage.IDLE
        private set
    private var generation = 0L

    fun begin(): Long? {
        if (stage != Stage.IDLE) return null
        stage = Stage.LOADING
        return ++generation
    }

    fun isCurrent(id: Long): Boolean = generation == id && stage != Stage.IDLE

    /** The only permission to open the microphone after the model is ready. */
    fun loaded(id: Long): Boolean {
        if (!isCurrent(id) || stage != Stage.LOADING) return false
        stage = Stage.RECORDING
        return true
    }

    fun finish(): Boolean {
        if (stage != Stage.RECORDING) return false
        stage = Stage.FINISHING
        return true
    }

    /** Invalidates session callbacks immediately, but blocks a new start until release completes. */
    fun cancel(): Long {
        stage = Stage.FINISHING
        return ++generation
    }

    fun released(id: Long): Boolean {
        if (!isCurrent(id)) return false
        stage = Stage.IDLE
        return true
    }
}
