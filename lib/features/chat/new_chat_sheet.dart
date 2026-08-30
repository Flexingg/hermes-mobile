import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';
import 'chat_thread_page.dart';

/// Google-Messages-style "Start chat" sheet: pick a bot, type a first message.
class NewChatSheet extends StatefulWidget {
  const NewChatSheet({super.key});

  @override
  State<NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<NewChatSheet> {
  String? _botId;
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final bots = state.servers
        .expand((s) => s.bots)
        .toList();

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Start chat',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('Choose an agent and send a first message.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: bots.map((b) {
              final selected = _botId == b.id;
              return ChoiceChip(
                avatar: Text(b.emoji),
                label: Text(b.name),
                selected: selected,
                onSelected: (_) => setState(() => _botId = b.id),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.send,
            decoration: const InputDecoration(
              hintText: 'Message',
              prefixIcon: Icon(Icons.edit_outlined),
            ),
            onSubmitted: (_) => _start(),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _botId == null ? null : _start,
              icon: const Icon(Icons.send),
              label: const Text('Start chat'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _start() async {
    final state = context.read<AppState>();
    final bot = state.servers
        .expand((s) => s.bots)
        .firstWhere((b) => b.id == _botId);
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(); // close sheet
    final session = await state.repo
        .createSession(bot.name, bot.id);
    await state.refreshSessions();
    await state.openSession(session.id);
    await state.sendMessage(text);
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatThreadPage(sessionId: session.id)),
    );
  }
}
