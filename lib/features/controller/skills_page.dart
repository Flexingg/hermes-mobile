import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';

/// Browse installed Hermes skills and toggle them.
class SkillsPage extends StatelessWidget {
  const SkillsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;

    if (state.skills.isEmpty) {
      return const StatusMessage(title: 'No skills installed', icon: Icons.widgets_outlined);
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: state.skills.length,
      itemBuilder: (context, i) {
        final s = state.skills[i];
        return Card(
          child: ListTile(
            leading: Icon(Icons.widgets_outlined, color: scheme.primary),
            title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 2),
                Text(s.description, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 4,
                  children: s.tags
                      .map((t) => Text('#$t ',
                          style: TextStyle(
                              fontSize: 12, color: scheme.tertiary)))
                      .toList(),
                ),
              ],
            ),
            trailing: Switch(
              value: s.enabled,
              onChanged: (_) => context.read<AppState>().toggleSkillById(s.id),
            ),
          ),
        );
      },
    );
  }
}
