import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/pets.dart';
import '../../core/util/format.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../settings/servers_page.dart';
import '../terminal/terminal_page.dart';
import 'chat_thread_page.dart';
import 'group_chat_page.dart';
import 'new_chat_sheet.dart';
import 'search_page.dart';

/// Google-Messages-style conversation list.
class ChatListPage extends StatelessWidget {
  const ChatListPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats', style: TextStyle(fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SearchPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.terminal_rounded),
            tooltip: 'Host terminal',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const TerminalPage()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: IconButton(
              icon: const Avatar(label: '', color: Color(0xFF00695C), emoji: '🧠', radius: 17),
              tooltip: 'Profile / servers',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ServersPage()),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
          builder: (_) => const NewChatSheet(),
        ),
        tooltip: 'Start chat',
        child: const Icon(Icons.chat_bubble_outline_rounded),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await state.refreshSessions();
          await state.loadGroups();
        },
        child: (state.sessions.isEmpty && state.groups.isEmpty)
            ? const StatusMessage(
                title: 'No conversations yet',
                subtitle: 'Tap + to start chatting with Hermes or make a group.',
                icon: Icons.forum_outlined)
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 88),
                itemCount: state.groups.length +
                    state.sessions.length +
                    (state.groups.isNotEmpty ? 1 : 0),
                itemBuilder: (context, i) {
                  final gCount = state.groups.length;
                  final headerOffset = gCount > 0 ? 1 : 0;
                  if (gCount > 0 && i == 0) {
                    return const _SectionHeader('Groups');
                  }
                  if (i < headerOffset + gCount) {
                    final g = state.groups[i - headerOffset];
                    return _GroupTile(
                      group: g,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => GroupChatPage(
                              groupId: g.id,
                              name: g.name,
                              agents: g.agents,
                            ),
                          ),
                        );
                      },
                    );
                  }
                  final s = state.sessions[i - headerOffset - gCount];
                  return _SessionTile(
                    session: s,
                    state: state,
                    onTap: () async {
                      await state.openSession(s.id);
                      if (!context.mounted) return;
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => ChatThreadPage(sessionId: s.id)),
                      );
                    },
                  );
                },
              ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(label.toUpperCase(),
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
    );
  }
}

class _GroupTile extends StatelessWidget {
  final GroupChat group;
  final VoidCallback onTap;
  const _GroupTile({required this.group, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onTap,
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: scheme.primaryContainer,
            child: Icon(Icons.groups, color: scheme.onPrimaryContainer),
          ),
          if (group.agents.isNotEmpty)
            Positioned(
              right: -2,
              bottom: -2,
              child: CircleAvatar(
                radius: 10,
                backgroundColor: scheme.surface,
                child: ClipOval(
                  child: Image.asset(petAssetForAgent(group.agents.first),
                      width: 18, height: 18, fit: BoxFit.cover),
                ),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(group.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Text(formatRelativeTime(group.lastTimestamp),
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(group.lastPreview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final ChatSession session;
  final AppState state;
  final VoidCallback onTap;

  const _SessionTile({
    required this.session,
    required this.state,
    required this.onTap,
  });

  /// Line 1 — who you're chatting with.
  String get _agentName => resolveAgentName(state.servers, session);

  /// Line 2 — the subject of the conversation.
  String get _subject {
    final agent = _agentName;
    final t = session.title;
    if (t.isEmpty || t.toLowerCase() == agent.toLowerCase()) {
      return session.lastPreview;
    }
    return t;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unread = session.unreadCount > 0;
    final agent = _agentName;
    final subject = _subject;
    final nameStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
          fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
        );
    final subjectStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: unread ? scheme.onSurface : scheme.onSurfaceVariant,
          fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
        );

    return Dismissible(
      key: ValueKey(session.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: scheme.errorContainer,
        child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
      ),
      onDismissed: (_) => context.read<AppState>().deleteSession(session.id),
      child: ListTile(
        onTap: onTap,
        leading: Avatar(
          label: agent,
          color: session.avatarColor,
          imagePath: petAssetForAgent(agent),
          hasUnread: unread,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(agent,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: nameStyle),
            ),
            Text(formatRelativeTime(session.lastTimestamp),
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
        subtitle: Row(
          children: [
            if (session.starred) ...[
              Icon(Icons.star, size: 16, color: scheme.tertiary),
              const SizedBox(width: 4),
            ],
            if (session.pinned) ...[
              Icon(Icons.push_pin, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text(subject,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: subjectStyle),
            ),
          ],
        ),
      ),
    );
  }
}
