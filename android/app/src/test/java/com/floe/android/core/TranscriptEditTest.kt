package com.floe.android.core
import org.junit.Assert.*
import org.junit.Test
class TranscriptEditTest {
    @Test fun insertsAtCursor() { val e=TranscriptEdit("Hello world",6,6); assertEquals("Hello 中文world",e.render("中文")); assertEquals(8,e.cursor("中文")) }
    @Test fun revisionsDoNotDuplicateText() { val e=TranscriptEdit("before after",7,7); e.accept("hello"); assertTrue(e.mayReplace("before helloafter")); assertEquals("before hello worldafter",e.render("hello world")) }
    @Test fun replacesSelectionAndPreservesSuffix() { assertEquals("one 二 three",TranscriptEdit("one two three",7,4).render("二")) }
    @Test fun doesNotOverwriteIndependentEdits() { val e=TranscriptEdit("",0,0); e.accept("hello"); assertFalse(e.mayReplace("hello!")) }
    @Test fun utf16SelectionMatchesAndroid() { val e=TranscriptEdit("🙂好",2,3); assertEquals("🙂hello",e.render("hello")); assertEquals(7,e.cursor("hello")) }
}
