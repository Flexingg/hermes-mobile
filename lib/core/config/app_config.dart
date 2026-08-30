import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';

/// App-wide, persisted configuration (theme, demo mode, accent).
/// Backed by [SharedPreferences] so choices survive restarts.
class AppConfig extends ChangeNotifier {
  static const _kDemo = 'cfg_demo';
  static const _kTheme = 'cfg_theme';
  static const _kSeed = 'cfg_seed';
  static const _kDynamic = 'cfg_dynamic';
  static const _kVault = 'cfg_vault';

  late bool _demoMode;
  late ThemePreference _themePreference;
  late bool _dynamicColor;
  bool _vaultEnabled = false;
  Color? _seedColor;

  bool get demoMode => _demoMode;
  bool get dynamicColor => _dynamicColor;
  ThemePreference get themePreference => _themePreference;
  bool get vaultEnabled => _vaultEnabled;
  Color? get seedColor => _seedColor;

  static Future<AppConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppConfig._(prefs);
  }

  AppConfig._(SharedPreferences prefs) {
    _demoMode = prefs.getBool(_kDemo) ?? true;
    _themePreference = ThemePreference.values[prefs.getInt(_kTheme) ?? 0];
    _dynamicColor = prefs.getBool(_kDynamic) ?? true;
    _vaultEnabled = prefs.getBool(_kVault) ?? false;
    final seed = prefs.getInt(_kSeed);
    _seedColor = seed == null ? null : Color(seed);
  }

  Future<void> setDemoMode(bool value) async {
    _demoMode = value;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kDemo, value);
  }

  Future<void> setThemePreference(ThemePreference value) async {
    _themePreference = value;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kTheme, value.index);
  }

  Future<void> setDynamicColor(bool value) async {
    _dynamicColor = value;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kDynamic, value);
  }

  Future<void> setSeedColor(Color? value) async {
    _seedColor = value;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    if (value == null) {
      await p.remove(_kSeed);
    } else {
      await p.setInt(_kSeed, value.value);
    }
  }

  Future<void> setVaultEnabled(bool value) async {
    _vaultEnabled = value;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kVault, value);
  }
}
