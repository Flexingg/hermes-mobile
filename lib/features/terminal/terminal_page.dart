import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';

/// Manual command runner against the host PC (via the bridge's terminal
/// endpoint). Token-gated on the server; requires a live connection.
class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key});

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TermEntry {
  final String command;
  String output = '';
  int exitCode = 0;
  bool running = false;
  int durationMs = 0;
  _TermEntry(this.command);
}

class _TerminalPageState extends State<TerminalPage> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final List<_TermEntry> _entries = [];
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _run(String raw) async {
    final command = raw.trim();
    if (command.isEmpty) return;
    setState(() {
      _entries.add(_TermEntry(command)..running = true);
      _busy = true;
    });
    _scrollToBottom();
    try {
      final state = context.read<AppState>();
      final r = await state.repo.runCommand(command);
      if (!mounted) return;
      setState(() {
        _applyResult(r);
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        final last = _runningEntry();
        if (last != null) {
          last.output = 'ERROR: $e';
          last.exitCode = -1;
          last.running = false;
        }
        _busy = false;
      });
    }
    _scrollToBottom();
  }

  _TermEntry? _runningEntry() {
    for (final e in _entries.reversed) {
      if (e.running) return e;
    }
    return null;
  }

  void _applyResult(TerminalResult r) {
    final last = _runningEntry();
    if (last == null) return;
    last.output = r.combined.trim().isEmpty ? '(no output)' : r.combined.trimRight();
    last.exitCode = r.exitCode;
    last.durationMs = r.durationMs;
    last.running = false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Host Terminal')),
      body: Column(
        children: [
          Expanded(
            child: _entries.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.terminal_rounded,
                            size: 56, color: scheme.primary.withValues(alpha: 0.5)),
                        const SizedBox(height: 12),
                        const Text('Run commands on hermes-pc',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text('Type a command below — output returns here.',
                            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    itemCount: _entries.length,
                    itemBuilder: (context, i) => _TermEntryView(entry: _entries[i]),
                  ),
          ),
          _inputBar(scheme),
        ],
      ),
    );
  }

  Widget _inputBar(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              icon: const Icon(Icons.clear_all_rounded),
              tooltip: 'Clear',
              onPressed: () => setState(_entries.clear),
            ),
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                autofocus: true,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                decoration: const InputDecoration(
                  hintText: r'$ e.g. df -h  |  systemctl --user status hermes-bridge',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                onSubmitted: (v) {
                  _run(v);
                  _controller.clear();
                },
              ),
            ),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: IconButton.filled(
                icon: _busy
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.play_arrow_rounded),
                tooltip: 'Run',
                onPressed: _busy ? null : () {
                  final v = _controller.text;
                  _run(v);
                  _controller.clear();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TermEntryView extends StatelessWidget {
  final _TermEntry entry;
  const _TermEntryView({required this.entry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ok = entry.exitCode == 0;
    final statusColor = entry.running
        ? scheme.primary
        : (ok ? Colors.green.shade700 : scheme.error);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('\$', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  entry.command,
                  style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              if (entry.running)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              else
                Text(
                  entry.exitCode == 0 ? 'exit 0' : 'exit ${entry.exitCode}',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: statusColor),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(
              entry.output.isEmpty ? (entry.running ? 'Running…' : '') : entry.output,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: entry.running ? scheme.onSurfaceVariant : scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
