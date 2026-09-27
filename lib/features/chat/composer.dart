import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';
import 'input_actions.dart';

/// Google-Messages-style message composer: attach(image/file) · text · voice/send.
class MessageComposer extends StatefulWidget {
  final bool enabled;

  /// Optional override for where text is sent (used by group chats).
  final void Function(String text)? onSend;

  /// Placeholder text (e.g. Plan mode asks for the change you want).
  final String? hint;

  /// Pre-filled text the user edits before sending (e.g. a task the chat was
  /// opened from). Never sent on its own.
  final String? initialText;
  const MessageComposer({super.key, this.enabled = true, this.onSend, this.hint, this.initialText});

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _imagePicker = ImagePicker();
  final _voiceInput = VoiceInputController();

  bool get _listening => _voiceInput.listening;

  @override
  void initState() {
    super.initState();
    _voiceInput.addListener(_onVoiceChanged);
    // Pre-filled text the user edits before sending (a task the chat was opened
    // from). Never sent on its own.
    final seed = widget.initialText;
    if (seed != null && seed.isNotEmpty) {
      _controller.text = seed;
      // Land the cursor at the end so typing continues the sentence.
      _controller.selection = TextSelection.collapsed(offset: seed.length);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  void _onVoiceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _voiceInput.dispose();
    super.dispose();
  }

  bool get _hasText => _controller.text.trim().isNotEmpty;

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    if (widget.onSend != null) {
      widget.onSend!(text);
      _controller.clear();
      return;
    }
    context.read<AppState>().sendMessage(text);
    _controller.clear();
  }

  Future<void> _voice() async {
    final available = await _voiceInput.toggle((words) {
      _controller.text = words;
      setState(() {});
    });
    if (!available && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Speech recognition is unavailable on this device.')),
      );
    }
  }

  Future<void> _attach(BuildContext context) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('Choose a file'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'camera':
        await _pickImage(ImageSource.camera);
        break;
      case 'gallery':
        await _pickImage(ImageSource.gallery);
        break;
      case 'file':
        await _pickFile();
        break;
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final picked = await pickImage(_imagePicker, source);
    if (picked == null || !mounted) return;
    final caption = _controller.text.trim();
    _controller.clear();
    await _sendAttachment(picked, caption: caption);
  }

  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles(withData: false);
    if (res == null || res.files.isEmpty || !mounted) return;
    final f = res.files.first;
    if (f.path == null) return;
    final caption = _controller.text.trim();
    _controller.clear();
    await _sendAttachment(
        LocalUpload(localPath: f.path!, name: f.name, mimeType: guessMime(f.name)),
        caption: caption);
  }

  Future<void> _sendAttachment(LocalUpload file, {required String caption}) async {
    if (!mounted) return;
    final state = context.read<AppState>();
    try {
      final att = await uploadPicked(state.repo, file);
      state.sendMessage(caption, attachments: [att]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send attachment: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(height: 1, color: scheme.outlineVariant),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: 'Attach',
                    color: scheme.onSurfaceVariant,
                    onPressed: widget.enabled ? () => _attach(context) : null,
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
                        enabled: widget.enabled,
                        minLines: 1,
                        maxLines: 6,
                        textInputAction: TextInputAction.newline,
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) {
                          if (!widget.enabled || state.sending) return;
                          _send();
                        },
                        decoration: InputDecoration(
                          hintText: widget.enabled ? (widget.hint ?? 'Message') : 'Starting…',
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (state.sending)
                    _stopButton(context, state)
                  else if (_hasText)
                    IconButton.filled(
                      icon: const Icon(Icons.send_rounded),
                      onPressed: !widget.enabled ? null : _send,
                    )
                  else
                    IconButton(
                      icon: _listening
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.mic_none_rounded),
                      tooltip: _listening ? 'Listening…' : 'Voice input',
                      color: _listening ? scheme.error : scheme.onSurfaceVariant,
                      onPressed: widget.enabled ? _voice : null,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Stop, in two stages, replacing the send button for as long as a turn runs.
  ///
  /// Tap one asks the turn to finish the step it is on and end (a steer: the
  /// reply stays a coherent answer), and the button changes shape so it is
  /// obvious that is what happened. Tap two asks for confirmation first, then
  /// cuts the run off wherever it is.
  Widget _stopButton(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    if (state.stopUnavailable) {
      // The bridge answered 404: it is an older build with no Stop route.
      // Going back to the inviting first shape just asked for the same 404
      // again, so it stays disabled — in the error tone — for this turn.
      return IconButton.filledTonal(
        key: const Key('stop-failed'),
        style: IconButton.styleFrom(
          disabledBackgroundColor: scheme.errorContainer,
          disabledForegroundColor: scheme.onErrorContainer,
        ),
        icon: const Icon(Icons.block),
        tooltip: 'the bridge does not have the Stop route (older build)',
        onPressed: null,
      );
    }
    if (state.stoppingHard) {
      // The kill is on its way; nothing left to press.
      return IconButton.filledTonal(
        key: const Key('stop-confirmed'),
        icon: const SizedBox(
            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        tooltip: 'Stopping now…',
        onPressed: null,
      );
    }
    if (state.stopRequested) {
      return IconButton.filledTonal(
        key: const Key('stop-kill'),
        // A different shape, not just a different glyph: the tap that follows
        // this one is the destructive one.
        style: IconButton.styleFrom(
          backgroundColor: scheme.errorContainer,
          foregroundColor: scheme.onErrorContainer,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        ),
        icon: const Icon(Icons.cancel_outlined),
        tooltip: 'Stopping after this step — tap again to kill it now',
        onPressed: () => _confirmKill(context, state),
      );
    }
    return IconButton.filled(
      key: const Key('stop-turn'),
      icon: const Icon(Icons.stop_rounded),
      tooltip: 'Stop after this step',
      onPressed: () => state.stopTurn(),
    );
  }

  /// The second tap's confirmation: it is the one that can lose work.
  Future<void> _confirmKill(BuildContext context, AppState state) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kill it now?'),
        content: const Text(
            'This cuts the run off wherever it is — if it is part-way through a step, '
            'that step is left unfinished. Stop after this step is the gentler option, '
            'and it is already on its way.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('stop-kill-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Kill it'),
          ),
        ],
      ),
    );
    if (ok == true) await state.stopTurn(hard: true);
  }
}
