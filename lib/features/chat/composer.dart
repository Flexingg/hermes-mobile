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
                  if (_hasText)
                    IconButton.filled(
                      icon: state.sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send_rounded),
                      onPressed: !widget.enabled || state.sending ? null : _send,
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
}
