package com.randalls.hermes_mobile

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity (a FragmentActivity) is required for the
// local_auth biometric prompt on Android. Without it, biometric auth throws
// "uiUnavailable: The current Activity must be a FragmentActivity".
class MainActivity : FlutterFragmentActivity()
