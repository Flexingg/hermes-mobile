import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';

/// Webhook routes that can be fired from a button.
class WebhooksPage extends StatelessWidget {
  const WebhooksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;

    if (state.webhooks.isEmpty) {
      return const StatusMessage(
          title: 'No webhook routes', icon: Icons.bolt_outlined);
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: state.webhooks.length,
      itemBuilder: (context, i) {
        final w = state.webhooks[i];
        return Card(
          child: ListTile(
            leading: Icon(Icons.bolt_outlined, color: scheme.tertiary),
            title: Text(w.name, style: const TextStyle(fontFamily: 'monospace')),
            subtitle: Text(w.description),
            trailing: FilledButton.tonalIcon(
              onPressed: () async {
                await context.read<AppState>().triggerWebhookById(w.id);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Triggered ${w.name}')),
                  );
                }
              },
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Fire'),
            ),
          ),
        );
      },
    );
  }
}
