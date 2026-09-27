import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/pets.dart';
import '../../data/models.dart';
import '../../data/project_models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../projects/issue_draft_card.dart';
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

  /// Set for a chat with a project's agent: enables the Chat | Plan switch, and
  /// Plan replies that end in an issue draft render as a "Create issue" card.
  final Project? project;
  final bool planMode;

  /// Text to pre-fill the composer with (not sent): used when a chat is opened
  /// from a task, so the message starts with the issue/PR in it.
  final String? draftText;

  const ChatThreadPage({
    super.key,
    required this.sessionId,
    this.isNewChat = false,
    this.name,
    this.pendingText,
    this.isGroup = false,
    this.project,
    this.planMode = false,
    this.draftText,
  });

  @override
  State<ChatThreadPage> createState() => _ChatThreadPageState();
}

class _ChatThreadPageState extends State<ChatThreadPage> {
  final _scroll = ScrollController();
  Timer? _poll;
  late bool _plan = widget.planMode;

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
      } else {
        // Always reload from the server on open. The in-memory cache goes
        // stale once a reply arrives via push/background (the send-stream has
        // closed), so opening the thread must refetch or it shows an old
        // message until the app is restarted. Covers notification taps too.
        final st = context.read<AppState>();
        st.guard(() => st.openSession(widget.sessionId), context: 'open chat');
        _startPolling();
      }
    });
  }

  /// Poll the server for new messages while this thread is open. The bridge's
  /// WebSocket is one-shot (it closes after a reply's `done`), so there's no
  /// persistent push channel to a parked thread — a light poll is how a reply
  /// that arrives while you're sitting here shows up without reopening.
  ///
  /// The state decides whether a tick runs and how long until the next one, so
  /// an unreachable bridge is polled slower, once at a time, not every 5 s.
  static const _normal = Duration(seconds: 5);
  String get _key => 'thread:${widget.sessionId}';

  void _startPolling() => _schedule(_normal);

  void _schedule(Duration d) {
    _poll?.cancel();
    _poll = Timer(d, _tick);
  }

  Future<void> _tick() async {
    if (!mounted) return;
    final state = context.read<AppState>();
    await state.pollTick(_key, () => state.refreshThread(_effectiveId(state)),
        normal: _normal);
    if (mounted) _schedule(state.pollInterval(_key, _normal));
  }

  Future<void> _refresh() async {
    final state = context.read<AppState>();
    await state.pollTick(_key, () => state.refreshThread(_effectiveId(state)),
        normal: _normal, userInitiated: true);
  }

  @override
  void dispose() {
    _poll?.cancel();
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
                            : (widget.name ?? 'Chat')),
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
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView.builder(
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
                      final draft = widget.project != null &&
                              m.isAssistant &&
                              m.status != ChatMessageStatus.streaming
                          ? IssueDraft.tryParse(m.text)
                          : null;
                      final shown = draft == null ? m : m.copyWith(text: IssueDraft.strip(m.text));
                      final bubble = (m.isAssistant && m.id.startsWith('u-') == false)
                          ? MessageBubble(
                              message: shown,
                              avatarColor:
                                  session?.avatarColor ?? widget.project?.color ?? scheme.primary,
                              avatarImagePath: petAssetForAgent(agentName),
                              showAvatar: widget.isGroup,
                            )
                          : MessageBubble(message: shown);
                      final item = _InteractiveBubble(message: m, child: bubble);
                      if (draft == null) return item;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (shown.text.trim().isNotEmpty) item,
                          IssueDraftCard(
                            project: widget.project!,
                            sessionId: _effectiveId(state),
                            messageId: m.id,
                            draft: draft,
                          ),
                        ],
                      );
                    },
                  ),
                ),
          ),
          if (widget.isNewChat && state.creatingChat)
            _startingBar(context, state)
          else if (state.sending)
            _sendingBar(context, state),
          if (widget.project != null) _modeBar(context),
          MessageComposer(
            enabled: !(widget.isNewChat && state.creatingChat),
            initialText: widget.draftText,
            hint: widget.project == null
                ? null
                : (_plan ? 'Describe the change you want…' : 'Message ${widget.project!.name}'),
            onSend: widget.project == null
                ? null
                : (text) => state.sendMessage(text,
                    mode: _plan ? 'plan' : 'chat',
                    project: widget.project!.id,
                    profile: widget.project!.profile),
          ),
        ],
      ),
    );
  }

  /// Chat | Plan switch for project chats. Plan is read-only: the agent only
  /// looks at the code and shapes an issue; nothing changes until it's filed.
  Widget _modeBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: _plan ? scheme.tertiaryContainer.withValues(alpha: 0.6) : scheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(children: [
        SegmentedButton<bool>(
          key: const Key('mode-switch'),
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(value: false, label: Text('Chat'), icon: Icon(Icons.chat_bubble_outline, size: 16)),
            ButtonSegment(value: true, label: Text('Plan'), icon: Icon(Icons.lightbulb_outline, size: 16)),
          ],
          selected: {_plan},
          onSelectionChanged: (s) => setState(() => _plan = s.first),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _plan ? 'Shape an issue together. Read-only until you tap Create issue.' : 'Ask about the code',
            maxLines: 2,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
      ]),
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
    // Stop is two-stage, so say which stage it is in: "after this step" is a
    // promise about the reply's shape, and the user should be able to see it.
    final label = state.stopUnavailable
        ? "Can't stop this turn — the bridge is an older build without Stop"
        : state.stoppingHard
        ? 'Stopping now…'
        : state.stopRequested
            ? 'Stopping after this step…'
            : toolActive
                ? 'Hermes is running a tool…'
                : 'Hermes is typing…';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    color: state.stopUnavailable
                        ? scheme.error
                        : scheme.onSurfaceVariant)),
          ),
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
    final p = widget.project;
    if (p != null) return _plan ? 'Plan mode · ${p.repo}' : '${p.repo} agent';
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
          Text(
              widget.project == null
                  ? 'Say hi to Hermes'
                  : (_plan ? 'What should ${widget.project!.name} do next?' : 'Ask the ${widget.project!.name} agent'),
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
