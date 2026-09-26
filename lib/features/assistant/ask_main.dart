import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/config/app_config.dart';
import '../../data/api_failure.dart';
import '../../data/hermes_repository.dart';
import '../../data/models.dart';
import '../chat/input_actions.dart';
import 'ask_control.dart';
import 'assistant_bar.dart';
import 'assistant_session.dart';

/// Entrypoint of the ask bar's engine (started by AskActivity).
///
/// This is a separate Flutter engine with its own isolate: it cannot see the
/// main app's [AppState] or providers, so it reads [AppConfig] itself and
/// builds its own [HermesRepository].
@pragma('vm:entry-point')
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Both are read before the first frame, so a prefill is in the field when the
  // bar appears instead of popping in a frame later.
  final link = await _readLink();
  final args = await AskControl.args();
  runApp(AskApp(initial: link, args: args));
}

/// What the ask bar needs to talk to Hermes; [repo] is null with no server.
typedef AskLink = ({AppConfig config, HermesRepository? repo});

/// Reads the saved server + token. The main app writes these from another
/// isolate, so the prefs cache is reloaded first — otherwise a server changed
/// in the app would not reach a bar opened in the same process.
Future<AskLink> _readLink() async {
  await (await SharedPreferences.getInstance()).reload();
  final config = await AppConfig.load();
  if (!config.hasServer) return (config: config, repo: null);
  final token = await config.serverToken;
  return (
    config: config,
    repo: HermesRepository(baseUrl: config.serverBaseUrl!, token: token),
  );
}

/// How long a reply may go quiet before the bar reports it instead of waiting
/// forever (the same budget as the main app's send watchdog).
const _replyTimeout = Duration(seconds: 150);

class AskApp extends StatefulWidget {
  final AskLink initial;

  /// How the intent asked the bar to open. Opening never sends anything.
  final AskArgs args;

  const AskApp({super.key, required this.initial, this.args = const AskArgs()});

  @override
  State<AskApp> createState() => _AskAppState();
}

class _AskAppState extends State<AskApp> {
  late AppConfig _config = widget.initial.config;
  late HermesRepository? _repo = widget.initial.repo;
  late AskArgs _args = widget.args;
  bool _authFailed = false;
  bool _busy = false;
  String _question = '';
  String _reply = '';
  String? _error;

  /// Voice mode listens only once the probe says the server is usable: a
  /// microphone going live over a "not connected" bar would record for nothing.
  bool _listen = false;

  /// The dedicated session, once resolved for the current server.
  String? _sessionId;

  bool get _connected => _repo != null && !_authFailed;

  @override
  void initState() {
    super.initState();
    AskControl.listen(_onArgs);
    _open();
  }

  Future<void> _open() async {
    await _probe();
    if (mounted) setState(() => _listen = _args.voice && _connected);
  }

  /// The intent fired again while the bar was open: take the new prefill, and
  /// for voice re-arm the listen (the bar starts one per false→true flip).
  Future<void> _onArgs(AskArgs args) async {
    if (!mounted) return;
    setState(() {
      _args = args;
      _listen = false;
    });
    // Let the bar see the false before the next true, or the flip is lost.
    await WidgetsBinding.instance.endOfFrame;
    await _reload();
    await _open();
  }

  Future<void> _reload() async {
    final link = await _readLink();
    if (!mounted) return;
    final changed = link.repo?.baseUrl != _repo?.baseUrl ||
        link.repo?.token != _repo?.token;
    setState(() {
      _config = link.config;
      _repo = link.repo;
      if (changed) {
        _authFailed = false;
        _sessionId = null;
        _error = null;
      }
    });
  }

  /// A stale token must show up as "not connected" when the bar opens, not as
  /// a failure after the user has typed a question.
  Future<void> _probe() async {
    final repo = _repo;
    if (repo == null) return;
    try {
      await repo.sessions();
      if (mounted && _authFailed) setState(() => _authFailed = false);
    } on ApiFailure catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.isAuth) {
          _authFailed = true;
        } else {
          _error = e.toString();
        }
      });
    }
  }

  Future<String> _ensureSession(HermesRepository repo) async {
    final cached = _sessionId;
    if (cached != null) return cached;
    // The main app's chat list picks a new session up when it next resumes.
    return _sessionId = await AssistantSession.ensure(config: _config, repo: repo);
  }

  void _fail(Object e) {
    if (!mounted) return;
    setState(() {
      // Re-resolve the session next turn: it may be what went away.
      _sessionId = null;
      if (e is ApiFailure && e.isAuth) {
        _authFailed = true;
      } else if (e is TimeoutException) {
        _error = 'No reply for ${_replyTimeout.inSeconds}s — open Mercury to '
            'see whether it finished.';
      } else {
        _error = e.toString();
      }
    });
  }

  Future<void> _send(String text, {List<Attachment> attachments = const []}) async {
    final repo = _repo;
    if (repo == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _question = text.isEmpty && attachments.isNotEmpty ? '📷 Photo' : text;
      _reply = '';
    });
    try {
      final sid = await _ensureSession(repo);
      // Only the answer phase is shown; thinking/tool output stays in the app.
      await for (final m in repo
          .sendMessage(sid, text, attachments: attachments)
          .timeout(_replyTimeout)) {
        if (m.type == ChatMessageType.answer && mounted) {
          setState(() => _reply = m.text);
        }
      }
    } catch (e) {
      // Includes the ApiFailure the repository throws when the socket ends
      // without `done`: the bar must say so rather than freeze mid-reply.
      _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // AskActivity is a real activity, so image_picker launches the camera from it
  // and gets the photo back through it — no host activity to lend or attach.
  Future<void> _camera(String caption) async {
    final repo = _repo;
    if (repo == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    Attachment? attachment;
    try {
      attachment = await captureAndUpload(repo);
    } catch (e) {
      _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (attachment != null) await _send(caption, attachments: [attachment]);
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF6750A4), brightness: b),
        );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      // No Scaffold and no opaque Material anywhere up to the bar: the window is
      // transparent so the app underneath stays visible, and any painted
      // background here would cover it again.
      home: Material(
        type: MaterialType.transparency,
        child: PopScope(
          canPop: false,
          // Back closes the bar (and the activity), back to the app underneath.
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) AskControl.finish();
          },
          child: Builder(builder: (context) {
            // The window is full-screen, so a tap outside the bar lands here
            // and not on the (paused) app underneath: treat it as "close".
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: AskControl.finish,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                    8, 8, 8, 8 + MediaQuery.viewInsetsOf(context).bottom),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    // Taps on the bar itself must not fall through to close.
                    child: GestureDetector(
                      onTap: () {},
                      child: AssistantAskBar(
                        connected: _connected,
                        busy: _busy,
                        question: _question,
                        reply: _reply,
                        error: _error,
                        initialText: _args.text,
                        autostartVoice: _listen,
                        onSend: _send,
                        onCamera: _camera,
                        onDismiss: AskControl.finish,
                        onOpenApp: AskControl.openApp,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
