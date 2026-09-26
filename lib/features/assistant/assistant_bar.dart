import 'package:flutter/material.dart';
import '../chat/input_actions.dart';

/// The floating assistant's ask bar: the reply so far above a composer-shaped
/// field with camera, voice and send.
///
/// It holds no connection of its own — the ask entrypoint passes the streamed
/// [reply]/[error] in and does the sending — so it renders the same in a widget
/// test as in AskActivity.
class AssistantAskBar extends StatefulWidget {
  /// False when there is no usable server/token. The bar then says so instead
  /// of offering a send that could only fail.
  final bool connected;

  final Future<void> Function(String text) onSend;

  /// Takes a photo and sends it, with the typed text as its caption.
  final Future<void> Function(String caption)? onCamera;

  /// Closes the bar, back to the app underneath.
  final VoidCallback? onDismiss;

  /// Opens the main app, offered when not connected.
  final VoidCallback? onOpenApp;

  /// What was last asked, echoed above the reply.
  final String question;

  /// The assistant's reply, growing while it streams.
  final String reply;

  /// A failed turn, shown in place instead of a silent freeze.
  final String? error;

  /// A turn is in flight.
  final bool busy;

  /// Put in the field when the bar opens (and again when it changes, for a
  /// second fire of the ask intent). Never sent: a send is always a tap.
  final String initialText;

  /// Start listening once, when this flips to true while [connected] — the
  /// host only sets it after its connection probe, so the microphone never
  /// goes live over a bar that could not send what it heard.
  final bool autostartVoice;

  /// Injected speech input (tests). When null the bar makes and disposes its
  /// own; an injected one belongs to the caller and is never disposed here.
  final VoiceInputController? voiceInput;

  const AssistantAskBar({
    super.key,
    required this.connected,
    required this.onSend,
    this.onCamera,
    this.onDismiss,
    this.onOpenApp,
    this.question = '',
    this.reply = '',
    this.error,
    this.busy = false,
    this.initialText = '',
    this.autostartVoice = false,
    this.voiceInput,
  });

  static const notConnectedText = 'not connected — open Mercury';

  @override
  State<AssistantAskBar> createState() => _AssistantAskBarState();
}

class _AssistantAskBarState extends State<AssistantAskBar> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  late final VoiceInputController _voiceInput =
      widget.voiceInput ?? VoiceInputController();
  String? _voiceError;

  bool get _voiceArmed => widget.autostartVoice && widget.connected;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialText;
    _voiceInput.addListener(_onVoiceChanged);
    // After the first frame: _voice() calls setState, and the mic button it
    // animates has to exist first.
    if (_voiceArmed) WidgetsBinding.instance.addPostFrameCallback((_) => _autostart());
  }

  @override
  void didUpdateWidget(AssistantAskBar old) {
    super.didUpdateWidget(old);
    if (widget.initialText != old.initialText && widget.initialText.isNotEmpty) {
      _controller.text = widget.initialText;
    }
    // Once per false→true flip, so a rebuild while armed can't stop (toggle)
    // a listen that is already running.
    final wasArmed = old.autostartVoice && old.connected;
    if (_voiceArmed && !wasArmed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _autostart());
    }
  }

  void _autostart() {
    if (mounted && _voiceArmed && !_voiceInput.listening) _voice();
  }

  void _onVoiceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _voiceInput.removeListener(_onVoiceChanged);
    if (widget.voiceInput == null) _voiceInput.dispose();
    super.dispose();
  }

  bool get _hasText => _controller.text.trim().isNotEmpty;

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || widget.busy) return;
    _controller.clear();
    setState(() => _voiceError = null);
    await widget.onSend(text);
  }

  Future<void> _voice() async {
    setState(() => _voiceError = null);
    final available = await _voiceInput.toggle((words) {
      _controller.text = words;
      if (mounted) setState(() {});
    });
    if (!available && mounted) {
      // The bar runs in a real activity, so the recognizer asks for the
      // microphone itself; getting here means it was refused or there is no
      // recognizer, and the bar says so rather than silently not listening.
      setState(() => _voiceError =
          'Voice input is unavailable — the microphone was not allowed or '
          'there is no speech recognizer.');
    }
  }

  Future<void> _camera() async {
    final caption = _controller.text.trim();
    _controller.clear();
    setState(() => _voiceError = null);
    await widget.onCamera!(caption);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      elevation: 6,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 6, 0),
            child: Row(children: [
              Icon(Icons.auto_awesome, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Assistant',
                    style: Theme.of(context).textTheme.titleSmall),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: 'Close',
                color: scheme.onSurfaceVariant,
                onPressed: widget.onDismiss,
              ),
            ]),
          ),
          if (!widget.connected)
            _notConnected(context)
          else ...[
            _replyArea(context),
            _composer(context),
          ],
        ],
      ),
    );
  }

  Widget _notConnected(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Row(children: [
        Icon(Icons.link_off_rounded, color: scheme.error),
        const SizedBox(width: 12),
        const Expanded(child: Text(AssistantAskBar.notConnectedText)),
        if (widget.onOpenApp != null)
          TextButton(onPressed: widget.onOpenApp, child: const Text('Open')),
      ]),
    );
  }

  Widget _replyArea(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final error = widget.error ?? _voiceError;
    final showReply = widget.reply.trim().isNotEmpty;
    final showQuestion = widget.question.trim().isNotEmpty;
    if (!showQuestion && !showReply && error == null && !widget.busy) {
      return const SizedBox.shrink();
    }
    return Flexible(
      child: SingleChildScrollView(
        reverse: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showQuestion)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(widget.question,
                    style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic)),
              ),
            if (showReply) SelectableText(widget.reply),
            if (widget.busy && !showReply)
              Text('Thinking…',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(error, style: TextStyle(color: scheme.error)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _composer(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final listening = _voiceInput.listening;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            icon: const Icon(Icons.photo_camera_outlined),
            tooltip: 'Take photo',
            color: scheme.onSurfaceVariant,
            onPressed: widget.onCamera == null || widget.busy ? null : _camera,
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(28),
              ),
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: 'Ask Hermes',
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: listening
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.mic_none_rounded),
            tooltip: listening ? 'Listening…' : 'Voice input',
            color: listening ? scheme.error : scheme.onSurfaceVariant,
            onPressed: widget.busy ? null : _voice,
          ),
          IconButton.filled(
            icon: widget.busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send_rounded),
            tooltip: 'Send',
            onPressed: !_hasText || widget.busy ? null : _send,
          ),
        ],
      ),
    );
  }
}
