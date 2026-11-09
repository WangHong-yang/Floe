package com.floe.android.accessibility

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.view.View
import com.floe.android.R
import com.floe.android.core.Phase

/** Draws the existing transparent Floe artwork, with no card, label or grip. */
internal class FloeIceView(context: Context) : View(context) {
    private val ice = BitmapFactory.decodeResource(resources, R.drawable.floe_ice)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    // The existing artwork is centered in its launcher-sized transparent canvas.
    // Find its nontransparent extent once, without changing the source pixels.
    private val source = Rect(ice.width, ice.height, 0, 0).apply {
        for (y in 0 until ice.height) for (x in 0 until ice.width) {
            if (Color.alpha(ice.getPixel(x, y)) > 12) {
                left = minOf(left, x); top = minOf(top, y)
                right = maxOf(right, x + 1); bottom = maxOf(bottom, y + 1)
            }
        }
    }
    private val target = RectF()
    var phase: Phase = Phase.READY
        set(value) { if (field != value) { field = value; invalidate() } }

    init {
        isClickable = true
        isFocusable = true
        isHapticFeedbackEnabled = true
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val density = resources.displayMetrics.density
        val drawWidth = width - 12f * density
        val drawHeight = drawWidth * source.height() / source.width()
        target.set((width - drawWidth) / 2f, (height - drawHeight) / 2f,
            (width + drawWidth) / 2f, (height + drawHeight) / 2f)
        val checkpoint = canvas.save()
        if (isPressed) canvas.scale(.96f, .96f, width / 2f, height / 2f)
        paint.alpha = if (phase == Phase.FINISHING) 160 else 255
        paint.style = Paint.Style.FILL
        canvas.drawBitmap(ice, source, target, paint)
        canvas.restoreToCount(checkpoint)
        // A tiny indicator is the only idle-artwork addition during an active session.
        if (phase == Phase.RECORDING || phase == Phase.LOADING || phase == Phase.FINISHING) {
            val x = width - 14f * density
            val y = target.top + 2f * density
            paint.alpha = 255
            paint.color = Color.WHITE
            canvas.drawCircle(x, y, 4.5f * density, paint)
            paint.color = if (phase == Phase.RECORDING) 0xFFD84B69.toInt() else 0xFF7087A6.toInt()
            canvas.drawCircle(x, y, 3f * density, paint)
        }
    }

    override fun drawableStateChanged() { super.drawableStateChanged(); invalidate() }
    override fun performClick(): Boolean = super.performClick()
}
