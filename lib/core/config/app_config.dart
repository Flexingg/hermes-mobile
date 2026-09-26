import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../security/vault.dart';
import '../theme/app_theme.dart';
import '../../data/models.dart';

/// App-wide, persisted configuration (theme, server connection, accent).
/// Backed by [SharedPreferences]; the server token lives in the secure
/// [VaultService] (Android Keystore), never in plaintext.
class AppConfig extends ChangeNotifier {
  static const _kTheme = 'cfg_theme';
  static const _kSeed = 'cfg_seed';
  static const _kDynamic = 'cfg_dynamic';
  static const _kVault = 'cfg_vault';
  static const _kNotif = 'cfg_notif';
  static const _kDensity = 'cfg_density';
  static const _kRadius = 'cfg_radius';
  static const _kBubble = 'cfg_bubble';
  static const _kTech = 'cfg_tech';
  static const _kServerName = 'cfg_server_name';
  static const _kServerBase = 'cfg_server_base';
  static const _kServerTokenRef = 'cfg_server_token_ref';
  static const _kServerKind = 'cfg_server_kind';
  static const _kAssistantSession = 'cfg_assistant_session';

  late ThemePreference _themePreference;
  late bool _dynamicColor;
  bool _vaultEnabled = false;
  bool _notificationsEnabled = false;
  Color? _seedColor;
  UiDensity _uiDensity = UiDensity.comfortable;
  CornerRadius _cornerRadius = CornerRadius.standard;
  BubbleStyle _bubbleStyle = BubbleStyle.green;
  bool _showTechnical = false;

  String? _serverName;
  String? _serverBaseUrl;
  String? _serverTokenRef;
  ConnectionKind _serverKind = ConnectionKind.lan;
  String? _assistantSessionId;

  bool get dynamicColor => _dynamicColor;
  ThemePreference get themePreference => _themePreference;
  bool get vaultEnabled => _vaultEnabled;
  bool get notificationsEnabled => _notificationsEnabled;
  Color? get seedColor => _seedColor;
  UiDensity get uiDensity => _uiDensity;
  CornerRadius get cornerRadius => _cornerRadius;
  BubbleStyle get bubbleStyle => _bubbleStyle;
  bool get showTechnical => _showTechnical;

  String? get serverName => _serverName;
  String? get serverBaseUrl => _serverBaseUrl;

  /// How the configured server is reached (a tunnel, the LAN, Tailscale). Kept
  /// so the connect screen and Settings can explain the connection, and so a
  /// tunnel URL can be recognised after the fact.
  ConnectionKind get serverKind => _serverKind;

  /// True once a server has been configured (connection may still be pending).
  bool get hasServer => _serverBaseUrl != null && _serverBaseUrl!.isNotEmpty;

  /// The dedicated session the ask bar posts into, so its turns never land in
  /// a project chat or whatever thread was last open.
  String? get assistantSessionId => _assistantSessionId;

  static Future<AppConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppConfig._(prefs);
  }

  AppConfig._(SharedPreferences prefs) {
    _themePreference = ThemePreference.values[prefs.getInt(_kTheme) ?? 0];
    _dynamicColor = prefs.getBool(_kDynamic) ?? true;
    _vaultEnabled = prefs.getBool(_kVault) ?? false;
    _notificationsEnabled = prefs.getBool(_kNotif) ?? false;
    _uiDensity = UiDensity.values[prefs.getInt(_kDensity) ?? 0];
    _cornerRadius = CornerRadius.values[prefs.getInt(_kRadius) ?? 0];
    _bubbleStyle = BubbleStyle.values[prefs.getInt(_kBubble) ?? 1];
    _showTechnical = prefs.getBool(_kTech) ?? false;
    _serverName = prefs.getString(_kServerName);
    _serverBaseUrl = prefs.getString(_kServerBase);
    _serverTokenRef = prefs.getString(_kServerTokenRef);
    _serverKind = ConnectionKind.parse(prefs.getString(_kServerKind));
    _assistantSessionId = prefs.getString(_kAssistantSession);
    final seed = prefs.getInt(_kSeed);
    _seedColor = seed == null ? null : Color(seed);
  }

  /// The API token for the configured server, from the secure vault.
  Future<String?> get serverToken =>
      _serverTokenRef == null ? Future.value(null) : VaultService.readToken(_serverTokenRef!);

  /// The Cloudflare Access service token for the configured server, if the edge
  /// is protected. Both halves come from the vault; null when either is missing.
  Future<({String id, String secret})?> get serverAccessToken async {
    final ref = _serverTokenRef;
    if (ref == null) return null;
    final id = await VaultService.readSecret(ref, 'cfId');
    final secret = await VaultService.readSecret(ref, 'cfSecret');
    if (id == null || id.isEmpty || secret == null || secret.isEmpty) return null;
    return (id: id, secret: secret);
  }

  /// Persist a server connection. The token and any Access service token go to
  /// the secure vault, never to plaintext preferences.
  Future<void> setServer({
    required String name,
    required String baseUrl,
    required String token,
    ConnectionKind kind = ConnectionKind.lan,
    String? accessClientId,
    String? accessClientSecret,
  }) async {
    _serverName = name;
    _serverBaseUrl = baseUrl;
    _serverTokenRef = baseUrl; // key the token by base URL
    _serverKind = kind;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kServerName, name);
    await p.setString(_kServerBase, baseUrl);
    await p.setString(_kServerTokenRef, baseUrl);
    await p.setString(_kServerKind, kind.name);
    if (token.isNotEmpty) {
      await VaultService.writeToken(baseUrl, token);
    }
    if ((accessClientId ?? '').isNotEmpty && (accessClientSecret ?? '').isNotEmpty) {
      await VaultService.writeSecret(baseUrl, 'cfId', accessClientId!);
      await VaultService.writeSecret(baseUrl, 'cfSecret', accessClientSecret!);
    } else {
      // Switching away from a protected tunnel must not leave the token behind.
      await VaultService.deleteServerSecrets(baseUrl);
    }
  }

  /// Forget the configured server (and its stored token).
  Future<void> clearServer() async {
    final ref = _serverTokenRef;
    _serverName = null;
    _serverBaseUrl = null;
    _serverTokenRef = null;
    _serverKind = ConnectionKind.lan;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.remove(_kServerName);
    await p.remove(_kServerBase);
    await p.remove(_kServerTokenRef);
    await p.remove(_kServerKind);
    if (ref != null) {
      await VaultService.deleteToken(ref);
      await VaultService.deleteServerSecrets(ref);
    }
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

  Future<void> setUiDensity(UiDensity value) async {
    _uiDensity = value;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kDensity, value.index);
  }

  Future<void> setCornerRadius(CornerRadius value) async {
    _cornerRadius = value;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kRadius, value.index);
  }

  Future<void> setBubbleStyle(BubbleStyle value) async {
    _bubbleStyle = value;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kBubble, value.index);
  }

  Future<void> setShowTechnical(bool value) async {
    _showTechnical = value;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kTech, value);
  }

  Future<void> setAssistantSessionId(String? id) async {
    _assistantSessionId = id;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    if (id == null) {
      await p.remove(_kAssistantSession);
    } else {
      await p.setString(_kAssistantSession, id);
    }
  }

  /// Reset appearance + UI preferences to their defaults.
  Future<void> resetAppearance() async {
    _dynamicColor = true;
    _themePreference = ThemePreference.system;
    _seedColor = null;
    _uiDensity = UiDensity.comfortable;
    _cornerRadius = CornerRadius.standard;
    _bubbleStyle = BubbleStyle.green;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.remove(_kSeed);
    await p.setBool(_kDynamic, true);
    await p.setInt(_kTheme, ThemePreference.system.index);
    await p.setInt(_kDensity, UiDensity.comfortable.index);
    await p.setInt(_kRadius, CornerRadius.standard.index);
    await p.setInt(_kBubble, BubbleStyle.green.index);
  }
}
