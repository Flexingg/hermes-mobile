import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';

/// Manage connected Hermes servers and their agents/bots.
class ServersPage extends StatelessWidget {
  const ServersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Servers & agents')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addServer(context, state),
        icon: const Icon(Icons.add),
        label: const Text('Add server'),
      ),
      body: state.servers.isEmpty
          ? const StatusMessage(
              title: 'No servers configured',
              subtitle: 'Add your Hermes gateway to get started.',
              icon: Icons.dns_outlined)
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: state.servers.length,
              itemBuilder: (context, i) {
                final s = state.servers[i];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: ExpansionTile(
                    leading: Avatar(
                        label: s.name, color: s.accentColor, radius: 20),
                    title: Row(children: [
                      Flexible(child: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                      if (s.isDefault)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text('DEFAULT',
                              style: TextStyle(fontSize: 10, color: scheme.tertiary)),
                        ),
                    ]),
                    subtitle: Text(s.baseUrl,
                        style: const TextStyle(fontFamily: 'monospace')),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => state.repo.removeServer(s.id).then(
                          (_) => state.refreshServers()),
                    ),
                    children: [
                      ...s.bots.map((b) => ListTile(
                            dense: true,
                            leading: Text(b.emoji, style: const TextStyle(fontSize: 20)),
                            title: Text(b.name),
                            subtitle: Text('${b.description} · ${b.model}'),
                          )),
                    ],
                  ),
                );
              },
            ),
    );
  }

  void _addServer(BuildContext context, AppState state) {
    final name = TextEditingController();
    final url = TextEditingController(text: 'http://');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 12),
            TextField(controller: url,
                decoration: const InputDecoration(labelText: 'Base URL (gateway)')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final p = ServerProfile(
                id: 'srv-${DateTime.now().millisecondsSinceEpoch}',
                name: name.text.trim().isEmpty ? 'Server' : name.text.trim(),
                baseUrl: url.text.trim(),
                bots: [
                  const BotProfile(
                      id: 'bot-hermes', name: '@hermes',
                      description: 'Main assistant', model: 'deepseek-v4-flash',
                      emoji: '🧠'),
                ],
              );
              await state.repo.addServer(p);
              await state.refreshServers();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}
