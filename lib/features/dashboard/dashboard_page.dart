import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/util/format.dart';
import '../../data/models.dart';
import '../../data/project_models.dart';
import '../projects/project_widgets.dart';
import '../../state/app_state.dart';

/// Dashboard: live server status cards, model health, and log viewer.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  @override
  void initState() {
    super.initState();
    // Defer to after the first frame so notifyListeners doesn't fire during build.
    final state = context.read<AppState>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      state.loadStatus();
      state.loadModels();
      state.loadLogs();
      state.loadAgents();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final status = state.status;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Status',
            style: TextStyle(fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            onPressed: () => context.read<AppState>().loadAll(),
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh all',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (status == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            _StatusBanner(scheme: scheme, status: status),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: _Gauge(scheme: scheme, label: 'CPU', value: status.cpu, icon: Icons.memory)),
              const SizedBox(width: 12),
              Expanded(child: _Gauge(scheme: scheme, label: 'RAM', value: status.memory, icon: Icons.sd_storage)),
              const SizedBox(width: 12),
              Expanded(child: _Gauge(scheme: scheme, label: 'Disk', value: status.disk, icon: Icons.storage)),
            ]),
            const SizedBox(height: 20),
            _AgentsCard(snapshot: state.agents),
            const SizedBox(height: 20),
            Text('Model providers',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...state.models.map((m) => Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: m.online ? Colors.green.shade100 : scheme.errorContainer,
                      child: Icon(
                          m.online ? Icons.check : Icons.error_outline,
                          color: m.online ? Colors.green : scheme.error),
                    ),
                    title: Text('${m.provider} · ${m.model}'),
                    subtitle: Text(m.quotaStatus ?? (m.online ? 'Online' : 'Offline')),
                  ),
                )),
            const SizedBox(height: 20),
            Row(
              children: [
                Text('Recent logs',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh logs',
                  onPressed: () => context.read<AppState>().loadLogs(),
                ),
              ],
            ),
            ...state.logs.take(15).map((l) => Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    dense: true,
                    leading: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _logColor(l.level, scheme),
                      ),
                    ),
                    title: Text(l.message,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        '${l.source} · ${formatRelativeTime(l.timestamp)} · ${l.level}',
                        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                  ),
                )),
          ],
        ],
      ),
    );
  }

  Color _logColor(String level, ColorScheme scheme) {
    switch (level) {
      case 'ERROR':
        return scheme.error;
      case 'WARN':
        return scheme.tertiary;
      default:
        return scheme.primary;
    }
  }
}

class _StatusBanner extends StatelessWidget {
  final ColorScheme scheme;
  final ServerStatus status;
  const _StatusBanner({required this.scheme, required this.status});

  @override
  Widget build(BuildContext context) {
    final up = status.gatewayUp;
    return Card(
      color: up ? scheme.primaryContainer : scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(up ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                size: 40, color: up ? scheme.onPrimaryContainer : scheme.onErrorContainer),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(up ? 'Gateway online' : 'Gateway offline',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: up ? scheme.onPrimaryContainer : scheme.onErrorContainer)),
                  Text(
                    'Hermes v${status.version} · uptime ${status.uptime}\n${status.activeSessions} active sessions · ${formatRelativeTime(status.fetchedAt, now: DateTime.now())}',
                    style: TextStyle(
                        color: up ? scheme.onPrimaryContainer : scheme.onErrorContainer),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Gauge extends StatelessWidget {
  final ColorScheme scheme;
  final String label;
  final double value;
  final IconData icon;
  const _Gauge({
    required this.scheme,
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final color = value > 85
        ? scheme.error
        : value > 65
            ? scheme.tertiary
            : scheme.primary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 8),
            Text('${value.round()}%',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(color: color)),
            const SizedBox(height: 4),
            Text(label,
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: value / 100,
                minHeight: 6,
                color: color,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ],
        ),
      ),
    );
  }
}


/// Hermes' agent processes and free memory, plus the kill switch. Hermes caps
/// coding runs itself and stops the newest one if RAM runs low; "Pause all"
/// asks it to stop dispatching work and taking new turns.
class _AgentsCard extends StatelessWidget {
  final AgentSnapshot? snapshot;
  const _AgentsCard({required this.snapshot});

  static String _kind(String k) => switch (k) {
        'gateway' => 'Hermes',
        'worker' => 'Worker',
        'coder' => 'Coder',
        'code_task' => 'Coding run',
        'bridge' => 'Bridge',
        'interactive' => 'Interactive',
        _ => k,
      };

  Future<void> _ask(BuildContext context, Future<String?> Function() job, String title) async {
    final reply = await job();
    if (reply != null && context.mounted) showHermesReply(context, title, reply);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final snap = snapshot;
    final busy = state.intentPending('pause') || state.intentPending('resume');
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Agents', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            if (snap != null)
              Text('${(snap.memAvailableMb / 1024).toStringAsFixed(1)} GB free',
                  style: TextStyle(color: snap.memAvailableMb < 1536 ? scheme.error : scheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: 6),
          if (snap == null)
            Text('Not available', style: TextStyle(color: scheme.outline))
          else
            ...snap.processes.where((p) => p.kind != 'interactive').map((p) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    SizedBox(width: 92, child: Text(_kind(p.kind), style: const TextStyle(fontWeight: FontWeight.w600))),
                    Expanded(
                        child: Text(p.profile ?? '', overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: scheme.onSurfaceVariant))),
                    Text('${p.rssMb} MB', style: TextStyle(color: scheme.onSurfaceVariant)),
                  ]),
                )),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton.icon(
              onPressed: busy ? null : () => _ask(context, state.resumeAll, 'Resume'),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Resume'),
            ),
            FilledButton.tonalIcon(
              onPressed: busy ? null : () => _ask(context, state.pauseAll, 'Pause all'),
              icon: const Icon(Icons.pause_rounded),
              label: const Text('Pause all'),
            ),
          ]),
        ]),
      ),
    );
  }
}
