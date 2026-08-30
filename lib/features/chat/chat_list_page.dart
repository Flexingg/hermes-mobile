import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/util/format.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../settings/servers_page.dart';
import 'chat_thread_page.dart';
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
        onRefresh: () => state.refreshSessions(),
        child: state.sessions.isEmpty
            ? const StatusMessage(
                title: 'No conversations yet',
                subtitle: 'Tap + to start chatting with Hermes.',
                icon: Icons.forum_outlined)
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 88),
                itemCount: state.sessions.length,
                itemBuilder: (context, i) {
                  final s = state.sessions[i];
                  return _SessionTile(
                    session: s,
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

class _SessionTile extends StatelessWidget {
  final dynamic session; // ChatSession
  final VoidCallback onTap;

  const _SessionTile({required this.session, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = session;
    final unread = s.unreadCount > 0;
    final nameStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
          fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
        );
    final previewStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: unread ? scheme.onSurface : scheme.onSurfaceVariant,
          fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
        );

    return Dismissible(
      key: ValueKey(s.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: scheme.errorContainer,
        child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
      ),
      onDismissed: (_) =>
          context.read<AppState>().deleteSession(s.id as String),
      child: ListTile(
        onTap: onTap,
        leading: Avatar(
          label: s.title as String,
          color: s.avatarColor as Color,
          emoji: _emojiFor(s.title as String),
          hasUnread: unread,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(s.title as String,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: nameStyle),
            ),
            Text(formatRelativeTime(s.lastTimestamp as DateTime),
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
        subtitle: Row(
          children: [
            if (s.starred as bool) ...[
              Icon(Icons.star, size: 16, color: scheme.tertiary),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text(s.lastPreview as String,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: previewStyle),
            ),
          ],
        ),
      ),
    );
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
