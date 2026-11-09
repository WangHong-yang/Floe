package com.floe.android.core

import org.junit.Assert.*
import org.junit.Test

class CaptureIntentTest {
    @Test fun oldStopCallbackIsRejectedAfterNextSessionStarts() {
        val intent = CaptureIntent()
        val old = intent.begin()!!
        assertTrue(intent.loaded(old))
        assertTrue(intent.finish())
        assertTrue(intent.released(old))
        val next = intent.begin()!!
        assertTrue(intent.loaded(next))
        assertFalse(intent.isCurrent(old))
        assertTrue(intent.isCurrent(next))
    }
    @Test fun stopCallbacksAreRejectedImmediatelyOnCancel() {
        val intent = CaptureIntent()
        val old = intent.begin()!!
        intent.loaded(old)
        val cleanup = intent.cancel()
        assertFalse(intent.isCurrent(old))
        assertTrue(intent.released(cleanup))
        assertFalse(intent.isCurrent(old))
    }

    @Test fun enabledIdleDoesNotAuthorizeMicrophone() {
        val intent = CaptureIntent()
        assertEquals(CaptureIntent.Stage.IDLE, intent.stage)
        assertFalse(intent.loaded(0))
    }
    @Test fun tapOrHeldPressWaitsForStartBeforeMicrophone() {
        val intent = CaptureIntent()
        val id = intent.begin()!!
        assertEquals(CaptureIntent.Stage.LOADING, intent.stage)
        assertTrue(intent.loaded(id))
        assertEquals(CaptureIntent.Stage.RECORDING, intent.stage)
        assertFalse(intent.loaded(id))
    }
    @Test fun releaseDuringStartupNeverAuthorizesLateMicrophone() {
        val intent = CaptureIntent()
        val loading = intent.begin()!!
        val cancelled = intent.cancel()
        assertFalse(intent.loaded(loading))
        assertNull(intent.begin()) // No overlapping utterances during cleanup.
        assertTrue(intent.released(cancelled))
        assertEquals(CaptureIntent.Stage.IDLE, intent.stage)
    }
    @Test fun repeatedTapCannotStartAnotherSessionDuringStartupOrRecording() {
        val intent = CaptureIntent()
        val id = intent.begin()!!
        assertNull(intent.begin())
        assertTrue(intent.loaded(id))
        assertNull(intent.begin())
    }
    @Test fun staleStartupAndCleanupCannotMutateNewSession() {
        val intent = CaptureIntent()
        val old = intent.begin()!!
        val cancelled = intent.cancel()
        assertTrue(intent.released(cancelled))
        val next = intent.begin()!!
        assertFalse(intent.loaded(old))
        assertFalse(intent.released(cancelled))
        assertTrue(intent.loaded(next))
    }
    @Test fun finishCanOnlyStartOnceAndRequiresReleaseBeforeNextSession() {
        val intent = CaptureIntent()
        val id = intent.begin()!!
        assertFalse(intent.finish())
        assertTrue(intent.loaded(id))
        assertTrue(intent.finish())
        assertFalse(intent.finish())
        assertNull(intent.begin())
        assertTrue(intent.released(id))
        assertNotNull(intent.begin())
    }
    @Test fun cancelDuringFinalDecodeInvalidatesItsResult() {
        val intent = CaptureIntent()
        val id = intent.begin()!!
        intent.loaded(id)
        intent.finish()
        val cancelled = intent.cancel()
        assertFalse(intent.isCurrent(id))
        assertFalse(intent.released(id))
        assertTrue(intent.released(cancelled))
    }
    @Test fun newestCancellationOwnsCleanup() {
        val intent = CaptureIntent()
        intent.begin()
        val first = intent.cancel()
        val second = intent.cancel()
        assertFalse(intent.released(first))
        assertTrue(intent.released(second))
    }
}
