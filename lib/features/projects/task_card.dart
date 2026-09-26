import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/apk_installer.dart';
import '../../core/util/format.dart';
import '../../data/project_models.dart';
import '../../state/app_state.dart';
import 'project_widgets.dart';
import 'task_detail_page.dart';

/// One issue's way through the pipeline: issue -> task -> PR -> CI -> test build.
class TaskCard extends StatefulWidget {
  final Project project;
  final ProjectTask task;
  const TaskCard({super.key, required this.project, required this.task});

  @override
  State<TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<TaskCard> {
  bool _downloading = false;

  Future<void> _open(String? url) async {
    if (url == null) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<void> _installApk() async {
    final apk = widget.task.apk;
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

  @override
  Widget build(BuildContext context) {
    final t = widget.task;
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final pending = state.intentPending('task:${t.id}');
    final finished = t.phase.isFinished;
    final meta = [
      if (t.issue != null) 'Issue #${t.issue}',
      if (t.prNumber != null) 'PR #${t.prNumber}',
      coderName(t.coder),
      if (t.mergedAt != null)
        'merged ${formatRelativeTime(t.mergedAt!)}'
      else if (t.updatedAt != null)
        formatRelativeTime(t.updatedAt!),
    ];
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // Open the task: everything about it, and the three things you can do
        // with it (suggest edits, follow-up issue, talk to the agent).
        key: Key('open-${t.id}'),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => TaskDetailPage(project: widget.project, task: t))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Text(t.title,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              TaskPhaseChip(t.phase, dense: true),
              Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
            ]),
            const SizedBox(height: 4),
            Text(meta.join(' · '), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            if (t.ci != null && t.prNumber != null && !finished) ...[
              const SizedBox(height: 6),
              _CiLine(ci: t.ci!, failing: t.failingChecks),
            ],
            if (t.phase == TaskPhase.needsYou && (t.blockedReason ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: scheme.errorContainer.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(12)),
                child: Text(t.blockedReason!, style: TextStyle(fontSize: 13, color: scheme.onErrorContainer)),
              ),
            ],
            const SizedBox(height: 4),
            Wrap(spacing: 4, children: [
              if (t.apk != null && !finished)
                FilledButton.icon(
                  key: Key('install-${t.id}'),
                  onPressed: _downloading ? null : _installApk,
                  icon: _downloading
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.install_mobile, size: 18),
                  label: Text(_downloading ? 'Downloading…' : 'Install test build'),
                ),
              if (t.prUrl != null)
                TextButton.icon(
                    onPressed: () => _open(t.prUrl),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Open PR')),
              if (t.prUrl == null && t.issueUrl != null)
                TextButton.icon(
                    onPressed: () => _open(t.issueUrl),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Issue')),
              if (t.canRetry)
                TextButton.icon(
                    onPressed: pending
                        ? null
                        : () => _ask(() => state.retryTask(widget.project.id, t.id), 'Retry'),
                    icon: const Icon(Icons.replay, size: 18),
                    label: Text(pending ? 'Asking Hermes…' : 'Retry')),
              if (t.canCancel)
                TextButton.icon(
                    onPressed: pending
                        ? null
                        : () => _ask(() => state.cancelTask(widget.project.id, t.id), 'Cancel'),
                    icon: const Icon(Icons.close, size: 18),
                    label: Text(pending ? 'Asking Hermes…' : 'Cancel')),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _CiLine extends StatelessWidget {
  final String ci;
  final List<String> failing;
  const _CiLine({required this.ci, required this.failing});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, text) = switch (ci) {
      'green' => (Icons.check_circle, const Color(0xFF2E7D32), 'CI passed'),
      'none' => (Icons.remove_circle_outline, scheme.outline, 'No CI on this repo'),
      'red' => (Icons.cancel, scheme.error, 'CI failed: ${failing.join(', ')}'),
      _ => (Icons.pending_outlined, scheme.tertiary, 'CI running'),
    };
    return Row(children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 6),
      Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: color))),
    ]);
  }
}
