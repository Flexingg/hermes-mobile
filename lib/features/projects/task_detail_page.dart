import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/apk_installer.dart';
import '../../core/util/format.dart';
import '../../data/project_models.dart';
import '../../state/app_state.dart';
import '../chat/chat_thread_page.dart';
import 'project_widgets.dart';

/// One task, opened by tapping its card: what it is, where it got to, and the
/// three things you can do about it — talk to the project agent about it, suggest
/// an edit (Hermes decides whether that reopens the work or files a follow-up),
/// or file a follow-up issue outright.
class TaskDetailPage extends StatefulWidget {
  final Project project;
  final ProjectTask task;
  const TaskDetailPage({super.key, required this.project, required this.task});

  @override
  State<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends State<TaskDetailPage> {
  final _edit = TextEditingController();
  final _followup = TextEditingController();
  bool _downloading = false;

  /// The task as the project detail last reported it, so the page reflects a
  /// reload (phase, PR, merged) without closing. Reads — never watches — so it is
  /// safe to call from a button handler; [build] watches the state itself.
  ProjectTask get task => _lookup(context.read<AppState>());

  ProjectTask _lookup(AppState state) =>
      state.projectDetail(widget.project.id)?.tasks.firstWhere(
        (t) => t.id == widget.task.id,
        orElse: () => widget.task,
      ) ??
      widget.task;

  @override
  void dispose() {
    _edit.dispose();
    _followup.dispose();
    super.dispose();
  }

  Future<void> _open(String? url) async {
    if (url == null) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<void> _installApk() async {
    final apk = task.apk;
    if (apk == null) return;
    final state = context.read<AppState>();
    setState(() => _downloading = true);
    try {
      final local = await state.repo.downloadFile(apk);
      await ApkInstaller.install(local);
    } catch (e) {
      state.reportError(e, context: 'install test build');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _ask(Future<String?> Function() job, String title) async {
    final reply = await job();
    if (!mounted || reply == null) return;
    showHermesReply(context, title, reply);
  }

  /// Suggest an edit: the note goes to Hermes, which either puts the task back on
  /// its worker (open PR) or starts a follow-up (merged PR).
  Future<void> _suggest() async {
    final note = _edit.text.trim();
    if (note.isEmpty) return;
    final project = widget.project;
    final t = task;
    await _ask(() => context.read<AppState>().suggestEdit(project.id, t, note), 'Suggestion sent');
    if (mounted) _edit.clear();
  }

  /// A follow-up issue, scoped by the project agent.
  Future<void> _fileFollowUp() async {
    final note = _followup.text.trim();
    if (note.isEmpty) return;
    final project = widget.project;
    final t = task;
    await _ask(() => context.read<AppState>().followupIssue(project.id, t, note), 'Follow-up issue');
    if (mounted) _followup.clear();
  }

  /// The project chat, with the issue/PR already in the composer.
  Future<void> _openChat() async {
    final state = context.read<AppState>();
    final project = widget.project;
    final t = task;
    final chats = state.projectSessionsFor(project.id);
    final sid = chats.isNotEmpty
        ? chats.first.id
        : await state.createProjectChat(project, project.name);
    if (sid == null || !mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ChatThreadPage(
              sessionId: sid,
              name: project.name,
              project: project,
              draftText: _context(t, project),
            )));
  }

  /// What the agent needs to know to act on a message about this task.
  String _context(ProjectTask t, Project project) {
    final bits = [
      if (t.issue != null) '${project.repo}#${t.issue}',
      if (t.prNumber != null) 'PR #${t.prNumber}',
      'task ${t.id}',
      t.phase.label.toLowerCase(),
    ];
    return 'About ${bits.join(' · ')}: ';
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final t = _lookup(state);
    final editing = state.intentPending('edit:${t.id}');
    final following = state.intentPending('followup:${t.id}');

    return Scaffold(
      appBar: AppBar(title: const Text('Task')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text(t.title,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
            TaskPhaseChip(t.phase),
          ]),
          const SizedBox(height: 8),
          Text(widget.project.name, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),

          // Where it got to.
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _row(scheme, 'Issue', t.issue == null ? '—' : '#${t.issue}',
                    onTap: t.issueUrl == null ? null : () => _open(t.issueUrl)),
                _row(scheme, 'Pull request', t.prNumber == null ? '—' : '#${t.prNumber}',
                    onTap: t.prUrl == null ? null : () => _open(t.prUrl)),
                if (t.ci != null) _row(scheme, 'CI', _ciLabel(t)),
                _row(scheme, 'Coder', coderName(t.coder)),
                if ((t.branch ?? '').isNotEmpty) _row(scheme, 'Branch', t.branch!),
                if (t.mergedAt != null)
                  _row(scheme, 'Merged', formatRelativeTime(t.mergedAt!)),
                if (t.updatedAt != null) _row(scheme, 'Updated', formatRelativeTime(t.updatedAt!)),
              ]),
            ),
          ),

          if (t.phase == TaskPhase.needsYou && (t.blockedReason ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(14)),
              child: Text(t.blockedReason!,
                  style: TextStyle(fontSize: 13, color: scheme.onErrorContainer)),
            ),
          ],

          const SizedBox(height: 10),
          Wrap(spacing: 6, children: [
            if (t.apk != null)
              FilledButton.icon(
                key: Key('install-${t.id}'),
                onPressed: _downloading ? null : _installApk,
                icon: _downloading
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.install_mobile, size: 18),
                label: Text(_downloading ? 'Downloading…' : 'Install test build'),
              ),
            if (t.prUrl != null)
              OutlinedButton.icon(
                  onPressed: () => _open(t.prUrl),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Open PR')),
            if (t.issueUrl != null && t.prUrl == null)
              OutlinedButton.icon(
                  onPressed: () => _open(t.issueUrl),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Issue')),
            OutlinedButton.icon(
                key: Key('open-chat-${t.id}'),
                onPressed: _openChat,
                icon: const Icon(Icons.forum_outlined, size: 18),
                label: Text('Ask ${widget.project.name}')),
            if (t.canPush)
              FilledButton.icon(
                  key: Key('push-${t.id}'),
                  onPressed: state.intentPending('push:${t.id}')
                      ? null
                      : () => _ask(
                          () => context.read<AppState>().pushTask(widget.project.id, t.id),
                          'Open the PR'),
                  icon: const Icon(Icons.upload, size: 18),
                  label: const Text('Push it')),
            if (t.canRetry)
              OutlinedButton.icon(
                  onPressed: state.intentPending('task:${t.id}')
                      ? null
                      : () => _ask(
                          () => context.read<AppState>().retryTask(widget.project.id, t.id), 'Retry'),
                  icon: const Icon(Icons.replay, size: 18),
                  label: const Text('Retry')),
            if (t.canCancel)
              OutlinedButton.icon(
                  onPressed: state.intentPending('task:${t.id}')
                      ? null
                      : () => _ask(
                          () => context.read<AppState>().cancelTask(widget.project.id, t.id), 'Cancel'),
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('Cancel')),
          ]),

          if (t.canSuggestEdit) ...[
            const SizedBox(height: 18),
            Text('Suggest further edits',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: scheme.onSurface)),
            const SizedBox(height: 4),
            Text(
              t.phase.isFinished
                  ? 'This one is finished, so the answer is a follow-up: Hermes reads what shipped '
                      'and decides how to carry your note forward.'
                  : (t.phase == TaskPhase.ready || t.phase == TaskPhase.review
                      ? 'The PR is still open — Hermes puts your note back on the task and the worker '
                          'updates the same branch.'
                      : 'Hermes adds this to the task and tells you what it did.'),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            TextField(
              key: Key('suggest-${t.id}'),
              controller: _edit,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'e.g. the header should stay visible while scrolling',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: Key('send-suggestion-${t.id}'),
                onPressed: editing ? null : _suggest,
                icon: editing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send_rounded, size: 18),
                label: Text(editing ? 'Sending…' : 'Suggest'),
              ),
            ),
          ],

          if (t.canFileFollowUp) ...[
            const SizedBox(height: 18),
            Text('File a follow-up issue',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: scheme.onSurface)),
            const SizedBox(height: 4),
            Text(
              'The ${widget.project.name} agent scopes it against the code, checks for duplicates, '
              'and files it queued like any other issue.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            TextField(
              key: Key('followup-${t.id}'),
              controller: _followup,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'What should happen instead or next?',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: Key('send-followup-${t.id}'),
                onPressed: following ? null : _fileFollowUp,
                icon: following
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.add_task, size: 18),
                label: Text(following ? 'Filing…' : 'File issue'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _ciLabel(ProjectTask t) => switch (t.ci) {
        'green' => 'passed',
        'none' => 'no CI on this repo',
        'red' => 'failed: ${t.failingChecks.join(', ')}',
        _ => 'running',
      };

  Widget _row(ColorScheme scheme, String label, String value, {VoidCallback? onTap}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(
            width: 108,
            child: Text(label, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: GestureDetector(
              onTap: onTap,
              child: Text(value,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: onTap == null ? scheme.onSurface : scheme.primary)),
            ),
          ),
          if (onTap != null) Icon(Icons.chevron_right, size: 16, color: scheme.onSurfaceVariant),
        ]),
      );
}
