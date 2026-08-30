import 'package:flutter/material.dart';
import 'app.dart';
import 'core/config/app_config.dart';
import 'core/notifications/notifications.dart';
import 'core/notifications/push.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationsService.init();
  await PushService.init();
  final config = await AppConfig.load();
  runApp(HermesMobileApp(config: config));
}
