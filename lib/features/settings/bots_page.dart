import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';

/// Manage Hermes agents (bots) — each bot is a Hermes profile. Lets you
/// create, edit (pet/description/soul), and delete bots, mirroring the
/// Hermes desktop experience.
class BotsPage extends StatelessWidget {
  const BotsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Bots')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createDialog(context),
        icon: const Icon(Icons.add),
        label: const Text('New bot'),
      ),
      body: state.bots.isEmpty
          ? Center(
              child: Text('No bots yet. Tap + to create one.',
                  style: TextStyle(color: scheme.onSurfaceVariant)))
          : RefreshIndicator(
              onRefresh: state.loadBots,
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 88),
                itemCount: state.bots.length,
                itemBuilder: (context, i) {
                  final b = state.bots[i];
                  return ListTile(
                    leading: Avatar(
                      label: b.name,
                      color: scheme.primary,
                      imagePath:
                          b.pet != null ? 'assets/pets/${b.pet}.png' : null,
                      radius: 22,
                    ),
                    title: Text(b.name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      b.description.isEmpty ? 'No description' : b.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: b.model != null
                        ? Text(
                            '${b.provider ?? ''}\n${b.model ?? ''}',
                            textAlign: TextAlign.end,
                            style: TextStyle(
                                fontSize: 10, color: scheme.onSurfaceVariant),
                          )
                        : null,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => BotEditPage(bot: b)),
                    ),
                  );
                },
              ),
            ),
    );
  }

  Future<void> _createDialog(BuildContext context) async {
    final app = context.read<AppState>();
    final name = TextEditingController();
    final desc = TextEditingController();
    final res = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New bot'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Name', hintText: 'e.g. sales-bot'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: desc,
              decoration: const InputDecoration(
                  labelText: 'Description (optional)'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Create')),
        ],
      ),
    );
    if (res == true && name.text.trim().isNotEmpty) {
      try {
        await app.createBot(
            name: name.text.trim(), description: desc.text.trim());
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Create failed: $e')));
        }
      }
    }
  }
}

class BotEditPage extends StatefulWidget {
  final Bot bot;
  const BotEditPage({super.key, required this.bot});

  @override
  State<BotEditPage> createState() => _BotEditPageState();
}

class _BotEditPageState extends State<BotEditPage> {
  late final TextEditingController _desc =
      TextEditingController(text: widget.bot.description);
  late final TextEditingController _soul =
      TextEditingController(text: widget.bot.soul);
  String? _pet;

  @override
  void initState() {
    super.initState();
    _pet = widget.bot.pet;
  }

  @override
  void dispose() {
    _desc.dispose();
    _soul.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final app = context.read<AppState>();
    try {
      await app.updateBot(widget.bot.id,
          description: _desc.text, pet: _pet, soul: _soul.text);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Saved')));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
  }

  Future<void> _delete() async {
    final app = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete bot?'),
        content: Text('Delete ${widget.bot.name}? This removes its profile '
            'and conversation history.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      try {
        await app.deleteBot(widget.bot.id);
        if (mounted) Navigator.pop(context);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final pets = state.botPets;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.bot.name),
        actions: [
          if (!widget.bot.isDefault)
            IconButton(
                icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Pet',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: scheme.primary)),
          const SizedBox(height: 8),
          if (pets.isEmpty)
            Text('No pets available.',
                style: TextStyle(color: scheme.onSurfaceVariant))
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4, mainAxisSpacing: 10, crossAxisSpacing: 10),
              itemCount: pets.length,
              itemBuilder: (context, i) {
                final slug = pets[i];
                final selected = _pet == slug;
                return GestureDetector(
                  onTap: () => setState(() => _pet = slug),
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected ? scheme.primary : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.asset('assets/pets/$slug.png',
                                fit: BoxFit.cover),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(slug,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 10)),
                      ],
                    ),
                  ),
                );
              },
            ),
          const SizedBox(height: 16),
          Text('Description',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: scheme.primary)),
          const SizedBox(height: 8),
          TextField(
              controller: _desc,
              maxLines: 2,
              decoration: const InputDecoration(
                  hintText: 'What is this bot for?',
                  border: OutlineInputBorder())),
          const SizedBox(height: 16),
          Text('Soul (persona)',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: scheme.primary)),
          const SizedBox(height: 8),
          TextField(
            controller: _soul,
            maxLines: 10,
            decoration: const InputDecoration(
                hintText: 'Who is this bot? How should it behave?',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
