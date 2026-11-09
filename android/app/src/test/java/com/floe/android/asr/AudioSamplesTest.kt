package com.floe.android.asr

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class AudioSamplesTest {
    @Test fun normalizesSignedPcmWithoutClippingOrStaleBufferTail() {
        assertArrayEquals(floatArrayOf(-1f, 0f, 32767 / 32768f),
            pcm16ToFloat(shortArrayOf(-32768, 0, 32767, 123), 3), 0f)
    }
    @Test fun emptyReadProducesNoSamples() {
        assertEquals(0, pcm16ToFloat(shortArrayOf(5), 0).size)
    }
    @Test(expected = IllegalArgumentException::class)
    fun invalidReadLengthIsRejected() { pcm16ToFloat(shortArrayOf(1), 2) }
    @Test fun repeatedFinishIsIdempotent() {
        val signal = RecordingSignal()
        signal.finish()
        signal.finish()
        assertEquals(RecordingSignal.State.FINISHING, signal.state)
    }
    @Test fun cancelWinsOverFinishInBothOrders() {
        val first = RecordingSignal()
        first.finish()
        first.cancel()
        first.finish()
        assertEquals(RecordingSignal.State.CANCELLED, first.state)
        val second = RecordingSignal()
        second.cancel()
        second.finish()
        assertEquals(RecordingSignal.State.CANCELLED, second.state)
    }
}
