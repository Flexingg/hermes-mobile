import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure token/secret store backed by the Android Keystore via
/// [FlutterSecureStorage]. Used to keep server API tokens out of plaintext.
class VaultService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _tokenPrefix = 'token_';
  static const _secretPrefix = 'secret_';
  static const _vaultPin = 'vault_pin';

  /// Read the stored token for a server (null if none).
  static Future<String?> readToken(String serverId) =>
      _storage.read(key: '$_tokenPrefix$serverId');

  static Future<void> writeToken(String serverId, String token) =>
      _storage.write(key: '$_tokenPrefix$serverId', value: token);

  static Future<void> deleteToken(String serverId) =>
      _storage.delete(key: '$_tokenPrefix$serverId');

  /// A named secret for a server (e.g. its Cloudflare Access service token).
  static Future<String?> readSecret(String serverId, String name) =>
      _storage.read(key: '$_secretPrefix${name}_$serverId');

  static Future<void> writeSecret(String serverId, String name, String value) =>
      _storage.write(key: '$_secretPrefix${name}_$serverId', value: value);

  static Future<void> deleteSecret(String serverId, String name) =>
      _storage.delete(key: '$_secretPrefix${name}_$serverId');

  /// Everything stored for one server, e.g. when it is forgotten.
  static Future<void> deleteServerSecrets(String serverId) async {
    for (final name in const ['cfId', 'cfSecret']) {
      await deleteSecret(serverId, name);
    }
  }

  /// A numeric PIN fallback for the lock screen (optional).
  static Future<void> setPin(String pin) => _storage.write(key: _vaultPin, value: pin);

  static Future<String?> getPin() => _storage.read(key: _vaultPin);

  static Future<bool> hasPin() async => (await getPin()) != null;
}
