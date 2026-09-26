package com.randalls.hermes_mobile

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// FlutterFragmentActivity (a FragmentActivity) is required for the
// local_auth biometric prompt on Android. Without it, biometric auth throws
// "uiUnavailable: The current Activity must be a FragmentActivity".
class MainActivity : FlutterFragmentActivity() {
    private var overlayEvents: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        configureOverlay(flutterEngine)
        // "Install APK" on a project's ready PR: hand the downloaded test build
        // to the system package installer. The user confirms every install.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mercury/apk")
            .setMethodCallHandler { call, result ->
                if (call.method != "install") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val file = path?.let { File(it) }
                // Only files the app itself downloaded (its cache dir) are served.
                if (file == null || !file.isFile ||
                    !file.canonicalPath.startsWith(cacheDir.canonicalPath + File.separator)
                ) {
                    result.error("bad_path", "not a downloaded APK", null)
                    return@setMethodCallHandler
                }
                try {
                    val uri = FileProvider.getUriForFile(this, "$packageName.mercury.files", file)
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("install_failed", e.message, null)
                }
            }
    }

    // The floating assistant (OverlayService). Everything goes through the
    // service's static API so this activity never holds the service itself.
    private fun configureOverlay(flutterEngine: FlutterEngine) {
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "mercury/overlay").setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                "hasPermission" -> result.success(Settings.canDrawOverlays(this))
                "requestPermission" -> {
                    // Returns at once; the settings tile re-checks on resume.
                    val intent = Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:$packageName"),
                    )
                    try {
                        startActivity(intent)
                    } catch (e: ActivityNotFoundException) {
                        // Some OEM builds lack the per-app page; open the list.
                        startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION))
                    }
                    result.success(null)
                }
                "start" -> {
                    // Called from the visible settings page / app launch, which
                    // is what makes the foreground-service start legal.
                    OverlayService.start(this)
                    result.success(null)
                }
                "stop" -> {
                    OverlayService.stop(this)
                    result.success(null)
                }
                "isRunning" -> result.success(OverlayService.isRunning)
                "notifyConfigChanged" -> result.success(OverlayService.notifyConfigChanged())
                else -> result.notImplemented()
            }
        }
        val events = MethodChannel(messenger, "mercury/overlay_events")
        overlayEvents = events
        OverlayService.mainEvents = events
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // Don't let the service call into an engine that is going away.
        if (OverlayService.mainEvents === overlayEvents) OverlayService.mainEvents = null
        overlayEvents = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
