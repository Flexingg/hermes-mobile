import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure token/secret store backed by the Android Keystore via
/// [FlutterSecureStorage]. Used to keep server API tokens out of plaintext.
class VaultService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _tokenPrefix = 'token_';
  static const _vaultPin = 'vault_pin';

  /// Read the stored token for a server (null if none).
  static Future<String?> readToken(String serverId) =>
      _storage.read(key: '$_tokenPrefix$serverId');

  static Future<void> writeToken(String serverId, String token) =>
      _storage.write(key: '$_tokenPrefix$serverId', value: token);

  static Future<void> deleteToken(String serverId) =>
      _storage.delete(key: '$_tokenPrefix$serverId');

  /// A numeric PIN fallback for the lock screen (optional).
  static Future<void> setPin(String pin) => _storage.write(key: _vaultPin, value: pin);

  static Future<String?> getPin() => _storage.read(key: _vaultPin);

  static Future<bool> hasPin() async => (await getPin()) != null;
}
