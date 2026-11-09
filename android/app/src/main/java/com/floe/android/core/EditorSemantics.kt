package com.floe.android.core

/** Platform-independent policy, shared by native and virtual accessibility nodes. */
data class EditorSemantics(
    val editable: Boolean,
    val canSetText: Boolean,
    val editTextClass: Boolean,
    val focused: Boolean,
    val enabled: Boolean,
    val visible: Boolean,
    val password: Boolean,
) {
    val isEditor: Boolean get() = enabled && visible && !password && (editable || canSetText || editTextClass)
    fun isFocusedEditor(focusEventEvidence: Boolean = false): Boolean = isEditor && (focused || focusEventEvidence)
}
