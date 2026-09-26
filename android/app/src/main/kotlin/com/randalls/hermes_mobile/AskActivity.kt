package com.randalls.hermes_mobile

import android.content.Context
import android.content.Intent
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

// The ask bar, on demand: a translucent activity over whatever app is showing,
// running its own engine (lib/features/assistant/ask_main.dart). It replaces
// the always-on overlay, so there is no service, no draw-over-apps window and
// no standing notification — the bar only exists while it is open.
//
// A plain FlutterActivity, not FlutterFragmentActivity: that one is only needed
// for local_auth's biometric prompt, which the ask bar never shows.
//
// The Tasker/adb contract (keep it stable, it is documented in the README):
//   action    com.randalls.hermes_mobile.action.ASK
//   component com.randallengineering.hermes/com.randalls.hermes_mobile.AskActivity
//             (the applicationId differs from the Kotlin package, so the class
//             must be spelled out; ".AskActivity" resolves to the wrong one)
//   extras    mode = "text" (default) | "voice" (start listening on open)
//             text = a prefill for the field
// Any app on the device can send this intent, so it may open, prefill and
// listen — never send. A send is always a tap in the bar.
class AskActivity : FlutterActivity() {
    companion object {
        // A package: URI, resolved against the loaded kernel the same way the
        // engine finds its own plugin registrant (see DartIsolate::RunFromLibrary).
        private const val ENTRYPOINT_LIBRARY =
            "package:hermes_mobile/features/assistant/ask_main.dart"

        private const val EXTRA_MODE = "mode"
        private const val EXTRA_TEXT = "text"

        // One group per process: engines spawned from it share the loaded
        // snapshot and ICU data instead of each open loading its own.
        private var engineGroup: FlutterEngineGroup? = null
    }

    private var channel: MethodChannel? = null

    override fun provideFlutterEngine(context: Context): FlutterEngine = askEngine()

    private fun askEngine(): FlutterEngine {
        // FlutterInjector's loader is normally initialized by the embedding
        // before the entrypoint is executed, but provideFlutterEngine runs
        // earlier than that, and DartEntrypoint.createDefault() asserts
        // initialization. Initializing it here is idempotent and is what keeps
        // a release build from starting no Dart at all.
        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(this, null)
        }
        val bundlePath = loader.findAppBundlePath()
            ?: DartExecutor.DartEntrypoint.createDefault().pathToBundle
        val group = engineGroup ?: FlutterEngineGroup(applicationContext).also { engineGroup = it }
        return group.createAndRunEngine(
            FlutterEngineGroup.Options(this).setDartEntrypoint(
                DartExecutor.DartEntrypoint(bundlePath, ENTRYPOINT_LIBRARY, "main")
            )
        )
    }

    // An engine handed over by provideFlutterEngine counts as "from the host",
    // and FlutterActivity then keeps it alive after the activity is gone unless
    // told otherwise. Each open gets a fresh engine, so without this every
    // closed bar would leak a running isolate.
    override fun shouldDestroyEngineWithHost(): Boolean = true

    // Transparent mode is what makes the FlutterView translucent (a texture,
    // not an opaque surface) and clears the window background; the default
    // opaque mode paints a black slab over the app underneath.
    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mercury/ask").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "args" -> result.success(askArgs(intent))
                    "finish" -> {
                        result.success(null)
                        finish()
                    }
                    "openApp" -> {
                        // The not-connected bar's "Open": bring Mercury itself
                        // up to reconnect, and get the bar out of its way.
                        packageManager.getLaunchIntentForPackage(packageName)?.let {
                            it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(it)
                        }
                        result.success(null)
                        finish()
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // singleTop: a second fire while the bar is open lands here instead of
    // stacking another bar (and another engine) on top of it.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        channel?.invokeMethod("args", askArgs(intent))
    }

    // Unknown or missing modes fall back to text: a typo in a Tasker task must
    // open a usable bar, not a listening microphone.
    private fun askArgs(intent: Intent?): Map<String, String> {
        val mode = if (intent?.getStringExtra(EXTRA_MODE) == "voice") "voice" else "text"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        return mapOf("mode" to mode, "text" to text)
    }
}
