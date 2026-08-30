import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local notification layer. Fires in-app notifications (e.g. when an assistant
/// reply finishes). True server-side push (FCM) is a follow-up that needs a
/// Firebase `google-services.json`.
class NotificationsService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static const _channelId = 'hermes_replies';
  static const _channelName = 'Hermes replies';

  /// Initialize the plugin + create the Android channel. Safe to call more than
  /// once. Call from `main()` after `WidgetsFlutterBinding.ensureInitialized()`.
  static Future<void> init() async {
    if (_initialized) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: 'Hermes assistant reply notifications',
          importance: Importance.high,
        ));
    _initialized = true;
  }

  /// Request notification permission (Android 13+).
  static Future<void> requestPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  /// Show a reply notification. Swallows errors so it never crashes the app.
  static Future<void> showReply(String title, String body) async {
    if (!_initialized) return;
    try {
      final id = DateTime.now().millisecondsSinceEpoch.remainder(1000000);
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (_) {}
  }
}
