import 'package:flutter/material.dart';
import 'app.dart';
import 'core/config/app_config.dart';
import 'core/notifications/notifications.dart';
import 'core/notifications/push.dart';
// The floating assistant's engine starts at this library's `main`. Release
// builds only compile what lib/main.dart reaches, so it is imported here even
// though nothing in this file calls it.
// ignore: unused_import
import 'features/assistant/overlay_main.dart' as assistant_overlay;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationsService.init();
  await PushService.init();
  final config = await AppConfig.load();
  runApp(HermesMobileApp(config: config));
}
