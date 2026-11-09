package com.floe.android.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class Phase { OFF, PREPARING, LOADING, READY, RECORDING, FINISHING, ERROR }
data class DictationState(val phase: Phase = Phase.OFF, val transcript: String = "", val message: String = "Turn on Floe, then tap a text field to use the voice button.")
interface InsertionTarget {
    fun begin(): Boolean
    fun partial(text: String)
    fun finish(text: String): String
    fun cancel()
}
object DictationBridge {
    private val mutableState = MutableStateFlow(DictationState())
    val state = mutableState.asStateFlow()
    val accessibilityConnected = MutableStateFlow(false)
    val serviceRunning = MutableStateFlow(false)
    var enable: (() -> Unit)? = null
    var disable: (() -> Unit)? = null
    var target: InsertionTarget? = null
    var start: (() -> Unit)? = null
    var finish: (() -> Unit)? = null
    var cancel: (() -> Unit)? = null
    var resetOverlay: (() -> Unit)? = null
    fun update(state: DictationState) { mutableState.value = state }
}
