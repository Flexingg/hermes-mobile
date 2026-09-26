import 'dart:async';
import 'package:flutter/services.dart';

/// The floating assistant, seen from the main app.
///
/// The native side (MainActivity + OverlayService) owns the permission check,
/// the foreground service and the second Flutter engine that draws the overlay.
/// Every call degrades to a safe default when the channel isn't there (widget
/// tests, desktop, an older build) — the same contract as [ApkInstaller].
class OverlayControl {
  static const _channel = MethodChannel('mercury/overlay');
  static const _events = MethodChannel('mercury/overlay_events');

  static final _sessionCreated = StreamController<String>.broadcast();
  static final _stopped = StreamController<void>.broadcast();
  static bool _listening = false;

  static Future<T?> _call<T>(String method) async {
    try {
      return await _channel.invokeMethod<T>(method);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// True when this device can draw over other apps (Android 6+).
  static Future<bool> isSupported() async => await _call<bool>('isSupported') ?? false;

  /// Whether "Draw over other apps" is granted right now. Re-check on resume:
  /// the user grants it in system Settings, outside the app.
  static Future<bool> hasPermission() async => await _call<bool>('hasPermission') ?? false;

  /// Opens the system "Draw over other apps" page for Mercury. Returns at once;
  /// the answer only exists once the user comes back.
  static Future<void> requestPermission() => _call<void>('requestPermission');

  /// Starts the overlay service. Only call this while the app is visible —
  /// Android refuses to start a foreground service from the background.
  static Future<void> start() => _call<void>('start');

  static Future<void> stop() => _call<void>('stop');

  static Future<bool> isRunning() async => await _call<bool>('isRunning') ?? false;

  /// Tells the overlay the server or token changed, so it rebuilds its
  /// connection without a restart. False when no overlay is running.
  static Future<bool> notifyConfigChanged() async =>
      await _call<bool>('notifyConfigChanged') ?? false;

  /// Session ids the overlay created, so the chat list can reload.
  static Stream<String> get sessionCreated {
    _listen();
    return _sessionCreated.stream;
  }

  /// Fires when the overlay service stops on its own (e.g. the notification's
  /// "Turn off" action), so a visible switch can follow it.
  static Stream<void> get stopped {
    _listen();
    return _stopped.stream;
  }

  static void _listen() {
    if (_listening) return;
    _listening = true;
    _events.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'sessionCreated':
          final id = (call.arguments as Map?)?['sessionId'] as String?;
          if (id != null) _sessionCreated.add(id);
          break;
        case 'overlayStopped':
          _stopped.add(null);
          break;
      }
      return null;
    });
  }
}

/// The overlay engine's side: its own window and its link back to the app.
///
/// Only meaningful inside the overlay entrypoint; elsewhere every call is a
/// no-op, which is what keeps the assistant widgets testable.
class OverlayWindow {
  static const _view = MethodChannel('mercury/overlay_view');
  static const _client = MethodChannel('mercury/overlay_client');

  static Future<void> _invoke(MethodChannel channel, String method, [Object? args]) async {
    try {
      await channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // Not running inside the overlay service (tests, other platforms).
    } on PlatformException {
      // The window is already gone (service stopping); nothing to resize.
    }
  }

  /// Grows the window into the focusable ask bar, or shrinks it to the handle.
  static Future<void> setExpanded(bool expanded) =>
      _invoke(_view, 'setExpanded', expanded);

  static Future<void> collapse() => _invoke(_view, 'collapse');

  /// The camera needs an Activity to launch from and to return to, and the
  /// overlay engine has none. This attaches a transparent one for the duration
  /// of a capture (and hides the overlay so it doesn't cover the camera UI).
  static Future<void> attachHost() => _invoke(_view, 'attachHost');

  static Future<void> detachHost() => _invoke(_view, 'detachHost');

  /// Brings Mercury itself to the front (e.g. to reconnect).
  static Future<void> openApp() => _invoke(_view, 'openApp');

  /// Lets the main app invalidate its session list.
  static Future<void> reportSessionCreated(String sessionId) =>
      _invoke(_client, 'sessionCreated', {'sessionId': sessionId});

  /// [onConfigChanged]: the main app saved a new server/token.
  /// [onCollapsed]: the native side collapsed the window (Back key).
  static void listen({
    required Future<void> Function() onConfigChanged,
    required void Function() onCollapsed,
  }) {
    _client.setMethodCallHandler((call) async {
      if (call.method == 'configChanged') await onConfigChanged();
      return null;
    });
    _view.setMethodCallHandler((call) async {
      if (call.method == 'collapsed') onCollapsed();
      return null;
    });
  }
}
