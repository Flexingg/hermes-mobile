import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/util/format.dart';
import '../../data/project_models.dart';
import '../../state/app_state.dart';
import '../chat/chat_thread_page.dart';
import 'link_repo_sheet.dart';
import 'project_page.dart';
import 'project_widgets.dart';

/// Home for project work: Hermes (the orchestrator) pinned on top, then one card
/// per linked repo with where its work stands.
class ProjectsPage extends StatefulWidget {
  const ProjectsPage({super.key});

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    // Work moves in the background (queued -> working -> ready); keep up.
    _poll = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) context.read<AppState>().loadProjects();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final state = context.read<AppState>();
    await Future.wait([state.loadProjects(), state.loadAgents()]);
  }

  Future<void> _openLink() async {
    final result = await showModalBottomSheet<LinkResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => const LinkRepoSheet(),
    );
    if (result != null && mounted) showHermesReply(context, 'Linked ${result.name}', result.reply);
  }

  Future<void> _openHermes() async {
    final state = context.read<AppState>();
    final sid = state.orchestratorSessionId ?? await state.openOrchestrator();
    if (sid == null || !mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ChatThreadPage(sessionId: sid, name: 'Hermes')));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final projects = [...state.projects]
      ..sort((a, b) => a.status.index.compareTo(b.status.index)); // most urgent first
    return Scaffold(
      appBar: AppBar(
        title: const Text('Projects', style: TextStyle(fontWeight: FontWeight.w600)),
        actions: [
          IconButton(tooltip: 'Link a repo', icon: const Icon(Icons.add_link), onPressed: _openLink),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
          children: [
            _HermesCard(projects: state.projects, agents: state.agents, onTap: _openHermes),
            const SizedBox(height: 8),
            if (projects.isEmpty)
              _EmptyProjects(onLink: _openLink)
            else
              ...projects.map((p) => _ProjectCard(project: p)),
          ],
        ),
      ),
    );
  }
}

class _HermesCard extends StatelessWidget {
  final List<Project> projects;
  final AgentSnapshot? agents;
  final VoidCallback onTap;
  const _HermesCard({required this.projects, required this.agents, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    int sum(int Function(Project) f) => projects.fold(0, (a, p) => a + f(p));
    final parts = [
      if (sum((p) => p.needsYou) > 0) '${sum((p) => p.needsYou)} need you',
      if (sum((p) => p.ready) > 0) '${sum((p) => p.ready)} ready',
      if (sum((p) => p.working) > 0) '${sum((p) => p.working)} working',
      if (sum((p) => p.queued) > 0) '${sum((p) => p.queued)} queued',
      if (agents != null) '${(agents!.memAvailableMb / 1024).toStringAsFixed(1)} GB free',
    ];
    return Card(
      key: const Key('hermes-card'),
      color: scheme.primaryContainer,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            const Text('🧠', style: TextStyle(fontSize: 34)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Hermes',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700, color: scheme.onPrimaryContainer)),
                const SizedBox(height: 2),
                Text(parts.isEmpty ? 'Orchestrator · all quiet' : parts.join(' · '),
                    style: TextStyle(color: scheme.onPrimaryContainer.withValues(alpha: 0.8))),
              ]),
            ),
            Icon(Icons.chevron_right, color: scheme.onPrimaryContainer),
          ]),
        ),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  final Project project;
  const _ProjectCard({required this.project});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final last = project.lastTask;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => ProjectPage(projectId: project.id))),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ProjectAvatar(project),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(project.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 6),
                  AwakeDot(project.awake),
                ]),
                const SizedBox(height: 2),
                Text('${project.repo} · ${project.coderLabel}',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                if (last != null) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    TaskPhaseChip(last.phase, dense: true),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(last.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                    ),
                    if (last.updatedAt != null)
                      Text(formatRelativeTime(last.updatedAt!),
                          style: TextStyle(fontSize: 11, color: scheme.outline)),
                  ]),
                ],
              ]),
            ),
            const SizedBox(width: 8),
            ProjectStatusChip(project.status, dense: true),
          ]),
        ),
      ),
    );
  }
}

class _EmptyProjects extends StatelessWidget {
  final VoidCallback onLink;
  const _EmptyProjects({required this.onLink});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(children: [
        Icon(Icons.folder_special_outlined, size: 64, color: scheme.outlineVariant),
        const SizedBox(height: 12),
        Text('No projects yet', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text('Link a GitHub repo. You plan issues with its agent; Hermes ships them as PRs.',
            textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: onLink, icon: const Icon(Icons.add_link), label: const Text('Link a repo')),
      ]),
    );
  }
}
