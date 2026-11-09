package com.floe.android.core

import com.floe.android.core.RecordingGesture.Action.*
import org.junit.Assert.assertEquals
import org.junit.Test

class RecordingGestureTest {
    @Test fun downDoesNotStartRecordingOrFeedback() {
        assertEquals(NONE, RecordingGesture().down(1000, true))
    }
    @Test fun quickTapStartsOnRelease() {
        val g = RecordingGesture(); g.down(1000, true)
        assertEquals(START_TAP, g.up(1100, true, false))
    }
    @Test fun holdStartsOnlyAtThreshold() {
        val g = RecordingGesture(); g.down(1000, true)
        assertEquals(NONE, g.hold(1299, true))
        assertEquals(START_HOLD, g.hold(1300, true))
        assertEquals(NONE, g.hold(1400, true))
    }
    @Test fun holdReleaseFinishes() {
        val g = RecordingGesture(); g.down(1000, true); g.hold(1300, true)
        assertEquals(FINISH, g.up(1500, false, true))
    }
    @Test fun holdReleaseDuringLoadingFinishesIntent() {
        // LOADING is passed as an active session, exactly like RECORDING.
        val g = RecordingGesture(); g.down(1000, true); g.hold(1300, true)
        assertEquals(FINISH, g.up(1400, false, true))
    }
    @Test fun tapAgainFinishesLatchedSession() {
        val g = RecordingGesture(); g.down(1000, false, true)
        assertEquals(NONE, g.hold(1400, false))
        assertEquals(FINISH, g.up(1500, false, true))
    }
    @Test fun dragBeforeThresholdNeverStarts() {
        val g = RecordingGesture(); g.down(1000, true)
        assertEquals(NONE, g.drag())
        assertEquals(NONE, g.hold(1500, true))
        assertEquals(NONE, g.up(2000, true, false))
    }
    @Test fun movingAfterHoldCancelsOnlyThatSession() {
        val g = RecordingGesture(); g.down(1000, true); g.hold(1300, true)
        assertEquals(CANCEL, g.drag())
        assertEquals(NONE, g.up(1500, false, true))
    }
    @Test fun movingLatchedSessionDoesNotCancel() {
        val g = RecordingGesture(); g.down(1000, false, true)
        assertEquals(NONE, g.drag())
        assertEquals(NONE, g.up(1500, false, true))
    }
    @Test fun interruptedPendingTouchNeverStarts() {
        val g = RecordingGesture(); g.down(1000, true)
        assertEquals(NONE, g.cancel()); assertEquals(NONE, g.hold(1500, true))
    }
    @Test fun systemCancellationCancelsNewHold() {
        val g = RecordingGesture(); g.down(1000, true); g.hold(1300, true)
        assertEquals(CANCEL, g.cancel()); assertEquals(NONE, g.up(2000, false, true))
    }
    @Test fun failedHoldStartNeverFinishesUnrelatedAction() {
        val g = RecordingGesture(); g.down(1000, true); g.hold(1300, true)
        assertEquals(NONE, g.up(2000, true, false))
    }
    @Test fun losingReadyBeforeTimerDoesNotStart() {
        val g = RecordingGesture(); g.down(1000, true)
        assertEquals(NONE, g.hold(1400, false)); assertEquals(NONE, g.up(1500, false, false))
    }
    @Test fun touchDuringBusyCannotFinishLaterSession() {
        val g = RecordingGesture(); g.down(1000, false, false)
        assertEquals(NONE, g.up(1500, false, true))
    }
    @Test fun repeatedReleaseDoesNotStartTwice() {
        val g = RecordingGesture(); g.down(1000, true)
        assertEquals(START_TAP, g.up(1100, true, false)); assertEquals(NONE, g.up(1200, true, false))
    }
    @Test fun repeatedReleaseDoesNotFinishTwice() {
        val g = RecordingGesture(); g.down(1000, true); g.hold(1300, true)
        assertEquals(FINISH, g.up(2000, false, true)); assertEquals(NONE, g.up(2100, false, true))
    }
    @Test fun releaseWithoutDownDoesNothing() {
        assertEquals(NONE, RecordingGesture().up(1000, true, false))
    }
    @Test fun nextGestureAfterDragWorks() {
        val g = RecordingGesture(); g.down(1000, true); g.drag(); g.up(1300, true, false)
        g.down(2000, true); assertEquals(START_TAP, g.up(2100, true, false))
    }
    @Test fun releaseAtThresholdWithoutTimerDoesNotStartLatchedRecording() {
        val g = RecordingGesture(); g.down(1000, true)
        assertEquals(NONE, g.up(1300, true, false))
        assertEquals(NONE, g.hold(1400, true))
    }
    @Test fun delayedHoldTimerNeverTurnsLongReleaseIntoTap() {
        val g = RecordingGesture(); g.down(1000, true)
        assertEquals(NONE, g.up(2000, true, false))
    }
    @Test fun readinessRestoredAfterMissedHoldDoesNotStartOnRelease() {
        val g = RecordingGesture(); g.down(1000, true)
        assertEquals(NONE, g.hold(1300, false))
        assertEquals(NONE, g.up(1400, true, false))
    }
    @Test fun existingRecordingCannotStartAnotherHoldEvenIfReadyIsStale() {
        val g = RecordingGesture(); g.down(1000, true, true)
        assertEquals(NONE, g.hold(1300, true))
        assertEquals(FINISH, g.up(1400, true, true))
    }
    @Test fun existingRecordingEndingDuringTouchDoesNotRestartOnRelease() {
        val g = RecordingGesture(); g.down(1000, true, true)
        assertEquals(NONE, g.up(1100, true, false))
    }
    @Test fun unrelatedRecordingBeginningDuringTouchDoesNotStartAgain() {
        val g = RecordingGesture(); g.down(1000, true, false)
        assertEquals(NONE, g.up(1100, true, true))
    }
    @Test fun releaseImmediatelyBeforeThresholdStillStartsTap() {
        val g = RecordingGesture(); g.down(1000, true)
        assertEquals(START_TAP, g.up(1299, true, false))
    }
    @Test fun clockMovingBackwardsDoesNotStartAndClearsTouch() {
        val g = RecordingGesture(); g.down(1000, true)
        assertEquals(NONE, g.up(999, true, false))
        assertEquals(NONE, g.hold(1500, true))
    }
}
