import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../../state/app_state.dart';

/// Google-Messages-style message composer: attach(image/file) · text · voice/send.
class MessageComposer extends StatefulWidget {
  final bool enabled;
  const MessageComposer({super.key, this.enabled = true});

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _imagePicker = ImagePicker();
  stt.SpeechToText? _speech;
  bool _listening = false;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _speech?.stop();
    super.dispose();
  }

  bool get _hasText => _controller.text.trim().isNotEmpty;

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    context.read<AppState>().sendMessage(text);
    _controller.clear();
  }

  Future<void> _voice() async {
    _speech ??= stt.SpeechToText();
    if (_listening) {
      await _speech!.stop();
      setState(() => _listening = false);
      return;
    }
    final available = await _speech!.initialize(
        onStatus: (s) {
          if (s == 'done' || s == 'notListening') {
            if (mounted) setState(() => _listening = false);
          }
        },
        onError: (_) {
          if (mounted) setState(() => _listening = false);
        });
    if (!available) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Speech recognition is unavailable on this device.')),
        );
      }
      return;
    }
    setState(() => _listening = true);
    await _speech!.listen(
      onResult: (r) {
        final w = r.recognizedWords;
        if (w.isNotEmpty) {
          _controller.text = w;
          setState(() {});
        }
      },
      listenOptions: stt.SpeechListenOptions(
        localeId: 'en_US',
        listenFor: const Duration(seconds: 20),
      ),
    );
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
    final picked = await _imagePicker.pickImage(source: source, maxWidth: 2048);
    if (picked == null || !mounted) return;
    final caption = _controller.text.trim();
    _controller.clear();
    await _sendAttachment(
        localPath: picked.path, name: p.basename(picked.path), mimeType: 'image/jpeg', caption: caption);
  }

  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles(withData: false);
    if (res == null || res.files.isEmpty || !mounted) return;
    final f = res.files.first;
    if (f.path == null) return;
    final caption = _controller.text.trim();
    _controller.clear();
    await _sendAttachment(
        localPath: f.path!, name: f.name, mimeType: _guessMime(f.name), caption: caption);
  }

  String _guessMime(String name) {
    final ext = p.extension(name).toLowerCase();
    const m = <String, String>{
      '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
      '.gif': 'image/gif', '.webp': 'image/webp',
      '.pdf': 'application/pdf', '.txt': 'text/plain', '.md': 'text/markdown',
      '.json': 'application/json', '.csv': 'text/csv',
      '.doc': 'application/msword', '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      '.xls': 'application/vnd.ms-excel', '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      '.zip': 'application/zip', '.apk': 'application/vnd.android.package-archive',
    };
    return m[ext] ?? 'application/octet-stream';
  }

  Future<void> _sendAttachment({
    required String localPath,
    required String name,
    required String mimeType,
    required String caption,
  }) async {
    if (!mounted) return;
    final state = context.read<AppState>();
    try {
      final att = await state.repo.uploadAttachment(
          localPath: localPath, name: name, mimeType: mimeType);
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
                          hintText: widget.enabled ? 'Message' : 'Starting…',
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
