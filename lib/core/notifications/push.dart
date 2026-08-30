import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import '../../features/chat/chat_thread_page.dart';
import '../navigation.dart';
import 'notifications.dart';

/// Firebase Cloud Messaging client. Handles permission, token registration
/// (handed to the bridge so it can push), foreground display, and tap
/// deep-linking. All opt-in — nothing fires until the user enables it.
class PushService {
  static final FirebaseMessaging _fm = FirebaseMessaging.instance;
  static String? _token;
  static bool _inited = false;

  /// Called with the device token so the bridge can register it for push.
  /// Set by `AppState` once connected; a no-op before that.
  static Future<void> Function(String token)? tokenSink;

  static String? get token => _token;

  static Future<void> init() async {
    if (_inited) return;
    await Firebase.initializeApp();

    // Foreground messages: render locally via the notification channel.
    FirebaseMessaging.onMessage.listen(_onForeground);
    // Tapped while app was in background / killed.
    FirebaseMessaging.onMessageOpenedApp.listen(_onTap);
    final initial = await _fm.getInitialMessage();
    if (initial != null) _onTap(initial);

    _fm.onTokenRefresh.listen((t) => _setToken(t));
    await _setToken(await _fm.getToken());
    _inited = true;
  }

  /// Ask for notification permission and, if granted, register the token.
  static Future<bool> requestPermission() async {
    final s = await _fm.requestPermission(alert: true, badge: true, sound: true);
    final granted = s.authorizationStatus == AuthorizationStatus.authorized ||
        s.authorizationStatus == AuthorizationStatus.provisional;
    if (granted) {
      await _setToken(await _fm.getToken());
    }
    return granted;
  }

  static Future<void> _setToken(String? t) async {
    if (t == null || t.isEmpty) return;
    _token = t;
    try {
      await tokenSink?.call(t);
    } catch (_) {
      // Bridge unreachable — token will re-register on next connect.
    }
  }

  static Future<void> _onForeground(RemoteMessage m) async {
    final n = m.notification;
    if (n != null) {
      await NotificationsService.showReply(
          n.title ?? 'Mercury Messenger', n.body ?? '');
    }
  }

  static void _onTap(RemoteMessage m) {
    final data = m.data;
    final type = data['type'];
    final sessionId = data['session_id'];
    final nav = appNavigatorKey.currentState;
    if (nav == null || type != 'chat' || sessionId == null) return;
    nav.push(
      MaterialPageRoute(
        builder: (_) => ChatThreadPage(sessionId: sessionId),
      ),
    );
  }
}
