package com.floe.android.core
import org.junit.Assert.*
import org.junit.Test
class EditorSemanticsTest {
    private val native = EditorSemantics(true,true,true,true,true,true,false)
    @Test fun nativeFocusedEditorAccepted() { assertTrue(native.isFocusedEditor()) }
    @Test fun virtualEditorCanExposeOnlySetTextAction() { assertTrue(native.copy(editable=false,editTextClass=false).isFocusedEditor()) }
    @Test fun editTextClassFallbackAccepted() { assertTrue(native.copy(editable=false,canSetText=false).isFocusedEditor()) }
    @Test fun passwordNeverAcceptedEvenWithFocusEvent() { assertFalse(native.copy(password=true).isFocusedEditor(true)) }
    @Test fun hiddenAndDisabledNeverAccepted() { assertFalse(native.copy(visible=false).isFocusedEditor(true));assertFalse(native.copy(enabled=false).isFocusedEditor(true)) }
    @Test fun unrelatedFocusedViewIsNotAnEditor() { assertFalse(native.copy(editable=false,canSetText=false,editTextClass=false).isFocusedEditor(true)) }
    @Test fun nonfocusedEditorNeedsEvidence() { assertFalse(native.copy(focused=false).isFocusedEditor());assertTrue(native.copy(focused=false).isFocusedEditor(true)) }
    @Test fun unfocusedPasswordStillRejected() { assertFalse(native.copy(focused=false,password=true).isFocusedEditor(true)) }
}
