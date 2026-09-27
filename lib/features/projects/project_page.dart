import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/util/format.dart';
import '../../data/project_models.dart';
import '../../state/app_state.dart';
import '../chat/chat_thread_page.dart';
import 'project_widgets.dart';
import 'task_card.dart';

/// One project: its agent's chats (Chat and Plan), the work in flight, the
/// agent's memory, and how it codes.
class ProjectPage extends StatefulWidget {
  final String projectId;
  final int initialTab;
  const ProjectPage({super.key, required this.projectId, this.initialTab = 0});

  static const workTab = 1;

  @override
  State<ProjectPage> createState() => _ProjectPageState();
}

class _ProjectPageState extends State<ProjectPage> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) context.read<AppState>().loadProject(widget.projectId);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final state = context.read<AppState>();
    await state.loadProject(widget.projectId);
    final p = state.projectById(widget.projectId);
    await Future.wait([
      state.loadProjectSessions(widget.projectId),
      state.loadProjectNotes(widget.projectId),
      if (p != null) state.loadProjectMemory(p.profile),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final p = state.projectDetail(widget.projectId) ?? state.projectById(widget.projectId);
    if (p == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    return DefaultTabController(
      length: 5,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Row(children: [
            ProjectAvatar(p, size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                Text('${p.repo} · ${p.coderLabel}',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ]),
            ),
          ]),
          actions: [
            Padding(padding: const EdgeInsets.only(right: 12), child: ProjectStatusChip(p.status, dense: true)),
          ],
          bottom: TabBar(
            labelPadding: const EdgeInsets.symmetric(horizontal: 8),
            tabs: [
              const Tab(text: 'Chat'),
              Tab(child: _WorkTabLabel(p)),
              Tab(child: _NotesTabLabel(p)),
              const Tab(text: 'Memory'),
              const Tab(text: 'Settings'),
            ],
          ),
        ),
        body: TabBarView(children: [
          _ChatsTab(project: p, onRefresh: _refresh),
          _WorkTab(project: p, onRefresh: _refresh),
          _NotesTab(project: p),
          _MemoryTab(project: p),
          _SettingsTab(project: p),
        ]),
      ),
    );
  }
}

class _WorkTabLabel extends StatelessWidget {
  final Project p;
  const _WorkTabLabel(this.p);

  @override
  Widget build(BuildContext context) {
    final n = p.needsYou + p.ready;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const Text('Work'),
      if (n > 0) ...[const SizedBox(width: 6), Badge(label: Text('$n'))],
    ]);
  }
}

/// Notes are yours, and there is no badge to earn: the count is only there so
/// you can see at a glance whether you have written anything down.
class _NotesTabLabel extends StatelessWidget {
  final Project p;
  const _NotesTabLabel(this.p);

  @override
  Widget build(BuildContext context) {
    final n = context.watch<AppState>().projectNotesFor(p.id).length;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const Text('Notes'),
      if (n > 0) ...[const SizedBox(width: 6), Badge(label: Text('$n'))],
    ]);
  }
}

// ---- Chat ------------------------------------------------------------------------
class _ChatsTab extends StatelessWidget {
  final Project project;
  final Future<void> Function() onRefresh;
  const _ChatsTab({required this.project, required this.onRefresh});

  Future<void> _start(BuildContext context, {required bool plan}) async {
    final state = context.read<AppState>();
    final sid = await state.createProjectChat(project, plan ? 'Plan · ${project.name}' : project.name);
    if (sid == null || !context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ChatThreadPage(
            sessionId: sid, name: project.name, project: project, planMode: plan)));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final chats = state.projectSessionsFor(project.id);
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          children: [
            Card(
              elevation: 0,
              color: scheme.tertiaryContainer,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: ListTile(
                key: const Key('plan-issue'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                leading: Icon(Icons.lightbulb_outline, color: scheme.onTertiaryContainer),
                title: Text('Plan an issue',
                    style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onTertiaryContainer)),
                subtitle: Text(
                    'Talk it through with the ${project.name} agent. Once the issue is filed, '
                    '${project.coderLabel} builds it in the background.',
                    style: TextStyle(color: scheme.onTertiaryContainer.withValues(alpha: 0.8))),
                onTap: () => _start(context, plan: true),
              ),
            ),
            const SizedBox(height: 8),
            if (chats.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('No conversations with this agent yet.',
                    textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
              )
            else
              ...chats.map((s) => ListTile(
                    leading: Icon(
                        s.title.startsWith('Plan') ? Icons.lightbulb_outline : Icons.chat_bubble_outline,
                        color: scheme.onSurfaceVariant),
                    title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: s.lastPreview.isEmpty
                        ? null
                        : Text(s.lastPreview, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Text(formatRelativeTime(s.lastTimestamp),
                        style: TextStyle(fontSize: 11, color: scheme.outline)),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ChatThreadPage(
                            sessionId: s.id,
                            name: project.name,
                            project: project,
                            planMode: s.title.startsWith('Plan')))),
                  )),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'project-chat',
        onPressed: () => _start(context, plan: false),
        icon: const Icon(Icons.chat_outlined),
        label: const Text('Chat'),
      ),
    );
  }
}

// ---- Work -------------------------------------------------------------------------
class _WorkTab extends StatelessWidget {
  final Project project;
  final Future<void> Function() onRefresh;
  const _WorkTab({required this.project, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tasks = project.tasks;
    final active = tasks.where((t) => t.phase.isActive || t.phase == TaskPhase.needsYou || t.phase == TaskPhase.ready).toList();
    final done = tasks.where((t) => !active.contains(t)).toList();
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          if (tasks.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Column(children: [
                Icon(Icons.inbox_outlined, size: 56, color: scheme.outlineVariant),
                const SizedBox(height: 10),
                Text('Nothing in flight', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text('Plan an issue in Chat, or label one `mercury` on GitHub.',
                    textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
              ]),
            ),
          ...active.map((t) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TaskCard(project: project, task: t))),
          if (done.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
              child: Text('Earlier', style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
            ),
            ...done.map((t) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TaskCard(project: project, task: t))),
          ],
        ],
      ),
    );
  }
}

// ---- Notes ------------------------------------------------------------------------
/// Notes are the user's own scratch space for a project, and the one thing on
/// this screen that is deliberately NOT the agent's: they are stored beside the
/// registry, never injected into a prompt, and only reach the agent when the
/// user taps "Ask about this". Memory (the next tab) is the opposite — it is
/// prompt-visible on every turn.
class _NotesTab extends StatelessWidget {
  final Project project;
  const _NotesTab({required this.project});

  Future<void> _write(BuildContext context, {ProjectNote? editing}) async {
    final ctl = TextEditingController(text: editing?.text ?? '');
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(editing == null ? 'New note' : 'Edit note'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: 8,
          minLines: 3,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Anything you want to come back to: a hunch, a rough edge, a thing to try',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (text == null || text.isEmpty || !context.mounted) return;
    final state = context.read<AppState>();
    await state.guard(
        () => editing == null
            ? state.addProjectNote(project.id, text)
            : state.editProjectNote(project.id, editing.id, text),
        context: 'save note');
  }

  /// Open a chat with the project's agent with the note pre-filled. The note
  /// only reaches the agent through this: the user decides, per note.
  Future<void> _ask(BuildContext context, ProjectNote n) async {
    final state = context.read<AppState>();
    final sid = await state.createProjectChat(project, project.name);
    if (sid == null || !context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ChatThreadPage(
            sessionId: sid,
            name: project.name,
            project: project,
            draftText: 'About my note:\n\n"${n.text}"\n\n')));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final notes = state.projectNotesFor(project.id);
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text('Your scratch space for ${project.name}. Nothing here is sent to '
                'the agent or costs anything to keep — ask about one and it becomes the '
                'start of a conversation.',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
          ),
          if (notes.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(children: [
                Icon(Icons.sticky_note_2_outlined, size: 48, color: scheme.outlineVariant),
                const SizedBox(height: 8),
                Text('No notes yet.', textAlign: TextAlign.center, style: TextStyle(color: scheme.outline)),
              ]),
            )
          else
            ...notes.reversed.map((n) => Card(
                  elevation: 0,
                  color: scheme.surfaceContainerLow,
                  child: ListTile(
                    key: Key('note-${n.id}'),
                    isThreeLine: n.text.length > 80,
                    title: Text(n.text, style: const TextStyle(fontSize: 14)),
                    subtitle: Text(
                        '${formatRelativeTime(n.at)}${n.updatedAt == null ? '' : ' · edited'}',
                        style: TextStyle(fontSize: 11, color: scheme.outline)),
                    onTap: () => _write(context, editing: n),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'edit') _write(context, editing: n);
                        if (v == 'ask') _ask(context, n);
                        if (v == 'delete') {
                          state.guard(() => state.deleteProjectNote(project.id, n.id), context: 'delete note');
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'ask', child: Text('Ask the agent about this')),
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ),
                )),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'project-note',
        tooltip: 'Jot a note',
        onPressed: () => _write(context),
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ---- Memory -----------------------------------------------------------------------
class _MemoryTab extends StatelessWidget {
  final Project project;
  const _MemoryTab({required this.project});

  Future<void> _add(BuildContext context) async {
    final ctl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remember'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'e.g. Run the Gradle build with --no-daemon'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (text == null || text.isEmpty || !context.mounted) return;
    final state = context.read<AppState>();
    await state.guard(() => state.addProjectMemory(project.profile, text), context: 'save memory');
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final entries = state.projectMemoryFor(project.profile);
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text('What the ${project.name} agent remembers about this repo. '
                'It adds to this as it works; you can too.',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
          ),
          if (entries.isEmpty)
            Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Nothing yet.', textAlign: TextAlign.center, style: TextStyle(color: scheme.outline))),
          ...entries.map((m) => Card(
                elevation: 0,
                color: scheme.surfaceContainerLow,
                child: ListTile(
                  title: Text(m.content, style: const TextStyle(fontSize: 14)),
                  trailing: IconButton(
                    tooltip: 'Forget',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => state.guard(() => state.deleteProjectMemory(project.profile, m.id),
                        context: 'forget memory'),
                  ),
                ),
              )),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'project-memory',
        tooltip: 'Remember something',
        onPressed: () => _add(context),
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ---- Settings -------------------------------------------------------------------------
class _SettingsTab extends StatefulWidget {
  final Project project;
  const _SettingsTab({required this.project});

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  late final TextEditingController _gates = TextEditingController(text: widget.project.gates);

  @override
  void dispose() {
    _gates.dispose();
    super.dispose();
  }

  Future<void> _ask(Future<String?> Function() job, String title) async {
    final reply = await job();
    if (!mounted || reply == null) return;
    showHermesReply(context, title, reply);
  }

  Future<void> _unlink() async {
    final p = widget.project;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Unlink ${p.name}?'),
        content: const Text('Mercury stops tracking it. The repo, its agent and its memory stay as they are.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Unlink')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final state = context.read<AppState>();
    final reply = await state.unlinkProject(p.id);
    if (reply != null && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.project;
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final pending = state.intentPending('set:${p.id}');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Coder', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text('Who writes the code. Hermes orchestrates, and codes itself only if this one is unavailable.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'claude', label: Text('Claude Code')),
            ButtonSegment(value: 'agy', label: Text('Antigravity')),
          ],
          selected: {p.coder == 'agy' ? 'agy' : 'claude'},
          onSelectionChanged: pending
              ? null
              : (s) => _ask(() => state.setProject(p.id, coder: s.first), 'Coder'),
        ),
        const SizedBox(height: 24),
        Text('Before it reaches GitHub', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text('Who opens the PR. Either way the coder\'s work is committed on a branch '
            'first; test-first just holds it there until you have installed the build.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'auto', label: Text('Auto'), icon: Icon(Icons.bolt_outlined)),
            ButtonSegment(value: 'test-first', label: Text('Test first'), icon: Icon(Icons.science_outlined)),
          ],
          selected: {p.testsFirst ? 'test-first' : 'auto'},
          onSelectionChanged: pending
              ? null
              : (s) => _ask(
                  () => state.setProject(p.id, pushPolicy: s.first),
                  s.first == 'test-first' ? 'Test first' : 'Auto'),
        ),
        const SizedBox(height: 24),
        Text('Gates', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text('The checks every change must pass before its PR opens.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        TextField(
          controller: _gates,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'e.g. ./gradlew test'),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: pending
                ? null
                : () => _ask(() => state.setProject(p.id, gates: _gates.text.trim()), 'Gates'),
            child: Text(pending ? 'Asking Hermes…' : 'Save gates'),
          ),
        ),
        const Divider(height: 32),
        _row(context, 'Repository', p.repo),
        _row(context, 'Agent profile', p.profile),
        _row(context, 'Default branch', p.defaultBranch),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: state.intentPending('unlink:${p.id}') ? null : _unlink,
          icon: Icon(Icons.link_off, color: scheme.error),
          label: Text('Unlink project', style: TextStyle(color: scheme.error)),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          SizedBox(width: 130, child: Text(k, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
          Expanded(child: SelectableText(v)),
        ]),
      );
}
