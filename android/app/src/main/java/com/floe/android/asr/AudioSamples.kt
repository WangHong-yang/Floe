package com.floe.android.asr

import java.util.concurrent.atomic.AtomicReference

internal fun pcm16ToFloat(samples: ShortArray, count: Int): FloatArray {
    require(count in 0..samples.size)
    return FloatArray(count) { samples[it] / 32768f }
}

internal class RecordingSignal {
    enum class State { RECORDING, FINISHING, CANCELLED }
    private val value = AtomicReference(State.RECORDING)
    val state: State get() = value.get()
    fun finish() { value.compareAndSet(State.RECORDING, State.FINISHING) }
    fun cancel() { value.set(State.CANCELLED) }
}
