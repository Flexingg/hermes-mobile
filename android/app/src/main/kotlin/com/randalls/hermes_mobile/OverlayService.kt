package com.randalls.hermes_mobile

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

// The floating assistant: a foreground service that owns a second Flutter
// engine (lib/features/assistant/overlay_main.dart) and draws its FlutterView
// over other apps. It is hand-rolled instead of using an overlay plugin because
// a plugin's AAR is exactly the class of dependency that already broke
// file_picker's SDK-34 build once (see the lifecycle pin in pubspec.yaml).
class OverlayService : Service() {
    companion object {
        private const val TAG = "OverlayService"
        private const val CHANNEL_ID = "mercury_overlay"
        private const val NOTIFICATION_ID = 4104
        private const val ACTION_STOP = "com.randalls.hermes_mobile.overlay.STOP"
        // A package: URI, not a file:// path: DartIsolate::RunFromLibrary
        // (runtime/dart_isolate.cc) passes this string to Dart_LookupLibrary,
        // which resolves it against the loaded kernel — the same way the engine
        // finds its own "package:flutter/src/dart_plugin_registrant.dart"
        // (runtime/dart_plugin_registrant.cc).
        private const val ENTRYPOINT_LIBRARY =
            "package:hermes_mobile/features/assistant/overlay_main.dart"

        // The key AppConfig.overlayEnabled reads, as the shared_preferences
        // plugin stores it ("flutter." prefix, FlutterSharedPreferences file).
        private const val PREFS_FILE = "FlutterSharedPreferences"
        private const val PREF_OVERLAY = "flutter.cfg_overlay"

        // How long the camera may wait for the host activity before giving up;
        // image_picker then reports "no activity" and the bar shows it.
        private const val HOST_ATTACH_TIMEOUT_MS = 5000L

        // One group per process: engines spawned from it share the loaded
        // snapshot and ICU data instead of each loading their own.
        private var engineGroup: FlutterEngineGroup? = null

        // The running instance, for the host activity's callbacks only. Cleared
        // in onDestroy; the activity side goes through the static API below.
        private var current: OverlayService? = null

        /// The main engine's `mercury/overlay_events`, set by MainActivity while
        /// it has an engine, so overlay events reach the app's session list.
        var mainEvents: MethodChannel? = null

        val isRunning: Boolean
            get() = current != null

        /// The overlay's engine, for the camera host activity to attach to.
        internal val overlayEngine: FlutterEngine?
            get() = current?.engine

        /// Starts the overlay. Must be called while an activity is visible: a
        /// foreground service can't be started from the background.
        fun start(context: Context): Boolean {
            if (!Settings.canDrawOverlays(context)) return false
            ContextCompat.startForegroundService(context, Intent(context, OverlayService::class.java))
            return true
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, OverlayService::class.java))
        }

        /// Pings the overlay engine to re-read the server/token. False when the
        /// overlay isn't running (nothing to update, not an error).
        fun notifyConfigChanged(): Boolean {
            val service = current ?: return false
            val client = service.clientChannel ?: return false
            client.invokeMethod("configChanged", null)
            return true
        }

        internal fun hostAttached(host: OverlayHostActivity) {
            current?.onHostAttached(host) ?: host.finish()
        }

        internal fun hostDetached(host: OverlayHostActivity) {
            current?.onHostDetached(host)
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var clientChannel: MethodChannel? = null
    private var flutterView: FlutterView? = null
    private var window: OverlayWindow? = null
    private var host: OverlayHostActivity? = null
    private var pendingHost: MethodChannel.Result? = null

    // Never leave the Dart side waiting if the host activity doesn't come up.
    private val hostTimeout = Runnable {
        pendingHost?.success(null)
        pendingHost = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // The notification's "Turn off" is the user switching the overlay
            // off: record it where the app reads it, or the next launch would
            // bring the overlay straight back. Started with plain startService,
            // so there is no startForeground obligation to meet here.
            getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
                .edit().putBoolean(PREF_OVERLAY, false).apply()
            stopSelf()
            return START_NOT_STICKY
        }
        // startForegroundService obliges us to call startForeground even when
        // we're about to give up, or Android kills the app for it.
        if (!startInForeground() || !Settings.canDrawOverlays(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (window == null && !showOverlay()) {
            // No Dart to run means nothing would ever draw: don't leave a
            // foreground service and its notification up for an invisible overlay.
            stopSelf()
            return START_NOT_STICKY
        }
        // Not sticky: a restart after the process dies would be a background
        // FGS start. The app brings the overlay back the next time it opens.
        return START_NOT_STICKY
    }

    private fun startInForeground(): Boolean {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Assistant overlay", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while the floating assistant is on"
                    setShowBadge(false)
                }
            )
        }
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
        }
        val turnOff = PendingIntent.getService(
            this, 1,
            Intent(this, OverlayService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Assistant overlay is on")
            .setContentText("Tap the handle to ask Hermes")
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(open)
            .addAction(0, "Turn off", turnOff)
            .build()
        // Android 14 throws if a type is claimed without its permission, so the
        // microphone type is only claimed once RECORD_AUDIO has been granted.
        var type = 0
        val mic = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && mic) {
            type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, type)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: Exception) {
            // e.g. ForegroundServiceStartNotAllowedException: not started from
            // a visible activity. Better no overlay than a crash.
            false
        }
    }

    private fun showOverlay(): Boolean {
        val group = engineGroup ?: FlutterEngineGroup(applicationContext).also { engineGroup = it }
        val bundlePath = resolveBundlePath()
        if (bundlePath == null) {
            Log.e(TAG, "No Flutter app bundle path (loader not initialized?); not starting the overlay engine")
            return false
        }
        val entrypoint = DartExecutor.DartEntrypoint(bundlePath, ENTRYPOINT_LIBRARY, "main")
        val e = group.createAndRunEngine(FlutterEngineGroup.Options(this).setDartEntrypoint(entrypoint))
        engine = e

        clientChannel = MethodChannel(e.dartExecutor.binaryMessenger, "mercury/overlay_client").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "sessionCreated") {
                    // Forwarded as-is: the app reloads its session list.
                    mainEvents?.invokeMethod("sessionCreated", call.arguments)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        }
        val viewChannel = MethodChannel(e.dartExecutor.binaryMessenger, "mercury/overlay_view")
        viewChannel.setMethodCallHandler { call, result -> onViewCall(call.method, call.arguments, result) }

        // A TextureView can be translucent, so only the handle/bar is visible.
        val view = FlutterView(this, FlutterTextureView(this).apply { isOpaque = false })
        view.attachToFlutterEngine(e)
        flutterView = view
        window = OverlayWindow(this, view) {
            // Back key while expanded: the window collapsed natively; tell Dart.
            viewChannel.invokeMethod("collapsed", null)
        }.also { it.show() }
        // No activity drives this engine's lifecycle; without this it never
        // schedules frames.
        e.lifecycleChannel.appIsResumed()
        return true
    }

    // findAppBundlePath() just returns a field, so on an uninitialized loader
    // it hands back null and the engine would start without running any Dart.
    // (FlutterEngineGroup's constructor normally initializes the loader.)
    // createDefault() asserts initialization, so it only runs on that branch.
    private fun resolveBundlePath(): String? {
        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) return null
        return loader.findAppBundlePath()
            ?: DartExecutor.DartEntrypoint.createDefault().pathToBundle
    }

    private fun onViewCall(method: String, args: Any?, result: MethodChannel.Result) {
        val w = window
        if (w == null) {
            result.error("gone", "overlay window is not showing", null)
            return
        }
        when (method) {
            "setExpanded" -> {
                w.setExpanded(args as? Boolean ?: false)
                result.success(null)
            }
            "collapse" -> {
                w.setExpanded(false)
                result.success(null)
            }
            "openApp" -> {
                w.setExpanded(false)
                packageManager.getLaunchIntentForPackage(packageName)?.let {
                    it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(it)
                }
                result.success(null)
            }
            "attachHost" -> attachHost(result)
            "detachHost" -> {
                host?.finish()
                host = null
                w.setHidden(false)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // The camera (image_picker) needs an Activity to launch from and to get the
    // photo back through. The overlay engine has none, so a transparent one is
    // attached for the duration of a capture, and the overlay steps aside so it
    // doesn't sit on top of the camera's own UI.
    private fun attachHost(result: MethodChannel.Result) {
        if (host != null) {
            result.success(null)
            return
        }
        pendingHost?.success(null)
        pendingHost = result
        window?.setHidden(true)
        startActivity(
            Intent(this, OverlayHostActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        main.removeCallbacks(hostTimeout)
        main.postDelayed(hostTimeout, HOST_ATTACH_TIMEOUT_MS)
    }

    private fun onHostAttached(activity: OverlayHostActivity) {
        host = activity
        main.removeCallbacks(hostTimeout)
        pendingHost?.success(null)
        pendingHost = null
    }

    private fun onHostDetached(activity: OverlayHostActivity) {
        if (host !== activity) return
        host = null
        window?.setHidden(false)
        engine?.lifecycleChannel?.appIsResumed()
    }

    override fun onDestroy() {
        current = null
        main.removeCallbacksAndMessages(null)
        pendingHost?.success(null)
        pendingHost = null
        host?.finish()
        host = null
        window?.remove()
        window = null
        flutterView?.detachFromFlutterEngine()
        flutterView = null
        clientChannel = null
        engine?.destroy()
        engine = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        mainEvents?.invokeMethod("overlayStopped", null)
        super.onDestroy()
    }

    override fun onCreate() {
        super.onCreate()
        current = this
    }
}
