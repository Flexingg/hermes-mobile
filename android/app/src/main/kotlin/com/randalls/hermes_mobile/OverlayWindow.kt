package com.randalls.hermes_mobile

import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterView
import kotlin.math.min

// The overlay's WindowManager window and its two shapes. Collapsed it is a
// small handle that never takes focus, so typing in the app underneath keeps
// working. Expanded it becomes focusable (the IME needs that) and resizes for
// the keyboard; touches outside it still reach the app below.
internal class OverlayWindow(
    private val context: Context,
    flutterView: FlutterView,
    private val onBackCollapsed: () -> Unit,
) {
    private val windowManager = context.getSystemService(WindowManager::class.java)
    private val density = context.resources.displayMetrics.density
    private var expanded = false
    private var hidden = false

    // Catches Back while expanded. The overlay engine has no activity, so the
    // key would otherwise never become a "pop" on the Dart side.
    private val root = object : FrameLayout(context) {
        override fun dispatchKeyEvent(event: KeyEvent): Boolean {
            if (expanded && event.keyCode == KeyEvent.KEYCODE_BACK) {
                if (event.action == KeyEvent.ACTION_UP) {
                    setExpanded(false)
                    onBackCollapsed()
                }
                return true
            }
            return super.dispatchKeyEvent(event)
        }
    }

    init {
        flutterView.isFocusable = true
        flutterView.isFocusableInTouchMode = true
        root.addView(
            flutterView,
            FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
        )
    }

    private val overlayType: Int
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

    private fun dp(value: Int) = (value * density).toInt()

    private fun collapsedParams(): WindowManager.LayoutParams {
        val size = dp(56)
        val metrics = context.resources.displayMetrics
        return WindowManager.LayoutParams(
            size, size, overlayType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = metrics.widthPixels - size
            y = metrics.heightPixels / 3
        }
    }

    private fun expandedParams(): WindowManager.LayoutParams {
        // Tall enough for the reply area plus a multi-line field; the keyboard
        // then resizes it rather than covering the field.
        val height = min(dp(420), (context.resources.displayMetrics.heightPixels * 0.7).toInt())
        return WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT, height, overlayType,
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.START
            @Suppress("DEPRECATION")
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
        }
    }

    private fun currentParams(): WindowManager.LayoutParams {
        val params = if (expanded) expandedParams() else collapsedParams()
        if (hidden) params.flags = params.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        return params
    }

    fun show() {
        windowManager.addView(root, currentParams())
    }

    fun setExpanded(value: Boolean) {
        if (value == expanded) return
        expanded = value
        if (!value) {
            context.getSystemService(InputMethodManager::class.java)
                .hideSoftInputFromWindow(root.windowToken, 0)
            root.clearFocus()
        }
        windowManager.updateViewLayout(root, currentParams())
        if (value) root.getChildAt(0)?.requestFocus()
    }

    /// Steps aside (invisible and untouchable) while the camera is in front.
    fun setHidden(value: Boolean) {
        if (value == hidden) return
        hidden = value
        root.visibility = if (value) View.INVISIBLE else View.VISIBLE
        windowManager.updateViewLayout(root, currentParams())
    }

    fun remove() {
        try {
            windowManager.removeView(root)
        } catch (e: IllegalArgumentException) {
            // Never attached (the permission was revoked before show()).
        }
    }
}
