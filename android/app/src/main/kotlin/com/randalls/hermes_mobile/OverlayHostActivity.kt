package com.randalls.hermes_mobile

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.android.ExclusiveAppComponent
import io.flutter.embedding.engine.FlutterEngine

// A transparent, short-lived activity that lends itself to the overlay engine
// while the camera runs. image_picker launches the camera from the attached
// activity and receives the photo through its onActivityResult; an engine with
// no activity just gets "no_activity". OverlayService starts and finishes it.
class OverlayHostActivity : FragmentActivity(), ExclusiveAppComponent<Activity> {
    private var engine: FlutterEngine? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val e = OverlayService.overlayEngine
        if (e == null) {
            finish()
            return
        }
        engine = e
        e.activityControlSurface.attachToActivity(this, lifecycle)
        OverlayService.hostAttached(this)
    }

    @Deprecated("Forwarded to the overlay engine's plugins (image_picker)")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        engine?.activityControlSurface?.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        engine?.activityControlSurface?.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    // Another component took the engine over (or it is being destroyed).
    override fun detachFromFlutterEngine() {
        engine = null
        finish()
    }

    override fun getAppComponent(): Activity = this

    override fun onDestroy() {
        engine?.activityControlSurface?.detachFromActivity()
        engine = null
        OverlayService.hostDetached(this)
        super.onDestroy()
    }
}
