import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/config/app_config.dart';
import '../../core/overlay/overlay_control.dart';
import '../../data/api_failure.dart';
import '../../data/hermes_repository.dart';
import '../../data/models.dart';
import '../chat/input_actions.dart';
import 'assistant_bar.dart';
import 'assistant_session.dart';

/// Entrypoint of the floating assistant's engine (started by OverlayService).
///
/// This is a separate Flutter engine with its own isolate: it cannot see the
/// main app's [AppState] or providers, so it reads [AppConfig] itself and
/// builds its own [HermesRepository].
@pragma('vm:entry-point')
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final link = await _readLink();
  runApp(AssistantOverlayApp(initial: link));
}

/// What the overlay needs to talk to Hermes; [repo] is null with no server.
typedef OverlayLink = ({AppConfig config, HermesRepository? repo});

/// Reads the saved server + token. The main app writes these from another
/// isolate, so the prefs cache is reloaded first — otherwise a server changed
/// in the app would never reach an overlay that was already running.
Future<OverlayLink> _readLink() async {
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

class AssistantOverlayApp extends StatefulWidget {
  final OverlayLink initial;
  const AssistantOverlayApp({super.key, required this.initial});

  @override
  State<AssistantOverlayApp> createState() => _AssistantOverlayAppState();
}

class _AssistantOverlayAppState extends State<AssistantOverlayApp> {
  late AppConfig _config = widget.initial.config;
  late HermesRepository? _repo = widget.initial.repo;
  bool _authFailed = false;
  bool _expanded = false;
  bool _busy = false;
  String _question = '';
  String _reply = '';
  String? _error;

  /// The dedicated session, once resolved for the current server.
  String? _sessionId;

  bool get _connected => _repo != null && !_authFailed;

  @override
  void initState() {
    super.initState();
    OverlayWindow.listen(
      onConfigChanged: _reload,
      onCollapsed: () {
        if (mounted) setState(() => _expanded = false);
      },
    );
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

  Future<void> _expand() async {
    await OverlayWindow.setExpanded(true);
    if (!mounted) return;
    setState(() => _expanded = true);
    await _reload();
    await _probe();
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

  Future<void> _collapse() async {
    await OverlayWindow.setExpanded(false);
    if (mounted) setState(() => _expanded = false);
  }

  Future<String> _ensureSession(HermesRepository repo) async {
    final cached = _sessionId;
    if (cached != null) return cached;
    final before = _config.assistantSessionId;
    final id = await AssistantSession.ensure(config: _config, repo: repo);
    if (id != before) await OverlayWindow.reportSessionCreated(id);
    return _sessionId = id;
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

  Future<void> _camera(String caption) async {
    final repo = _repo;
    if (repo == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    Attachment? attachment;
    try {
      await OverlayWindow.attachHost();
      attachment = await captureAndUpload(repo);
    } catch (e) {
      _fail(e);
    } finally {
      await OverlayWindow.detachHost();
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
      home: Material(
        type: MaterialType.transparency,
        child: LayoutBuilder(builder: (context, box) {
          // The window is resized natively; until the new size arrives the
          // bar must not try to lay out inside the 56dp handle.
          if (!_expanded || box.maxWidth < 200) {
            return _Handle(onTap: _expand);
          }
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _collapse,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  8, 8, 8, 8 + MediaQuery.viewInsetsOf(context).bottom),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  // Taps on the bar itself must not fall through to collapse.
                  child: GestureDetector(
                    onTap: () {},
                    child: AssistantAskBar(
                      connected: _connected,
                      busy: _busy,
                      question: _question,
                      reply: _reply,
                      error: _error,
                      onSend: _send,
                      onCamera: _camera,
                      onDismiss: _collapse,
                      onOpenApp: OverlayWindow.openApp,
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// The collapsed state: a small round handle at the screen edge.
class _Handle extends StatelessWidget {
  final VoidCallback onTap;
  const _Handle({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Material(
        color: scheme.primaryContainer,
        shape: const CircleBorder(),
        elevation: 4,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(Icons.auto_awesome, color: scheme.onPrimaryContainer),
          ),
        ),
      ),
    );
  }
}
