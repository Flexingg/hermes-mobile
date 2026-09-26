import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/project_models.dart';
import '../../state/app_state.dart';

class LinkResult {
  final String name;
  final String reply;
  const LinkResult(this.name, this.reply);
}

/// Pick a GitHub repo to become a project. Hermes does the linking (clone,
/// agent profile, board, label); this sheet only asks it to.
class LinkRepoSheet extends StatefulWidget {
  const LinkRepoSheet({super.key});

  @override
  State<LinkRepoSheet> createState() => _LinkRepoSheetState();
}

class _LinkRepoSheetState extends State<LinkRepoSheet> {
  final _query = TextEditingController();
  String _coder = 'claude';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<AppState>().loadGithubRepos());
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Closes with Hermes' reply; the page that opened the sheet shows it (this
  /// sheet's context is gone once it's closed).
  Future<void> _link(GithubRepo repo) async {
    final state = context.read<AppState>();
    final reply = await state.linkRepo(repo.repo, coder: _coder);
    if (!mounted || reply == null) return;
    Navigator.of(context).pop(LinkResult(repo.name, reply));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final q = _query.text.trim().toLowerCase();
    final repos = state.githubRepos
        .where((r) => q.isEmpty || r.repo.toLowerCase().contains(q) || r.description.toLowerCase().contains(q))
        .toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          const SizedBox(height: 8),
          Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: scheme.outlineVariant, borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Row(children: [
              Text('Link a repo', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => state.loadGithubRepos()),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Hermes gives the repo its own agent, memory and work queue. '
              'Plans become issues; the coder you pick turns them into pull requests.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<String>(
              key: const Key('coder-picker'),
              segments: const [
                ButtonSegment(value: 'claude', label: Text('Claude Code'), icon: Icon(Icons.code)),
                ButtonSegment(value: 'agy', label: Text('Antigravity'), icon: Icon(Icons.rocket_launch_outlined)),
              ],
              selected: {_coder},
              onSelectionChanged: (s) => setState(() => _coder = s.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _query,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search your repos',
                filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(
            child: state.githubRepos.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: scroll,
                    itemCount: repos.length,
                    itemBuilder: (context, i) {
                      final r = repos[i];
                      final pending = state.intentPending('link:${r.repo}');
                      final anyPending = state.githubRepos.any((x) => state.intentPending('link:${x.repo}'));
                      return ListTile(
                        leading: Icon(r.private ? Icons.lock_outline : Icons.public, color: scheme.onSurfaceVariant),
                        title: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          [if (r.language != null) r.language!, if (r.description.isNotEmpty) r.description]
                              .join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: r.linkedAs != null
                            ? const Chip(label: Text('Linked'), visualDensity: VisualDensity.compact)
                            : pending
                                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                                : FilledButton.tonal(
                                    onPressed: anyPending ? null : () => _link(r),
                                    child: const Text('Link')),
                      );
                    },
                  ),
          ),
          if (state.githubRepos.any((x) => state.intentPending('link:${x.repo}')))
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Hermes is setting it up (clone, agent, board)… this can take a minute.',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
