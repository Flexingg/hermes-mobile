import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../security/vault.dart';
import '../theme/app_theme.dart';

/// App-wide, persisted configuration (theme, server connection, accent).
/// Backed by [SharedPreferences]; the server token lives in the secure
/// [VaultService] (Android Keystore), never in plaintext.
class AppConfig extends ChangeNotifier {
  static const _kTheme = 'cfg_theme';
  static const _kSeed = 'cfg_seed';
  static const _kDynamic = 'cfg_dynamic';
  static const _kVault = 'cfg_vault';
  static const _kNotif = 'cfg_notif';
  static const _kServerName = 'cfg_server_name';
  static const _kServerBase = 'cfg_server_base';
  static const _kServerTokenRef = 'cfg_server_token_ref';

  late ThemePreference _themePreference;
  late bool _dynamicColor;
  bool _vaultEnabled = false;
  bool _notificationsEnabled = false;
  Color? _seedColor;

  String? _serverName;
  String? _serverBaseUrl;
  String? _serverTokenRef;

  bool get dynamicColor => _dynamicColor;
  ThemePreference get themePreference => _themePreference;
  bool get vaultEnabled => _vaultEnabled;
  bool get notificationsEnabled => _notificationsEnabled;
  Color? get seedColor => _seedColor;

  String? get serverName => _serverName;
  String? get serverBaseUrl => _serverBaseUrl;

  /// True once a server has been configured (connection may still be pending).
  bool get hasServer => _serverBaseUrl != null && _serverBaseUrl!.isNotEmpty;

  static Future<AppConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppConfig._(prefs);
  }

  AppConfig._(SharedPreferences prefs) {
    _themePreference = ThemePreference.values[prefs.getInt(_kTheme) ?? 0];
    _dynamicColor = prefs.getBool(_kDynamic) ?? true;
    _vaultEnabled = prefs.getBool(_kVault) ?? false;
    _notificationsEnabled = prefs.getBool(_kNotif) ?? false;
    _serverName = prefs.getString(_kServerName);
    _serverBaseUrl = prefs.getString(_kServerBase);
    _serverTokenRef = prefs.getString(_kServerTokenRef);
    final seed = prefs.getInt(_kSeed);
    _seedColor = seed == null ? null : Color(seed);
  }

  /// The API token for the configured server, from the secure vault.
  Future<String?> get serverToken =>
      _serverTokenRef == null ? Future.value(null) : VaultService.readToken(_serverTokenRef!);

  /// Persist a server connection. The token is stored in the secure vault.
  Future<void> setServer({
    required String name,
    required String baseUrl,
    required String token,
  }) async {
    _serverName = name;
    _serverBaseUrl = baseUrl;
    _serverTokenRef = baseUrl; // key the token by base URL
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kServerName, name);
    await p.setString(_kServerBase, baseUrl);
    await p.setString(_kServerTokenRef, baseUrl);
    if (token.isNotEmpty) {
      await VaultService.writeToken(baseUrl, token);
    }
  }

  /// Forget the configured server (and its stored token).
  Future<void> clearServer() async {
    final ref = _serverTokenRef;
    _serverName = null;
    _serverBaseUrl = null;
    _serverTokenRef = null;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.remove(_kServerName);
    await p.remove(_kServerBase);
    await p.remove(_kServerTokenRef);
    if (ref != null) await VaultService.deleteToken(ref);
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
      await p.setInt(_kSeed, value.toARGB32());
    }
  }

  Future<void> setVaultEnabled(bool value) async {
    _vaultEnabled = value;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kVault, value);
  }

  Future<void> setNotificationsEnabled(bool value) async {
    _notificationsEnabled = value;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kNotif, value);
  }
}
