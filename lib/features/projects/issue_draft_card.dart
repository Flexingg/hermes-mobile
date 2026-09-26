import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/project_models.dart';
import '../../state/app_state.dart';

/// The issue a Plan chat produced, editable before it's filed. "Create issue"
/// asks the project agent (which drafted it) to file it; Hermes then queues it
/// and the coder builds it in the background.
class IssueDraftCard extends StatefulWidget {
  final Project project;
  final String sessionId;
  final String messageId;
  final IssueDraft draft;
  const IssueDraftCard({
    super.key,
    required this.project,
    required this.sessionId,
    required this.messageId,
    required this.draft,
  });

  @override
  State<IssueDraftCard> createState() => _IssueDraftCardState();
}

class _IssueDraftCardState extends State<IssueDraftCard> {
  late IssueDraft _draft = widget.draft;
  bool _expanded = false;

  @override
  void didUpdateWidget(IssueDraftCard old) {
    super.didUpdateWidget(old);
    if (old.draft.title != widget.draft.title || old.draft.body != widget.draft.body) {
      _draft = widget.draft;
    }
  }

  Future<void> _edit() async {
    final title = TextEditingController(text: _draft.title);
    final body = TextEditingController(text: _draft.body);
    final criteria = TextEditingController(text: _draft.acceptance.join('\n'));
    final saved = await showDialog<IssueDraft>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit issue'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
            const SizedBox(height: 8),
            TextField(
                controller: body,
                minLines: 4,
                maxLines: 12,
                decoration: const InputDecoration(labelText: 'Description', alignLabelWithHint: true)),
            const SizedBox(height: 8),
            TextField(
                controller: criteria,
                minLines: 2,
                maxLines: 8,
                decoration: const InputDecoration(
                    labelText: 'Acceptance criteria (one per line)', alignLabelWithHint: true)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(
                ctx,
                _draft.copyWith(
                  title: title.text.trim().isEmpty ? _draft.title : title.text.trim(),
                  body: body.text,
                  acceptance: criteria.text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList(),
                )),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != null) setState(() => _draft = saved);
  }

  Future<void> _create() async {
    final state = context.read<AppState>();
    await state.fileIssue(widget.project, widget.sessionId, widget.messageId, _draft);
    await state.loadProject(widget.project.id);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final filed = state.filedDraftReply(widget.messageId);
    final filing = state.intentPending('file:${widget.messageId}');
    return Card(
      key: Key('draft-${widget.messageId}'),
      margin: const EdgeInsets.fromLTRB(44, 4, 8, 8),
      elevation: 0,
      color: scheme.tertiaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.assignment_outlined, size: 18, color: scheme.onTertiaryContainer),
            const SizedBox(width: 6),
            Text('Issue draft · ${widget.project.name}',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onTertiaryContainer)),
          ]),
          const SizedBox(height: 8),
          Text(_draft.title,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: scheme.onTertiaryContainer)),
          if (_draft.body.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Text(_draft.body.trim(),
                  maxLines: _expanded ? null : 4,
                  overflow: _expanded ? null : TextOverflow.fade,
                  style: TextStyle(fontSize: 13, color: scheme.onTertiaryContainer.withValues(alpha: 0.9))),
            ),
          ],
          if (_draft.acceptance.isNotEmpty) ...[
            const SizedBox(height: 8),
            ..._draft.acceptance.map((c) => Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.check_box_outline_blank, size: 16, color: scheme.onTertiaryContainer),
                    const SizedBox(width: 6),
                    Expanded(child: Text(c, style: TextStyle(fontSize: 13, color: scheme.onTertiaryContainer))),
                  ]),
                )),
          ],
          const SizedBox(height: 6),
          if (filed != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: scheme.surface.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(12)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.check_circle, size: 18, color: Color(0xFF2E7D32)),
                const SizedBox(width: 8),
                Expanded(child: Text(filed, style: const TextStyle(fontSize: 13))),
              ]),
            )
          else
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: filing ? null : _edit, child: const Text('Edit')),
              const SizedBox(width: 4),
              FilledButton.icon(
                key: const Key('create-issue'),
                onPressed: filing ? null : _create,
                icon: filing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send_rounded, size: 18),
                label: Text(filing ? 'Filing…' : 'Create issue'),
              ),
            ]),
        ]),
      ),
    );
  }
}
