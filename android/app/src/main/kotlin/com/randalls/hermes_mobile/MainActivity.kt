package com.randalls.hermes_mobile

import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// FlutterFragmentActivity (a FragmentActivity) is required for the
// local_auth biometric prompt on Android. Without it, biometric auth throws
// "uiUnavailable: The current Activity must be a FragmentActivity".
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
}
