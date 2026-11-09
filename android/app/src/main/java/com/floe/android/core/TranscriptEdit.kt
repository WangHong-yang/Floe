package com.floe.android.core
class TranscriptEdit(val original: String, start: Int, end: Int) {
    val selectionStart = minOf(start, end).coerceIn(0, original.length)
    val selectionEnd = maxOf(start, end).coerceIn(selectionStart, original.length)
    var expected: String = original
        private set
    var wrote = false
        private set
    fun render(transcript: String) = original.take(selectionStart) + transcript + original.drop(selectionEnd)
    fun cursor(transcript: String) = selectionStart + transcript.length
    fun accept(transcript: String) { expected = render(transcript); wrote = true }
    fun mayReplace(current: String) = current == expected
}
