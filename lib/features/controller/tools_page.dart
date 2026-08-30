import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/util/format.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';

/// Live tool-activity timeline + the tool catalog.
class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Tool catalog',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        FutureBuilder(
          future: state.repo.toolCatalog(),
          builder: (context, snap) {
            final tools = snap.data ?? const [];
            if (tools.isEmpty) return const SizedBox.shrink();
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: tools.take(14).map((t) => Chip(
                    avatar: Icon(Icons.handyman_outlined,
                        size: 18, color: scheme.primary),
                    label: Text(t),
                    side: BorderSide.none,
                    backgroundColor: scheme.surfaceContainerHigh,
                  )).toList(),
            );
          },
        ),
        const SizedBox(height: 20),
        Text('Recent activity',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        if (state.activities.isEmpty)
          const StatusMessage(title: 'No tool activity yet', icon: Icons.handyman_outlined)
        else
          ...state.activities.map((a) => Card(
                child: ListTile(
                  leading: Icon(_iconFor(a.toolName), color: scheme.primary),
                  title: Text(a.detail,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      '${a.toolName} · ${a.status} · ${formatRelativeTime(a.timestamp)}',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                  trailing: Icon(Icons.check_circle,
                      color: a.status == 'done'
                          ? Colors.green
                          : a.status == 'error'
                              ? scheme.error
                              : scheme.tertiary),
                ),
              )),
      ],
    );
  }

  IconData _iconFor(String tool) {
    switch (tool) {
      case 'terminal':
        return Icons.terminal_outlined;
      case 'web_search':
        return Icons.travel_explore_outlined;
      case 'read_file':
      case 'write_file':
      case 'patch':
        return Icons.description_outlined;
      case 'browser_navigate':
        return Icons.language_outlined;
      case 'cronjob':
        return Icons.schedule_outlined;
      case 'delegate_task':
        return Icons.account_tree_outlined;
      default:
        return Icons.handyman_outlined;
    }
  }
}
