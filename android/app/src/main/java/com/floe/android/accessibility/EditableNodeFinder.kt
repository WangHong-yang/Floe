package com.floe.android.accessibility

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import com.floe.android.core.EditorSemantics
import java.util.ArrayDeque

/** Android virtual editors (including Compose) need not implement NodeProvider.findFocus. */
@Suppress("DEPRECATION")
internal class EditableNodeFinder(private val service: AccessibilityService) {
    fun semantics(node: AccessibilityNodeInfo) = EditorSemantics(
        editable = node.isEditable,
        canSetText = node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT },
        editTextClass = node.className?.toString() == "android.widget.EditText",
        focused = node.isFocused,
        enabled = node.isEnabled,
        visible = node.isVisibleToUser,
        password = node.isPassword,
    )

    fun find(hint: AccessibilityNodeInfo? = null, focusEventEvidence: Boolean = false): AccessibilityNodeInfo? {
        val roots = mutableListOf<AccessibilityNodeInfo>()
        val allowedWindowIds = mutableSetOf<Int>()
        val windows = service.windows
        try {
            val activeRoot = service.rootInActiveWindow
            if (activeRoot != null) {
                val window = windows.firstOrNull { it.id == activeRoot.windowId }
                if (window == null || window.type == AccessibilityWindowInfo.TYPE_APPLICATION) {
                    roots += activeRoot
                    allowedWindowIds += activeRoot.windowId
                } else activeRoot.recycle()
            }
            for (window in windows) {
                if (window.type != AccessibilityWindowInfo.TYPE_APPLICATION || (!window.isActive && !window.isFocused)) continue
                if (!allowedWindowIds.add(window.id)) continue
                window.root?.let { roots += it }
            }
            // Prefer provider focus, then inspect focused semantics in the virtual node tree.
            for (root in roots) {
                val direct = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                if (direct != null) {
                    if (semantics(direct).isEditor) return direct
                    val password = direct.isPassword
                    direct.recycle()
                    if (password) return null
                    // Compose may return the focused host View here, not its virtual editor.
                }
                findInTree(root)?.let { return it }
            }
            // Focus/selection events bridge short node-provider update races; never use IME nodes.
            if (hint != null && hint.windowId in allowedWindowIds && hint.refresh() &&
                semantics(hint).isFocusedEditor(focusEventEvidence)) return AccessibilityNodeInfo.obtain(hint)
            return null
        } finally {
            roots.forEach { it.recycle() }
            windows.forEach { it.recycle() }
        }
    }

    private fun findInTree(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(AccessibilityNodeInfo.obtain(root))
        var visited = 0
        try {
            while (queue.isNotEmpty() && visited++ < 400) {
                val node = queue.removeFirst()
                if (semantics(node).isFocusedEditor()) return node
                for (index in 0 until node.childCount) node.getChild(index)?.let { queue.add(it) }
                node.recycle()
            }
            return null
        } finally { while (queue.isNotEmpty()) queue.removeFirst().recycle() }
    }
}
