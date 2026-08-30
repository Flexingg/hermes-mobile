import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/util/format.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';

/// View/search/edit Hermes persistent memory.
class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key});

  @override
  State<MemoryPage> createState() => MemoryPageState();
}

class MemoryPageState extends State<MemoryPage> {
  String _tab = 'user'; // 'user' | 'memory'
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final entries = state.memory
        .where((e) => e.category == _tab)
        .where((e) =>
            _search.text.isEmpty ||
            e.content.toLowerCase().contains(_search.text.toLowerCase()))
        .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'Search memory',
              prefixIcon: Icon(Icons.search),
              suffixIcon: Icon(Icons.memory),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'user', label: Text('About you')),
              ButtonSegment(value: 'memory', label: Text('Agent notes')),
            ],
            selected: {_tab},
            onSelectionChanged: (s) => setState(() => _tab = s.first),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: entries.isEmpty
              ? const StatusMessage(title: 'No entries', icon: Icons.memory)
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    return Card(
                      child: ListTile(
                        leading: Icon(
                            e.category == 'user'
                                ? Icons.person_outline
                                : Icons.psychology_outlined,
                            color: scheme.primary),
                        title: Text(e.content,
                            maxLines: 3, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            '${e.category} · ${formatRelativeTime(e.createdAt)}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () =>
                              context.read<AppState>().deleteMemoryEntry(e.id),
                        ),
                        onTap: () => _edit(context, state, e),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _edit(BuildContext context, AppState state, dynamic entry) {
    showDialog(
      context: context,
      builder: (context) {
        final c = TextEditingController(text: entry.content);
        return AlertDialog(
          title: const Text('Edit memory'),
          content: TextField(
            controller: c,
            maxLines: 4,
            decoration: const InputDecoration(hintText: 'Memory content'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () async {
                  await state.deleteMemoryEntry(entry.id);
                  await state.addMemoryEntry(entry.category, c.text.trim());
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('Save')),
          ],
        );
      },
    );
  }

  void _add(BuildContext context, AppState state) {
    showDialog(
      context: context,
      builder: (context) {
        final c = TextEditingController();
        return AlertDialog(
          title: const Text('Add memory'),
          content: TextField(
            controller: c,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'What should Hermes remember?'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () async {
                  if (c.text.trim().isEmpty) return;
                  await state.addMemoryEntry(_tab, c.text.trim());
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('Save')),
          ],
        );
      },
    );
  }

  void showAddButton(BuildContext context) {
    _add(context, context.read<AppState>());
  }
}
