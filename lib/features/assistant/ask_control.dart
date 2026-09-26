import 'package:flutter/services.dart';

/// What the ask intent asked for: how to open the bar and what to prefill.
///
/// Built from the intent's extras (see AskActivity.kt). Any app can send that
/// intent, so it carries no way to send — only to open, prefill and listen.
class AskArgs {
  /// `voice` starts listening as soon as the bar opens; anything else is text.
  final String mode;

  /// Put in the field, never sent: a send is always a tap in the bar.
  final String text;

  const AskArgs({this.mode = 'text', this.text = ''});

  /// Unknown, missing or malformed values fall back to a plain text bar: a typo
  /// in a Tasker task must open something usable, not a listening microphone.
  factory AskArgs.fromMap(Map<Object?, Object?>? map) {
    final mode = map?['mode'];
    final text = map?['text'];
    return AskArgs(
      mode: mode == 'voice' ? 'voice' : 'text',
      text: text is String ? text : '',
    );
  }

  bool get voice => mode == 'voice';
}

/// The ask engine's side of `mercury/ask`, the channel AskActivity opens.
///
/// Only meaningful inside the ask entrypoint; elsewhere (widget tests, other
/// platforms) every call degrades to a safe default instead of throwing.
class AskControl {
  static const _channel = MethodChannel('mercury/ask');

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Not running inside AskActivity (tests, other platforms).
    } on PlatformException {
      // The activity is already finishing; nothing left to do.
    }
  }

  /// The intent that opened the bar. Plain text when there is no activity.
  static Future<AskArgs> args() async {
    try {
      return AskArgs.fromMap(
          await _channel.invokeMethod<Map<Object?, Object?>>('args'));
    } on MissingPluginException {
      return const AskArgs();
    } on PlatformException {
      return const AskArgs();
    }
  }

  /// Closes the bar, back to the app underneath.
  static Future<void> finish() => _invoke('finish');

  /// Brings Mercury itself to the front (e.g. to reconnect) and closes the bar.
  static Future<void> openApp() => _invoke('openApp');

  /// [onArgs]: the intent fired again while the bar was open (singleTop).
  static void listen(void Function(AskArgs args) onArgs) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'args') {
        onArgs(AskArgs.fromMap(call.arguments as Map<Object?, Object?>?));
      }
      return null;
    });
  }
}
