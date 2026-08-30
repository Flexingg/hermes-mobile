import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';

/// Google-Messages-style message composer: attach · text · voice/send.
class MessageComposer extends StatefulWidget {
  final bool enabled;
  const MessageComposer({super.key, this.enabled = true});

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _hasText => _controller.text.trim().isNotEmpty;

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    context.read<AppState>().sendMessage(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
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
              onPressed: () => _attach(context),
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
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
                icon: const Icon(Icons.mic_none_rounded),
                tooltip: 'Voice input',
                color: scheme.onSurfaceVariant,
                onPressed: () => _voice(context),
              ),
          ],
        ),
      ),
    );
  }

  void _attach(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Attachment support coming in this build.')),
    );
  }

  void _voice(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Voice input (STT) — wired in a later step.')),
    );
  }
}
