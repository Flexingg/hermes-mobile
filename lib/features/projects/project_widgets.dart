import 'package:flutter/material.dart';
import '../../data/project_models.dart';

/// One visual language for where work stands, used on every project screen.
({IconData icon, Color bg, Color fg}) _tone(ColorScheme s, String key) => switch (key) {
      'needs_you' => (icon: Icons.priority_high_rounded, bg: s.errorContainer, fg: s.onErrorContainer),
      'ready' => (icon: Icons.task_alt_rounded, bg: s.primaryContainer, fg: s.onPrimaryContainer),
      'working' => (icon: Icons.autorenew_rounded, bg: s.tertiaryContainer, fg: s.onTertiaryContainer),
      'review' => (icon: Icons.rate_review_outlined, bg: s.tertiaryContainer, fg: s.onTertiaryContainer),
      'ci_retry' => (icon: Icons.build_circle_outlined, bg: s.tertiaryContainer, fg: s.onTertiaryContainer),
      'queued' => (icon: Icons.schedule_rounded, bg: s.secondaryContainer, fg: s.onSecondaryContainer),
      'merged' => (icon: Icons.merge_rounded, bg: s.surfaceContainerHighest, fg: s.onSurfaceVariant),
      _ => (icon: Icons.circle_outlined, bg: s.surfaceContainerHighest, fg: s.onSurfaceVariant),
    };

String _statusKey(ProjectStatus st) => switch (st) {
      ProjectStatus.needsYou => 'needs_you',
      ProjectStatus.ready => 'ready',
      ProjectStatus.working => 'working',
      ProjectStatus.queued => 'queued',
      ProjectStatus.idle => 'idle',
    };

String _phaseKey(TaskPhase p) => switch (p) {
      TaskPhase.needsYou => 'needs_you',
      TaskPhase.ready => 'ready',
      TaskPhase.working => 'working',
      TaskPhase.review => 'review',
      TaskPhase.ciRetry => 'ci_retry',
      TaskPhase.queued => 'queued',
      TaskPhase.merged => 'merged',
      _ => 'idle',
    };

class _Pill extends StatelessWidget {
  final String toneKey;
  final String label;
  final bool dense;
  const _Pill({required this.toneKey, required this.label, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final t = _tone(Theme.of(context).colorScheme, toneKey);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 3 : 5),
      decoration: BoxDecoration(color: t.bg, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(t.icon, size: dense ? 13 : 15, color: t.fg),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(fontSize: dense ? 11 : 12, fontWeight: FontWeight.w600, color: t.fg)),
      ]),
    );
  }
}

class ProjectStatusChip extends StatelessWidget {
  final ProjectStatus status;
  final bool dense;
  const ProjectStatusChip(this.status, {super.key, this.dense = false});

  @override
  Widget build(BuildContext context) =>
      _Pill(toneKey: _statusKey(status), label: status.label, dense: dense);
}

class TaskPhaseChip extends StatelessWidget {
  final TaskPhase phase;
  final bool dense;
  const TaskPhaseChip(this.phase, {super.key, this.dense = false});

  @override
  Widget build(BuildContext context) =>
      _Pill(toneKey: _phaseKey(phase), label: phase.label, dense: dense);
}

/// Green when the project's agent is doing something, grey when it's asleep.
class AwakeDot extends StatelessWidget {
  final bool awake;
  const AwakeDot(this.awake, {super.key});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Tooltip(
      message: awake ? 'Agent working' : 'Agent asleep',
      child: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: awake ? const Color(0xFF2E7D32) : s.outlineVariant,
        ),
      ),
    );
  }
}

/// A rounded project monogram in the project's colour.
class ProjectAvatar extends StatelessWidget {
  final Project project;
  final double size;
  const ProjectAvatar(this.project, {super.key, this.size = 44});

  @override
  Widget build(BuildContext context) {
    final letter = project.name.isEmpty ? '?' : project.name.characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: project.color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Text(letter,
          style: TextStyle(
              fontSize: size * 0.42, fontWeight: FontWeight.w700, color: project.color)),
    );
  }
}

/// Shows a reply from Hermes (the result of asking it to do something).
void showHermesReply(BuildContext context, String title, String reply) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Text('🧠', style: TextStyle(fontSize: 28)),
      title: Text(title),
      content: SingleChildScrollView(child: SelectableText(reply)),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
    ),
  );
}
