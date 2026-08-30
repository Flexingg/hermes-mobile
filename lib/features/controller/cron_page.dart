import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/util/format.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';

/// Manage Hermes cron routines: view, enable/disable, run now, add, edit.
class CronPage extends StatelessWidget {
  const CronPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;

    if (state.cronJobs.isEmpty) {
      return const StatusMessage(
          title: 'No scheduled routines', icon: Icons.schedule_outlined);
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: state.cronJobs.length + 1,
      itemBuilder: (context, i) {
        if (i == state.cronJobs.length) {
          return Padding(
            padding: const EdgeInsets.all(8),
            child: FilledButton.tonalIcon(
              onPressed: () => _edit(context, state, null),
              icon: const Icon(Icons.add),
              label: const Text('New routine'),
            ),
          );
        }
        final j = state.cronJobs[i];
        return Card(
          child: Column(
            children: [
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(Icons.schedule,
                      color: scheme.onPrimaryContainer, size: 20),
                ),
                title: Row(
                  children: [
                    Expanded(
                        child: Text(j.name,
                            style: const TextStyle(fontWeight: FontWeight.w600))),
                    if (!j.enabled)
                      Text('OFF',
                          style: TextStyle(
                              color: scheme.error,
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
                  ],
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 2),
                    Text('⏰ ${j.schedule} · ${j.deliver}',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                    const SizedBox(height: 4),
                    Text(j.prompt, maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (j.lastRun != null) ...[
                      const SizedBox(height: 4),
                      Text('${j.lastStatus ?? ''} · ${formatRelativeTime(j.lastRun!)}',
                          style: TextStyle(
                              fontSize: 12, color: scheme.tertiary)),
                    ],
                  ],
                ),
                isThreeLine: true,
                trailing: Switch(
                  value: j.enabled,
                  onChanged: (v) {
                    final updated = j.copyWith(enabled: v);
                    context.read<AppState>().updateCron(updated);
                  },
                ),
              ),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: () => _edit(context, state, j),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit'),
                  ),
                  TextButton.icon(
                    onPressed: () => context.read<AppState>().runCron(j.id),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Run now'),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        context.read<AppState>().deleteCron(j.id),
                    icon: Icon(Icons.delete_outline, size: 18, color: scheme.error),
                    label: Text('Delete', style: TextStyle(color: scheme.error)),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _edit(BuildContext context, AppState state, CronJob? existing) {
    final name = TextEditingController(text: existing?.name ?? '');
    final schedule = TextEditingController(text: existing?.schedule ?? '');
    final prompt = TextEditingController(text: existing?.prompt ?? '');
    final deliver = TextEditingController(text: existing?.deliver ?? 'DM: me');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(existing == null ? 'New routine' : 'Edit routine'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
              const SizedBox(height: 12),
              TextField(controller: schedule, decoration: const InputDecoration(labelText: 'Schedule (e.g. 8:00 PM daily)')),
              const SizedBox(height: 12),
              TextField(controller: prompt, decoration: const InputDecoration(labelText: 'Prompt'), maxLines: 3),
              const SizedBox(height: 12),
              TextField(controller: deliver, decoration: const InputDecoration(labelText: 'Deliver to')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final job = CronJob(
                id: existing?.id ?? 'cron-${DateTime.now().millisecondsSinceEpoch}',
                name: name.text.trim(),
                schedule: schedule.text.trim(),
                prompt: prompt.text.trim(),
                deliver: deliver.text.trim(),
                enabled: existing?.enabled ?? true,
                lastRun: existing?.lastRun,
                lastStatus: existing?.lastStatus,
              );
              if (existing == null) {
                await state.createCron(job);
              } else {
                await state.updateCron(job);
              }
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
