package com.floe.android.accessibility

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.os.SystemClock
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.floe.android.core.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Real View/Handler/touch tests, with injected session callbacks and haptic sink.
 * These prove routing and haptic requests, not physical vibration or speech inference. */
@RunWith(AndroidJUnit4::class)
class IceOverlayInteractionTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val feedback = mutableListOf<Int>()
    private lateinit var overlay: DictationOverlay
    private lateinit var ice: View
    private lateinit var panel: LinearLayout
    private var starts = 0
    private var finishes = 0
    private var cancels = 0
    private var downTime = 0L
    private var savedPosition: Pair<Float, Float>? = null
    private var oldStart: (() -> Unit)? = null
    private var oldFinish: (() -> Unit)? = null
    private var oldCancel: (() -> Unit)? = null
    private var oldState = DictationState()

    @Before fun setUp() = instrumentation.runOnMainSync {
        oldStart = DictationBridge.start; oldFinish = DictationBridge.finish; oldCancel = DictationBridge.cancel
        oldState = DictationBridge.state.value
        savedPosition = FloePreferences(instrumentation.targetContext).overlayPosition
        DictationBridge.update(DictationState(Phase.READY))
        overlay = DictationOverlay(instrumentation.targetContext, FloePreferences(instrumentation.targetContext)) { _, type ->
            feedback += type; true
        }
        panel = overlay.javaClass.getDeclaredField("panel").apply { isAccessible = true }.get(overlay) as LinearLayout
        ice = panel.getChildAt(0)
        DictationBridge.start = { starts++; DictationBridge.update(DictationState(Phase.LOADING)); overlay.render(DictationBridge.state.value) }
        DictationBridge.finish = { finishes++; DictationBridge.update(DictationState(Phase.FINISHING)); overlay.render(DictationBridge.state.value) }
        DictationBridge.cancel = { cancels++; DictationBridge.update(DictationState(Phase.READY)); overlay.render(DictationBridge.state.value) }
        overlay.render(DictationBridge.state.value)
        layoutPanel(104)
    }
    @After fun cleanUp() = instrumentation.runOnMainSync {
        overlay.destroy()
        DictationBridge.start = oldStart; DictationBridge.finish = oldFinish; DictationBridge.cancel = oldCancel
        DictationBridge.update(oldState)
        FloePreferences(instrumentation.targetContext).overlayPosition = savedPosition
    }
    @Test fun tapStartsOnlyOnUpAndRequestsOneTick() {
        touch(MotionEvent.ACTION_DOWN)
        assertEquals(0, starts); assertTrue(feedback.isEmpty())
        touch(MotionEvent.ACTION_UP)
        assertEquals(1, starts); assertEquals(listOf(HapticFeedbackConstants.VIRTUAL_KEY), feedback)
        touch(MotionEvent.ACTION_UP)
        assertEquals(1, starts)
    }
    @Test fun holdRequestsOneLongPressAndReleaseFinishesLoading() {
        touch(MotionEvent.ACTION_DOWN)
        SystemClock.sleep(450)
        instrumentation.waitForIdleSync()
        assertEquals(1, starts); assertEquals(listOf(HapticFeedbackConstants.LONG_PRESS), feedback)
        touch(MotionEvent.ACTION_UP)
        assertEquals(1, finishes)
    }
    @Test fun dragHasNoStartOrHapticAndCanRepeatTapAfterward() {
        touch(MotionEvent.ACTION_DOWN)
        touch(MotionEvent.ACTION_MOVE, 90f, 28f)
        SystemClock.sleep(400)
        touch(MotionEvent.ACTION_UP, 90f, 28f)
        assertEquals(0, starts); assertEquals(0, cancels); assertTrue(feedback.isEmpty())
        touch(MotionEvent.ACTION_DOWN); touch(MotionEvent.ACTION_UP)
        assertEquals(1, starts)
    }
    @Test fun controlsOpeningAtRightEdgeKeepIceUnderTheHeldFinger() {
        var anchorBefore = 0
        instrumentation.runOnMainSync {
            val params = overlay.javaClass.getDeclaredField("params").apply { isAccessible = true }
                .get(overlay) as WindowManager.LayoutParams
            val density = instrumentation.targetContext.resources.displayMetrics.density
            val screenWidth = instrumentation.targetContext.resources.displayMetrics.widthPixels
            params.x = screenWidth - (112 * density).toInt()
            anchorBefore = params.x + ice.left
        }
        touch(MotionEvent.ACTION_DOWN)
        SystemClock.sleep(450)
        instrumentation.runOnMainSync {
            layoutPanel(184)
            val params = overlay.javaClass.getDeclaredField("params").apply { isAccessible = true }
                .get(overlay) as WindowManager.LayoutParams
            assertEquals("Ice must remain under the finger when controls open", anchorBefore, params.x + ice.left)
            assertEquals(View.LAYOUT_DIRECTION_RTL, panel.layoutDirection)
        }
        touch(MotionEvent.ACTION_UP)
    }
    @Test fun cancelBeforeHoldDoesNotActivateAnything() {
        touch(MotionEvent.ACTION_DOWN); touch(MotionEvent.ACTION_CANCEL)
        SystemClock.sleep(400)
        assertEquals(0, starts); assertEquals(0, cancels); assertTrue(feedback.isEmpty())
    }
    @Test fun secondPointerCancelsPendingPressWithoutRecording() {
        touch(MotionEvent.ACTION_DOWN); touch(MotionEvent.ACTION_POINTER_DOWN)
        SystemClock.sleep(400); touch(MotionEvent.ACTION_UP)
        assertEquals(0, starts); assertTrue(feedback.isEmpty())
    }
    @Test fun rejectedStartDoesNotClaimSuccessWithHaptic() {
        instrumentation.runOnMainSync { DictationBridge.start = { starts++ } }
        touch(MotionEvent.ACTION_DOWN); touch(MotionEvent.ACTION_UP)
        assertEquals(1, starts); assertTrue(feedback.isEmpty())
    }
    @Test fun accessibilityClickStartsAndThenFinishesWithoutTouch() {
        instrumentation.runOnMainSync { ice.performClick(); ice.performClick() }
        assertEquals(1, starts); assertEquals(1, finishes)
        assertEquals(listOf(HapticFeedbackConstants.VIRTUAL_KEY), feedback)
    }
    @Test fun idleArtworkHasTransparentCornersAndNoVisibleTextOrPanel() = instrumentation.runOnMainSync {
        assertNull(panel.background)
        assertEquals(View.GONE, panel.getChildAt(1).visibility)
        assertEquals(View.GONE, panel.getChildAt(2).visibility)
        val bitmap = Bitmap.createBitmap(panel.width, panel.height, Bitmap.Config.ARGB_8888)
        panel.draw(Canvas(bitmap))
        assertEquals(0, Color.alpha(bitmap.getPixel(0, 0)))
        assertEquals(0, Color.alpha(bitmap.getPixel(bitmap.width / 2, 0)))
        assertTrue(Color.alpha(bitmap.getPixel(bitmap.width / 2, bitmap.height / 2)) > 0)
        val dir = File(instrumentation.targetContext.filesDir, "ice-regression").apply { mkdirs() }
        File(dir, "idle-ice.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
    private fun layoutPanel(widthDp: Int) {
        val density = instrumentation.targetContext.resources.displayMetrics.density
        val width = (widthDp * density).toInt(); val height = (56 * density).toInt()
        panel.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
        panel.layout(0, 0, width, height)
    }
    private fun touch(action: Int, x: Float = 30f, y: Float = 28f) = instrumentation.runOnMainSync {
        val now = SystemClock.uptimeMillis()
        if (action == MotionEvent.ACTION_DOWN) downTime = now
        val event = MotionEvent.obtain(downTime, now, action, x, y, 0)
        try { ice.dispatchTouchEvent(event) } finally { event.recycle() }
    }
}
