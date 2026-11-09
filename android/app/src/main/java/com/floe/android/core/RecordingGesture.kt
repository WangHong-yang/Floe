package com.floe.android.core

/** A tap commits on release; a stationary hold commits after the threshold.
 * Moving first can therefore drag the same ice without starting the microphone.
 */
class RecordingGesture(val holdThresholdMs: Long = 300L) {
    enum class Action { NONE, START_TAP, START_HOLD, FINISH, CANCEL }
    private var downAt = 0L
    private var pressed = false
    private var readyAtDown = false
    private var recordingAtDown = false
    private var startedHold = false

    fun down(nowMs: Long, ready: Boolean, recording: Boolean = false): Action {
        downAt = nowMs
        pressed = true
        readyAtDown = ready
        recordingAtDown = recording
        startedHold = false
        return Action.NONE
    }

    fun hold(nowMs: Long, ready: Boolean): Action {
        if (!pressed || !readyAtDown || recordingAtDown || startedHold || !ready || nowMs - downAt < holdThresholdMs) return Action.NONE
        startedHold = true
        return Action.START_HOLD
    }

    fun up(nowMs: Long, ready: Boolean, recording: Boolean): Action {
        if (!pressed) return Action.NONE
        val action = when {
            nowMs < downAt -> Action.NONE
            startedHold && recording -> Action.FINISH
            recordingAtDown && recording -> Action.FINISH
            // A delayed/missed hold callback must never turn a long press into
            // a latched recording on release, after the user's finger is gone.
            readyAtDown && !recordingAtDown && !startedHold && ready && !recording &&
                nowMs - downAt < holdThresholdMs -> Action.START_TAP
            else -> Action.NONE
        }
        reset()
        return action
    }

    /** Cancels only a hold started by this touch, never a previously latched session. */
    fun cancel(): Action {
        val action = if (pressed && startedHold) Action.CANCEL else Action.NONE
        reset()
        return action
    }
    fun drag(): Action = cancel()
    private fun reset() {
        pressed = false
        readyAtDown = false
        recordingAtDown = false
        startedHold = false
    }
}
