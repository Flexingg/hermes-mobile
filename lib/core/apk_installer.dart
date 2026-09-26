import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

/// Opens Android's package installer on a downloaded APK (a PR's test build).
///
/// The native side (MainActivity) hands the file to the installer through a
/// FileProvider. Android asks the user once to allow installs from Mercury.
/// If the channel isn't there (older build, other platform), falls back to the
/// share sheet so the file is never a dead end.
class ApkInstaller {
  static const _channel = MethodChannel('mercury/apk');

  static Future<void> install(String localPath) async {
    try {
      await _channel.invokeMethod<void>('install', {'path': localPath});
    } on MissingPluginException {
      await SharePlus.instance.share(ShareParams(files: [XFile(localPath)]));
    }
  }
}
