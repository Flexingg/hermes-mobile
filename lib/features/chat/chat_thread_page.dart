import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/pets.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import 'composer.dart';
import 'message_bubble.dart';

/// A full chat thread, Google-Messages style.
class ChatThreadPage extends StatefulWidget {
  final String sessionId;

  /// When true, this thread was opened optimistically for a brand-new chat:
  /// [pendingText]/[name] show immediately and the real session is created in
  /// the background, swapping into view via `AppState.newChatTargetId`.
  final bool isNewChat;
  final String? name;
  final String? pendingText;
  /// True for a multi-agent group chat (shows per-agent avatars).
  final bool isGroup;

  const ChatThreadPage({
    super.key,
    required this.sessionId,
    this.isNewChat = false,
    this.name,
    this.pendingText,
    this.isGroup = false,
  });

  @override
  State<ChatThreadPage> createState() => _ChatThreadPageState();
}

class _ChatThreadPageState extends State<ChatThreadPage> {
  final _scroll = ScrollController();

  String _effectiveId(AppState state) => widget.isNewChat
      ? (state.newChatTargetId ?? widget.sessionId)
      : widget.sessionId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToBottom();
      if (widget.isNewChat) {
        context.read<AppState>().createNewChat(
              name: widget.name ?? 'Hermes',
              text: widget.pendingText ?? '',
              pendingId: widget.sessionId,
            );
      }
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

  ChatSession? _session(AppState state) {
    final id = _effectiveId(state);
    for (final s in state.sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final session = _session(state);
    final scheme = Theme.of(context).colorScheme;
    final messages = state.messagesFor(_effectiveId(state));
    final agentName = session != null
        ? resolveAgentName(state.servers, session)
        : (widget.name ?? 'Hermes');

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            if (session != null)
              Avatar(
                label: session.title,
                color: session.avatarColor,
                emoji: _emojiFor(session.title),
                radius: 18,
              ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    session?.title ??
                        (widget.isNewChat
                            ? (widget.name ?? 'New chat')
                            : 'Chat'),
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600)),
                Text(_subtitle(state, session),
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () => _menu(context, state, session),
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
                      // Skip "empty" messages (no text, no attachments, not
                      // streaming) so orphan timestamps don't render as
                      // standalone bubbles.
                      if (m.role != ChatMessageRole.tool &&
                          m.text.trim().isEmpty &&
                          m.attachments.isEmpty &&
                          m.status != ChatMessageStatus.streaming) {
                        return const SizedBox.shrink();
                      }
                      final bubble = (m.isAssistant && m.id.startsWith('u-') == false)
                          ? MessageBubble(
                              message: m,
                              avatarColor:
                                  session?.avatarColor ?? scheme.primary,
                              avatarImagePath: petAssetForAgent(agentName),
                              showAvatar: widget.isGroup,
                            )
                          : MessageBubble(message: m);
                      return _InteractiveBubble(message: m, child: bubble);
                    },
                  ),
          ),
          if (widget.isNewChat && state.creatingChat)
            _startingBar(context, state)
          else if (state.sending)
            _sendingBar(context, state),
          MessageComposer(enabled: !(widget.isNewChat && state.creatingChat)),
        ],
      ),
    );
  }

  Widget _startingBar(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          const SizedBox(
              width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Text('Hermes is starting…',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _sendingBar(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    final last = state.messagesFor(_effectiveId(state)).isNotEmpty
        ? state.messagesFor(_effectiveId(state)).last
        : null;
    final toolActive = last != null && last.role == ChatMessageRole.tool;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Text(toolActive ? 'Hermes is running a tool…' : 'Hermes is typing…',
              style: TextStyle(
                  fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  String _subtitle(AppState state, ChatSession? session) {
    final last = state.messagesFor(_effectiveId(state)).isNotEmpty
        ? state.messagesFor(_effectiveId(state)).last
        : null;
    if (last != null) {
      if (last.isAssistant && last.text.isNotEmpty && last.status.name == 'streaming') {
        return 'Hermes is typing…';
      }
    }
    return 'Hermes Agent · always available';
  }

  Widget _empty(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline,
              size: 72, color: scheme.outlineVariant),
          const SizedBox(height: 12),
          Text('Say hi to Hermes',
              style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }

  Future<void> _menu(BuildContext context, AppState state, ChatSession? session) async {
    final s = session;
    if (s == null) return;
    final scheme = Theme.of(context).colorScheme;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(s.pinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(s.pinned ? 'Unpin' : 'Pin'),
              onTap: () => Navigator.pop(context, 'pin'),
            ),
            ListTile(
              leading: Icon(s.starred ? Icons.star : Icons.star_outline),
              title: Text(s.starred ? 'Remove star' : 'Star'),
              onTap: () => Navigator.pop(context, 'star'),
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Share transcript'),
              onTap: () => Navigator.pop(context, 'share'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text('Delete conversation',
                  style: TextStyle(color: scheme.error)),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'pin':
        await state.togglePinned(s.id);
        break;
      case 'star':
        await state.toggleStarred(s.id);
        break;
      case 'share':
        await _share(state);
        break;
      case 'delete':
        await state.deleteSession(s.id);
        if (context.mounted) Navigator.of(context).pop();
        break;
    }
  }

  Future<void> _share(AppState state) async {
    final msgs = state.messagesFor(_effectiveId(state));
    final session = _session(state);
    final text = [
      'Hermes conversation: ${session?.title ?? ''}',
      '',
      ...msgs.map((m) {
        final who = switch (m.role) {
          ChatMessageRole.user => 'You',
          ChatMessageRole.assistant => 'Hermes',
          _ => 'Tool',
        };
        return '$who:\n${m.text}';
      }),
    ].join('\n\n');
    try {
      await SharePlus.instance.share(ShareParams(text: text));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not share: $e')),
        );
      }
    }
  }

  String? _emojiFor(String title) {
    final t = title.toLowerCase();
    if (t.contains('patrick')) return '💪';
    if (t.contains('homie') || t.contains('home')) return '🏠';
    if (t.contains('financ')) return '💰';
    if (t.contains('hermes')) return '🧠';
    return null;
  }
}

/// Wraps a message bubble with hold + swipe actions.
///  - Long-press: context menu (copy / share).
///  - Swipe left: copy the message.
class _InteractiveBubble extends StatefulWidget {
  final ChatMessage message;
  final Widget child;
  const _InteractiveBubble({required this.message, required this.child});

  @override
  State<_InteractiveBubble> createState() => _InteractiveBubbleState();
}

class _InteractiveBubbleState extends State<_InteractiveBubble> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey('msg-${widget.message.id}-'
          '${widget.message.timestamp.millisecondsSinceEpoch}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: scheme.secondaryContainer,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.copy_rounded, size: 18, color: scheme.onSecondaryContainer),
            const SizedBox(width: 6),
            Text('Copy', style: TextStyle(color: scheme.onSecondaryContainer)),
          ],
        ),
      ),
      confirmDismiss: (_) async {
        await _copy();
        return false; // snap back — swipe is an action, not a delete
      },
      child: GestureDetector(
        onLongPress: _showMenu,
        child: widget.child,
      ),
    );
  }

  Future<void> _copy() async {
    final text = widget.message.text;
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 1)),
    );
  }

  void _share() {
    SharePlus.instance.share(ShareParams(text: widget.message.text));
  }

  Future<void> _showMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy message'),
              onTap: () => Navigator.pop(context, 'copy'),
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Share message'),
              onTap: () => Navigator.pop(context, 'share'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'copy':
        await _copy();
        break;
      case 'share':
        _share();
        break;
    }
  }
}
