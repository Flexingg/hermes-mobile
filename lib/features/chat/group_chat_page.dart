import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/pets.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import 'composer.dart';
import 'message_bubble.dart';

/// A multi-agent group chat. Every message fans out to all member agents and
/// their (tagged) replies stream in — avatars identify who's talking.
class GroupChatPage extends StatefulWidget {
  final String groupId;
  final String name;
  final List<String> agents;
  const GroupChatPage({
    super.key,
    required this.groupId,
    required this.name,
    required this.agents,
  });

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().openGroup(widget.groupId);
      _jumpToBottom();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _jumpToBottom() {
    if (_scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final messages = state.groupMessagesFor(widget.groupId);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.name,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            Text('${widget.agents.length} agents · group',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'delete') {
                state.deleteGroup(widget.groupId);
                Navigator.of(context).maybePop();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'delete', child: Text('Delete group')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? _empty(context)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    itemCount: messages.length,
                    itemBuilder: (context, i) {
                      final m = messages[i];
                      if (m.role != ChatMessageRole.tool &&
                          m.text.trim().isEmpty &&
                          m.attachments.isEmpty &&
                          m.status != ChatMessageStatus.streaming) {
                        return const SizedBox.shrink();
                      }
                      if (m.isUser) {
                        return MessageBubble(message: m);
                      }
                      return MessageBubble(
                        message: m,
                        showAvatar: true,
                        avatarColor: scheme.primary,
                        avatarImagePath:
                            petAssetForAgent(m.agent ?? widget.name),
                      );
                    },
                  ),
          ),
          if (state.groupSending) _groupBar(context),
          MessageComposer(
            enabled: !state.groupSending,
            onSend: (t) => state.sendGroupMessage(widget.groupId, t),
          ),
        ],
      ),
    );
  }

  Widget _groupBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          const SizedBox(
              width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Text('Agents are replying…',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.groups_outlined, size: 72, color: scheme.outlineVariant),
          const SizedBox(height: 12),
          Text('Say something to the group',
              style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}
