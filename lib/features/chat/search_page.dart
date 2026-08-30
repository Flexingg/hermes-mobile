import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/util/format.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import 'chat_thread_page.dart';

/// Full-text session search page (Google-Messages-style search UX).
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  List _results = [];

  void _run(String q) async {
    final state = context.read<AppState>();
    final res = await state.repo.searchSessions(q);
    if (mounted) setState(() => _results = res);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search conversations',
            border: InputBorder.none,
          ),
          onChanged: _run,
        ),
      ),
      body: _results.isEmpty && _controller.text.isEmpty
          ? const StatusMessage(
              title: 'Search your chats',
              subtitle: 'Find sessions and conversations across Hermes.',
              icon: Icons.search)
          : _results.isEmpty
              ? const StatusMessage(
                  title: 'No results',
                  icon: Icons.search_off)
              : ListView.builder(
                  itemCount: _results.length,
                  itemBuilder: (context, i) {
                    final s = _results[i];
                    return ListTile(
                      leading: Avatar(
                          label: s.title,
                          color: s.avatarColor,
                          radius: 20),
                      title: Text(s.title),
                      subtitle: Text(s.lastPreview,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: Text(
                          formatRelativeTime(s.lastTimestamp),
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                      onTap: () async {
                        await state.openSession(s.id);
                        if (!context.mounted) return;
                        Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                              builder: (_) => ChatThreadPage(sessionId: s.id)),
                        );
                      },
                    );
                  },
                ),
    );
  }
}
