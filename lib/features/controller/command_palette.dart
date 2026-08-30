import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';

/// Command palette — Google Messages style overlay listing slash-commands and
/// tools. Tapping one inserts/executes it against the current chat.
class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key});

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final _controller = TextEditingController();
  List _items = [];

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _items = state.commands;
    state.repo.toolCatalog().then((tools) {
      if (mounted) {
        setState(() => _items = [...state.commands, ...tools.map((t) => _Tool(t))]);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final query = _controller.text.toLowerCase();
    final filtered = _items.where((i) =>
        i.label.toLowerCase().contains(query)).toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Search commands & tools',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          Expanded(
            child: filtered.isEmpty
                ? const Center(child: Text('No commands found'))
                : ListView.builder(
                    controller: scrollController,
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final item = filtered[i];
                      return ListTile(
                        leading: Icon(_iconFor(item), color: scheme.primary),
                        title: Text(item.label,
                            style: const TextStyle(fontFamily: 'monospace')),
                        subtitle: item.description.isNotEmpty
                            ? Text(item.description,
                                maxLines: 1, overflow: TextOverflow.ellipsis)
                            : null,
                        onTap: () => _run(item),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  IconData _iconFor(dynamic item) {
    if (item is _Tool) return Icons.handyman_outlined;
    switch (item.icon as String) {
      case 'forum':
        return Icons.forum_outlined;
      case 'memory':
        return Icons.memory_outlined;
      case 'widgets':
        return Icons.widgets_outlined;
      case 'schedule':
        return Icons.schedule_outlined;
      case 'medical':
        return Icons.medical_information_outlined;
      case 'smart_toy':
        return Icons.smart_toy_outlined;
      case 'tune':
        return Icons.tune_outlined;
      case 'terminal':
        return Icons.terminal_outlined;
      default:
        return Icons.chevron_right_rounded;
    }
  }

  Future<void> _run(dynamic item) async {
    final state = context.read<AppState>();
    final label = item.label as String;
    Navigator.of(context).pop();

    // If there's an active session, send it as a message.
    if (state.activeSessionId != null) {
      await state.sendMessage(label);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Opened $label — start a chat to run it.')),
      );
    }
  }
}

class _Tool {
  final String label;
  final String description;
  const _Tool(this.label) : description = 'Tool';
  @override
  String toString() => label;
}
