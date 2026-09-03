import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/network/bridge_discovery.dart';
import '../../state/app_state.dart';

/// Full-screen onboarding: link the app to a real Hermes bridge server.
/// No data is shown until a connection is verified.
class ConnectServerPage extends StatefulWidget {
  const ConnectServerPage({super.key});

  @override
  State<ConnectServerPage> createState() => _ConnectServerPageState();
}

class _ConnectServerPageState extends State<ConnectServerPage> {
  final _name = TextEditingController(text: 'Hermes PC');
  final _url = TextEditingController(text: 'http://100.67.34.4:9130');
  final _token = TextEditingController();

  bool _scanning = false;
  List<DiscoveredBridge> _found = const [];

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _found = const [];
    });
    final results = await BridgeDiscovery.discover(timeout: const Duration(seconds: 4));
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _found = results;
    });
    if (results.isEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No Mercury bridges found on this network. '
                'Check the bridge host is on the same Wi-Fi and try again.')),
      );
    }
  }

  void _apply(DiscoveredBridge b) {
    _name.text = b.name;
    _url.text = b.baseUrl;
    setState(() {});
  }

  Future<void> _connect() async {
    final state = context.read<AppState>();
    final name = _name.text.trim();
    final url = _url.text.trim().replaceAll(RegExp(r'/+$'), '');
    final token = _token.text.trim();
    if (url.isEmpty) return;
    await state.connect(name: name, baseUrl: url, token: token);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(22),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.dns_outlined,
                        size: 44, color: scheme.onPrimaryContainer),
                  ),
                  const SizedBox(height: 20),
                  Text('Connect to Hermes',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(
                    'Link this app to your Hermes bridge server to load your real sessions, controller, and dashboard. No data is shown until the connection is verified.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: 'Server name',
                      prefixIcon: Icon(Icons.label_outline),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Server URL',
                      hintText: 'http://192.168.1.146:PORT',
                      prefixIcon: Icon(Icons.link),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _token,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'API token',
                      hintText: 'Leave blank if the bridge requires none',
                      prefixIcon: Icon(Icons.key_outlined),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Divider(height: 1, color: scheme.outlineVariant),
                  const SizedBox(height: 16),
                  Text('Found it automatically?',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  Text(
                    'Bridges advertise on your local network. Tap one to fill the '
                    'server name and URL above.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: state.busy || _scanning ? null : _scan,
                    icon: _scanning
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.wifi_tethering),
                    label: Text(_scanning ? 'Searching…' : 'Search your network'),
                  ),
                  if (_found.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ..._found.map(
                      (b) => Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.dns_outlined,
                              color: scheme.primary),
                          title: Text(b.name),
                          subtitle: Text(b.baseUrl,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _apply(b),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (state.error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline, color: scheme.onErrorContainer),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Connection failed: ${state.error}',
                              style: TextStyle(color: scheme.onErrorContainer),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  FilledButton.icon(
                    onPressed: state.busy ? null : _connect,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    icon: state.busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.link),
                    label: Text(state.busy ? 'Connecting…' : 'Connect & verify'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
