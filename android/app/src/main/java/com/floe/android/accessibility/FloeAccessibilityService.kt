package com.floe.android.accessibility

import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
import android.graphics.Rect
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.floe.android.core.*
import com.floe.android.service.DictationController
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.*

@Suppress("DEPRECATION")
class FloeAccessibilityService : AccessibilityService(), InsertionTarget {
    private var controller: DictationController? = null
    private val controllerOperations = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var overlay: DictationOverlay
    private lateinit var preferences: FloePreferences
    private lateinit var finder: EditableNodeFinder
    private var focused: AccessibilityNodeInfo? = null
    private var eventHint: AccessibilityNodeInfo? = null
    private var focusEvidenceAt = 0L
    private var sessionNode: AccessibilityNodeInfo? = null
    private var edit: TranscriptEdit? = null
    private var liveRejected = false
    private var bounds = Rect()
    private var scanScheduled = false
    private var hideScheduled = false
    private val pendingSelections = mutableListOf<AccessibilityNodeInfo>()
    private var selectionVersion = 0L
    private val scan = Runnable { scanScheduled = false; updateFocus() }
    private val delayedScan = Runnable { updateFocus() }
    private val settledScan = Runnable { updateFocus() }
    private val hideIfStillAbsent = Runnable {
        hideScheduled = false
        if (DictationBridge.state.value.phase == Phase.READY) {
            val found = findEditor()
            if (found != null) display(found) else {
                focused?.recycle(); focused = null; overlay.hide()
            }
        }
    }

    override fun onServiceConnected() {
        if (::overlay.isInitialized) return
        DictationBridge.enable = ::enableDictation
        DictationBridge.disable = ::disableDictation
        preferences = FloePreferences(this)
        finder = EditableNodeFinder(this)
        overlay = DictationOverlay(this, preferences)
        DictationBridge.target = this
        DictationBridge.accessibilityConnected.value = true
        DictationBridge.resetOverlay = { preferences.overlayPosition = null; updateFocus() }
        scope.launch { DictationBridge.state.collect { overlay.render(it); updateFocus() } }
        updateFocus()
    }

    private fun enableDictation() {
        if (controller != null) return
        if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            DictationBridge.update(DictationState(Phase.ERROR, message = "Allow microphone access, then enable Floe again."))
            return
        }
        controller = DictationController(this, controllerOperations, ::disableDictation)
        try { controller?.enable() }
        catch (error: RuntimeException) {
            disableDictation()
            DictationBridge.update(DictationState(Phase.ERROR, message = "Could not enable Floe: ${error.message ?: error.javaClass.simpleName}"))
        }
    }

    private fun disableDictation() {
        controller?.close()
        controller = null
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (!::overlay.isInitialized || event == null) return
        // Accessibility can remain enabled after Floe is switched off. Do not scan
        // other apps or schedule settling callbacks while dictation is disabled.
        when (DictationBridge.state.value.phase) { Phase.OFF, Phase.ERROR -> return; else -> Unit }
        val type = event.eventType
        if (type in setOf(AccessibilityEvent.TYPE_VIEW_FOCUSED, AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED, AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED)) {
            val source = event.source
            if (source != null && finder.semantics(source).isEditor) {
                eventHint?.recycle(); eventHint = source
                focusEvidenceAt = if (type == AccessibilityEvent.TYPE_VIEW_FOCUSED) SystemClock.uptimeMillis() else 0L
            } else {
                source?.recycle()
                if (type == AccessibilityEvent.TYPE_VIEW_FOCUSED) { eventHint?.recycle(); eventHint = null; focusEvidenceAt = 0L }
            }
        }
        if (!scanScheduled) { scanScheduled = true; handler.postDelayed(scan, 40) }
        if (type == AccessibilityEvent.TYPE_VIEW_CLICKED || type == AccessibilityEvent.TYPE_VIEW_FOCUSED || type == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            handler.removeCallbacks(delayedScan)
            handler.postDelayed(delayedScan, 200)
            handler.removeCallbacks(settledScan)
            handler.postDelayed(settledScan, 800)
        }
    }

    private fun findEditor(): AccessibilityNodeInfo? = finder.find(
        eventHint, focusEvidenceAt > 0L && SystemClock.uptimeMillis() - focusEvidenceAt < 750,
    )

    private fun display(node: AccessibilityNodeInfo) {
        handler.removeCallbacks(hideIfStillAbsent); hideScheduled = false
        focused?.recycle(); focused = node
        node.getBoundsInScreen(bounds)
        overlay.show(bounds)
    }

    private fun updateFocus() {
        if (!::overlay.isInitialized) return
        when (DictationBridge.state.value.phase) {
            Phase.LOADING, Phase.RECORDING, Phase.FINISHING -> overlay.show(bounds)
            Phase.READY -> {
                val node = findEditor()
                if (node != null) display(node)
                else if (!hideScheduled) { hideScheduled = true; handler.postDelayed(hideIfStillAbsent, 350) }
            }
            else -> { handler.removeCallbacks(hideIfStillAbsent); hideScheduled = false; overlay.hide() }
        }
    }

    override fun begin(): Boolean {
        ++selectionVersion
        clearSession()
        val node = findEditor() ?: return false
        val text = node.text?.toString().orEmpty()
        val start = node.textSelectionStart.takeIf { it >= 0 } ?: text.length
        val end = node.textSelectionEnd.takeIf { it >= 0 } ?: start
        sessionNode = node
        edit = TranscriptEdit(text, start, end)
        liveRejected = !preferences.liveInsertion
        node.getBoundsInScreen(bounds)
        return true
    }

    override fun partial(text: String) {
        if (text.isNotBlank() && !liveRejected && !writeText(text)) liveRejected = true
    }

    private fun stillTargeted(node: AccessibilityNodeInfo): Boolean {
        if (!node.refresh() || !finder.semantics(node).isEditor) return false
        val current = findEditor() ?: return false
        val same = current == node
        current.recycle()
        return same
    }

    private fun writeText(text: String): Boolean {
        val node = sessionNode ?: return false
        val replacement = edit ?: return false
        if (!stillTargeted(node) || !replacement.mayReplace(node.text?.toString().orEmpty())) return false
        if (replacement.wrote && replacement.expected == replacement.render(text)) return true
        if (!node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, replacement.render(text))
        })) return false
        replacement.accept(text)
        setSelectionAfterText(node, replacement.cursor(text), replacement.cursor(text), replacement.render(text))
        return true
    }

    override fun finish(text: String): String {
        ++selectionVersion
        if (writeText(text)) { clearSession(); return "Text inserted." }
        val node = sessionNode
        val replacement = edit
        val hadPreview = replacement?.wrote == true
        val restored = hadPreview && restorePreview()
        val canPaste = node != null && replacement != null && stillTargeted(node) &&
            if (restored) node.text?.toString().orEmpty() == replacement.original
            else !replacement.wrote && replacement.mayReplace(node.text?.toString().orEmpty())
        getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Floe", text))
        val pasted = canPaste && node!!.performAction(AccessibilityNodeInfo.ACTION_PASTE)
        clearSession()
        return when {
            pasted -> "Text pasted. The final transcript is also on the clipboard."
            hadPreview && !restored -> "Final transcript copied. Select the text inserted during this session before pasting to avoid duplicates."
            else -> "This field does not support automatic typing. Text copied; please paste it manually."
        }
    }

    override fun cancel() { ++selectionVersion; restorePreview(); clearSession() }
    private fun restorePreview(): Boolean {
        val node = sessionNode ?: return false
        val replacement = edit ?: return false
        if (!replacement.wrote || !node.refresh() || node.isPassword || !replacement.mayReplace(node.text?.toString().orEmpty())) return false
        val restored = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, replacement.original)
        })
        if (restored) setSelectionAfterText(node, replacement.selectionStart, replacement.selectionEnd, replacement.original)
        return restored
    }
    private fun setSelectionAfterText(node: AccessibilityNodeInfo, start: Int, end: Int, expectedText: String) {
        // Virtual editors can retain an old SetSelection callback until recomposition.
        // Calling it immediately after SetText may resubmit the old text and undo the edit.
        // Cursor placement is optional: only apply after committed text is observable.
        val version = ++selectionVersion
        val snapshot = AccessibilityNodeInfo.obtain(node)
        pendingSelections += snapshot
        handler.postDelayed({
            try {
                if (version == selectionVersion && snapshot.refresh() && snapshot.isFocused && !snapshot.isPassword &&
                    snapshot.text?.toString().orEmpty() == expectedText &&
                    (snapshot.textSelectionStart != start || snapshot.textSelectionEnd != end)) {
                    snapshot.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start)
                        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, end)
                    })
                }
            } finally {
                pendingSelections.removeAll { it === snapshot }
                snapshot.recycle()
            }
        }, 32)
    }
    private fun clearSession() { sessionNode?.recycle(); sessionNode = null; edit = null }
    override fun onInterrupt() { DictationBridge.cancel?.invoke() }
    override fun onDestroy() {
        disableDictation()
        DictationBridge.enable = null
        DictationBridge.disable = null
        if (DictationBridge.target === this) DictationBridge.target = null
        DictationBridge.accessibilityConnected.value = false
        DictationBridge.resetOverlay = null
        handler.removeCallbacksAndMessages(null)
        pendingSelections.forEach { it.recycle() }; pendingSelections.clear()
        clearSession(); focused?.recycle(); eventHint?.recycle()
        if (::overlay.isInitialized) overlay.destroy()
        scope.cancel()
        super.onDestroy()
    }
}
