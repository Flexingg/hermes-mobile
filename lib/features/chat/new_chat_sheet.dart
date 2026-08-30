import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';
import 'chat_thread_page.dart';
import 'group_chat_page.dart';

/// Google-Messages-style "Start chat" sheet: pick a bot (direct) or several
/// bots (group), then type a first message.
class NewChatSheet extends StatefulWidget {
  const NewChatSheet({super.key});

  @override
  State<NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<NewChatSheet> {
  String? _botId;
  final _controller = TextEditingController();
  bool _groupMode = false;
  final Set<String> _groupAgents = {};

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
          Text(_groupMode ? 'New group' : 'Start chat',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
              _groupMode
                  ? 'Pick two or more agents — every reply fans out to all of them.'
                  : 'Choose an agent and send a first message.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Direct'), icon: Icon(Icons.person_outline, size: 18)),
              ButtonSegment(value: true, label: Text('Group'), icon: Icon(Icons.groups_outlined, size: 18)),
            ],
            selected: {_groupMode},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _groupMode = s.first),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: bots.map((b) {
              if (_groupMode) {
                final selected = _groupAgents.contains(b.name);
                return FilterChip(
                  avatar: Text(b.emoji),
                  label: Text(b.name),
                  selected: selected,
                  onSelected: (v) => setState(() {
                    if (v) {
                      _groupAgents.add(b.name);
                    } else {
                      _groupAgents.remove(b.name);
                    }
                  }),
                );
              }
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
              onPressed: _canStart() ? _start : null,
              icon: _groupMode ? const Icon(Icons.groups) : const Icon(Icons.send),
              label: Text(_groupMode ? 'Create group' : 'Start chat'),
            ),
          ),
        ],
      ),
    );
  }

  bool _canStart() {
    if (_groupMode) return _groupAgents.length >= 2;
    return _botId != null;
  }

  Future<void> _start() async {
    final state = context.read<AppState>();
    final text = _controller.text.trim();
    final nav = Navigator.of(context);

    if (_groupMode) {
      final agents = _groupAgents.toList();
      if (agents.length < 2) return;
      try {
        final g = await state.createGroup(name: '', agents: agents);
        if (!mounted) return;
        nav.pop(); // close the sheet
        nav.push(
          MaterialPageRoute(
            builder: (_) => GroupChatPage(
              groupId: g.id,
              name: g.name,
              agents: g.agents,
            ),
          ),
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not create group: $e')),
          );
        }
      }
      return;
    }

    if (_botId == null || text.isEmpty) return;
    final bot = state.servers
        .expand((s) => s.bots)
        .firstWhere((b) => b.id == _botId);
    final pendingId = 'new_${DateTime.now().millisecondsSinceEpoch}';
    nav.pop();
    nav.push(
      MaterialPageRoute(
        builder: (_) => ChatThreadPage(
          sessionId: pendingId,
          isNewChat: true,
          name: bot.name,
          pendingText: text,
        ),
      ),
    );
  }
}
