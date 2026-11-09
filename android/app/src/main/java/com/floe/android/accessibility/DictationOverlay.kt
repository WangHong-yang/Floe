package com.floe.android.accessibility

import android.content.Context
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import com.floe.android.core.*
import kotlin.math.hypot

internal class DictationOverlay(
    private val context: Context,
    private val prefs: FloePreferences,
    private val feedback: (View, Int) -> Boolean = { view, kind -> view.performHapticFeedback(kind) },
) {
    private val manager = context.getSystemService(WindowManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val panel = LinearLayout(context)
    private val ice = FloeIceView(context)
    private val cancel = label("×", 27f, "Cancel recording")
    private val finish = label("✓", 23f, "Finish recording")
    private val params = WindowManager.LayoutParams(
        dp(104), dp(56), WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
        PixelFormat.TRANSLUCENT,
    ).apply { gravity = Gravity.TOP or Gravity.START; title = "Floe voice input" }
    private var controlsOnLeft = false
    private var attached = false
    private var state = DictationState()
    private var dragging = false
    private var touching = false
    private var touchClick = false
    private var initialX = 0
    private var initialY = 0
    private var touchX = 0f
    private var touchY = 0f
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private val gesture = RecordingGesture()
    private val hold = Runnable {
        if (touching && !dragging) applyGesture(gesture.hold(SystemClock.uptimeMillis(), DictationBridge.state.value.phase == Phase.READY))
    }

    init {
        panel.contentDescription = "Floe voice input overlay"
        panel.orientation = LinearLayout.HORIZONTAL
        panel.gravity = Gravity.CENTER_VERTICAL
        // Deliberately no panel background, outline, text label or separate drag grip.
        panel.addView(ice, LinearLayout.LayoutParams(dp(104), dp(56)))
        panel.addView(cancel, LinearLayout.LayoutParams(dp(40), dp(40)))
        panel.addView(finish, LinearLayout.LayoutParams(dp(40), dp(40)))
        ice.setOnClickListener {
            if (!touchClick) when (DictationBridge.state.value.phase) {
                Phase.READY -> applyGesture(RecordingGesture.Action.START_TAP)
                Phase.LOADING, Phase.RECORDING -> applyGesture(RecordingGesture.Action.FINISH)
                else -> Unit
            }
        }
        ice.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    handler.removeCallbacks(hold)
                    touching = true; dragging = false
                    initialX = params.x; initialY = params.y; touchX = event.rawX; touchY = event.rawY
                    ice.isPressed = true
                    val phase = DictationBridge.state.value.phase
                    gesture.down(SystemClock.uptimeMillis(), phase == Phase.READY, phase == Phase.LOADING || phase == Phase.RECORDING)
                    handler.postDelayed(hold, gesture.holdThresholdMs)
                }
                MotionEvent.ACTION_MOVE -> {
                    if (touching) {
                        val dx = event.rawX - touchX
                        val dy = event.rawY - touchY
                        if (!dragging && hypot(dx, dy) > touchSlop) {
                            dragging = true; ice.isPressed = false
                            handler.removeCallbacks(hold)
                            applyGesture(gesture.drag())
                        }
                        if (dragging) {
                            params.x = initialX + dx.toInt(); params.y = initialY + dy.toInt()
                            clampPosition()
                            if (attached) manager.updateViewLayout(panel, params)
                        }
                    }
                }
                MotionEvent.ACTION_UP -> {
                    handler.removeCallbacks(hold)
                    ice.isPressed = false
                    if (touching && dragging) savePosition()
                    else if (touching) {
                        val phase = DictationBridge.state.value.phase
                        applyGesture(gesture.up(SystemClock.uptimeMillis(), phase == Phase.READY, phase == Phase.LOADING || phase == Phase.RECORDING))
                        touchClick = true
                        try { ice.performClick() } finally { touchClick = false }
                    }
                    touching = false; dragging = false
                }
                MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_POINTER_DOWN -> {
                    handler.removeCallbacks(hold)
                    ice.isPressed = false
                    applyGesture(gesture.cancel())
                    touching = false; dragging = false
                }
            }
            true
        }
        cancel.setOnClickListener { applyGesture(RecordingGesture.Action.CANCEL) }
        finish.setOnClickListener { applyGesture(RecordingGesture.Action.FINISH) }
        render(state)
    }

    fun render(value: DictationState) {
        val previous = state.phase
        state = value
        val active = value.phase == Phase.LOADING || value.phase == Phase.RECORDING
        val busy = value.phase == Phase.FINISHING
        ice.phase = value.phase
        ice.contentDescription = when (value.phase) {
            Phase.LOADING -> "Starting the microphone; release or tap to finish, or choose Cancel"
            Phase.RECORDING -> "Recording; release or tap to finish; drag the ice to move"
            Phase.FINISHING -> "Finishing recording"
            else -> "Floe ice: hold to speak, release to finish; tap for hands-free recording; drag to move"
        }
        cancel.visibility = if (active || busy) View.VISIBLE else View.GONE
        finish.visibility = if (active) View.VISIBLE else View.GONE
        ice.isEnabled = !busy
        val width = dp(104 + (if (active || busy) 40 else 0) + (if (active) 40 else 0))
        if (params.width != width) {
            val previousX = params.x
            val anchorX = params.x + controlsInset()
            val availableWidth = screenSize().first
            controlsOnLeft = width > dp(104) && anchorX + width > availableWidth - dp(8)
            params.width = width
            panel.layoutDirection = if (controlsOnLeft) View.LAYOUT_DIRECTION_RTL else View.LAYOUT_DIRECTION_LTR
            params.x = anchorX - controlsInset()
            clampPosition()
            // Controls can open on either side; the ice stays under the same finger.
            if (touching) initialX += params.x - previousX
            if (attached) manager.updateViewLayout(panel, params)
        }
        applyTheme()
        // Keep the icon text-free, but do not hide the instruction when manual paste is needed.
        if (value.phase == Phase.READY && previous == Phase.FINISHING &&
            (value.message.contains("copied", ignoreCase = true) ||
                value.message.contains("Recording failed", ignoreCase = true) ||
                value.message.contains("No speech", ignoreCase = true))) {
            Toast.makeText(context, value.message, Toast.LENGTH_LONG).show()
        }
        // The request tick happens immediately; this quiet second tick means the mic is ready.
        if (attached && previous == Phase.LOADING && value.phase == Phase.RECORDING)
            feedback(ice, HapticFeedbackConstants.CLOCK_TICK)
    }

    private fun applyTheme() {
        listOf(cancel, finish).forEach {
            it.setTextColor(0xFFF5F5F7.toInt())
            it.background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0xED000000.toInt())
                setStroke(dp(1), 0x40FFFFFF)
            }
        }
    }

    fun show(field: Rect) {
        val oldX = params.x; val oldY = params.y
        // State changes while a finger is down must not move the target away from that finger.
        if (!touching) place(field)
        if (!attached) { applyTheme(); manager.addView(panel, params); attached = true }
        else if (oldX != params.x || oldY != params.y) manager.updateViewLayout(panel, params)
    }
    private fun place(field: Rect) {
        val (width, height) = screenSize()
        val saved = prefs.overlayPosition
        if (saved != null) {
            params.x = (saved.first * maxOf(1, width - dp(104))).toInt() - controlsInset()
            params.y = (saved.second * maxOf(1, height - params.height)).toInt()
        } else {
            params.x = field.centerX() - dp(104) / 2 - controlsInset()
            params.y = field.top - params.height - dp(10)
            if (params.y < dp(8)) params.y = field.bottom + dp(10)
        }
        clampPosition()
    }
    private fun savePosition() {
        val (width, height) = screenSize()
        prefs.overlayPosition = (params.x + controlsInset()).toFloat() / maxOf(1, width - dp(104)) to
            params.y.toFloat() / maxOf(1, height - params.height)
    }
    private fun controlsInset(): Int = if (controlsOnLeft) params.width - dp(104) else 0
    private fun clampPosition() {
        val (width, height) = screenSize()
        params.x = params.x.coerceIn(dp(8), maxOf(dp(8), width - params.width - dp(8)))
        params.y = params.y.coerceIn(dp(8), maxOf(dp(8), height - params.height - dp(8)))
    }
    @Suppress("DEPRECATION")
    private fun screenSize(): Pair<Int, Int> = if (Build.VERSION.SDK_INT >= 30) manager.currentWindowMetrics.bounds.let { it.width() to it.height() }
        else android.util.DisplayMetrics().let { manager.defaultDisplay.getMetrics(it); it.widthPixels to it.heightPixels }
    fun hide() {
        handler.removeCallbacks(hold)
        val interrupted = gesture.cancel()
        touching = false; dragging = false; ice.isPressed = false
        if (attached) { manager.removeView(panel); attached = false }
        // Only a hold started by this pointer can be cancelled by a lost window.
        if (interrupted == RecordingGesture.Action.CANCEL) applyGesture(interrupted)
    }
    fun destroy() { hide(); handler.removeCallbacksAndMessages(null) }
    private fun applyGesture(action: RecordingGesture.Action) {
        when (action) {
            RecordingGesture.Action.START_TAP, RecordingGesture.Action.START_HOLD -> {
                if (DictationBridge.state.value.phase != Phase.READY) return
                DictationBridge.start?.invoke()
                if (DictationBridge.state.value.phase in setOf(Phase.LOADING, Phase.RECORDING)) {
                    feedback(ice, if (action == RecordingGesture.Action.START_HOLD) HapticFeedbackConstants.LONG_PRESS
                        else HapticFeedbackConstants.VIRTUAL_KEY)
                }
            }
            RecordingGesture.Action.FINISH -> DictationBridge.finish?.invoke()
            RecordingGesture.Action.CANCEL -> DictationBridge.cancel?.invoke()
            RecordingGesture.Action.NONE -> Unit
        }
    }
    private fun dp(value: Int) = (value * context.resources.displayMetrics.density).toInt()
    private fun label(text: String, size: Float, description: String) = TextView(context).apply {
        this.text = text; textSize = size; contentDescription = description; gravity = Gravity.CENTER
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
    }
}
