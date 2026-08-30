import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'core/config/app_config.dart';
import 'core/connection/server_gate.dart';
import 'core/navigation.dart';
import 'core/security/vault_gate.dart';
import 'core/theme/app_theme.dart';
import 'features/shell/home_shell.dart';
import 'state/app_state.dart';

/// Root widget: wires providers, applies Material You theming (dynamic color
/// from wallpaper), and selects the theme mode.
class HermesMobileApp extends StatelessWidget {
  final AppConfig config;
  const HermesMobileApp({super.key, required this.config});

  ThemeMode _resolve(ThemePreference pref) {
    switch (pref) {
      case ThemePreference.system:
        return ThemeMode.system;
      case ThemePreference.light:
        return ThemeMode.light;
      case ThemePreference.dark:
        return ThemeMode.dark;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: config),
        ChangeNotifierProvider(
          create: (_) {
            final state = AppState(config);
            // Connect + load AFTER the first frame so `notifyListeners` never
            // fires during the initial build (avoids deactivation crash).
            WidgetsBinding.instance.addPostFrameCallback((_) => state.init());
            return state;
          },
        ),
      ],
      child: AppTheme.builder((lightDynamic, darkDynamic) {
        return Consumer<AppConfig>(builder: (context, cfg, _) {
          final useDynamic = cfg.dynamicColor;
          final seed = cfg.seedColor;
          return MaterialApp(
            title: 'Mercury Messenger',
            debugShowCheckedModeBanner: false,
            navigatorKey: appNavigatorKey,
            theme: AppTheme.light(
              dynamicScheme: useDynamic ? lightDynamic : null,
              seedOverride: seed,
              density: cfg.uiDensity,
              radius: cfg.cornerRadius,
              bubble: cfg.bubbleStyle,
            ),
            darkTheme: AppTheme.dark(
              dynamicScheme: useDynamic ? darkDynamic : null,
              seedOverride: seed,
              density: cfg.uiDensity,
              radius: cfg.cornerRadius,
              bubble: cfg.bubbleStyle,
            ),
            themeMode: _resolve(cfg.themePreference),
            home: const VaultGate(
              child: ServerGate(child: HomeShell()),
            ),
          );
        });
      }),
    );
  }
}
