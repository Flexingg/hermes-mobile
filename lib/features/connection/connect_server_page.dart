import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/network/bridge_discovery.dart';
import '../../data/models.dart';
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
  final _accessId = TextEditingController();
  final _accessSecret = TextEditingController();

  ConnectionKind _kind = ConnectionKind.tailscale;
  String? _urlError;
  bool _scanning = false;
  bool _tunnelBusy = false;
  String? _tunnelNote;
  List<DiscoveredBridge> _found = const [];

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    _accessId.dispose();
    _accessSecret.dispose();
    super.dispose();
  }

  /// Switching how you reach the server: keep an edited URL, replace a URL that
  /// was only another kind's example, and re-validate what's there.
  void _pick(ConnectionKind kind) {
    final current = _url.text.trim();
    final wasExample = ConnectionKind.values.any((k) => k.example == current) || current.isEmpty;
    setState(() {
      _kind = kind;
      if (wasExample) _url.text = kind.example;
      _urlError = null;
      _tunnelNote = null;
    });
  }

  /// Ask the server (over the connection we already have) which tunnel it has
  /// open, and use that URL. Only useful once the app has reached it somehow.
  Future<void> _fetchTunnel() async {
    final state = context.read<AppState>();
    setState(() {
      _tunnelBusy = true;
      _tunnelNote = null;
    });
    final t = await state.tunnel();
    if (!mounted) return;
    setState(() {
      _tunnelBusy = false;
      if (t != null && t.up && (t.url ?? '').isNotEmpty) {
        _url.text = t.url!;
        _urlError = null;
        _tunnelNote = t.accessProtected == true
            ? 'Found the server’s tunnel (behind Cloudflare Access).'
            : 'Found the server’s tunnel. It is not behind Cloudflare Access — the '
                'API token is the only gate.';
      } else {
        _tunnelNote = 'The server has no tunnel open. Ask Hermes to start one: '
            '“start the tunnel” in the Hermes chat.';
      }
    });
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
    final invalid = _kind.validate(url);
    if (invalid != null) {
      setState(() => _urlError = invalid);
      return;
    }
    setState(() => _urlError = null);
    await state.connect(
      name: name,
      baseUrl: url,
      token: token,
      kind: _kind,
      accessClientId: _accessId.text.trim(),
      accessClientSecret: _accessSecret.text.trim(),
    );
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

                  // How you reach the server. This only changes the URL you need
                  // and the guidance: LAN and Tailscale are direct, a tunnel goes
                  // out through Cloudflare.
                  Text('How do you reach it?',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SegmentedButton<ConnectionKind>(
                    key: const Key('connection-kind'),
                    segments: [
                      for (final k in ConnectionKind.values)
                        ButtonSegment(
                          value: k,
                          label: Text(k.label, style: const TextStyle(fontSize: 12)),
                          icon: Icon(switch (k) {
                            ConnectionKind.lan => Icons.wifi,
                            ConnectionKind.tailscale => Icons.vpn_lock_outlined,
                            ConnectionKind.tunnel => Icons.cloud_outlined,
                          }, size: 16),
                        ),
                    ],
                    selected: {_kind},
                    showSelectedIcon: false,
                    onSelectionChanged: state.busy ? null : (s) => _pick(s.first),
                  ),
                  const SizedBox(height: 6),
                  Text(_kind.hint,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  if (_kind == ConnectionKind.tunnel) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      key: const Key('fetch-tunnel'),
                      onPressed: state.busy || _tunnelBusy ? null : _fetchTunnel,
                      icon: _tunnelBusy
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.download_outlined),
                      label: const Text('Use the tunnel my server has open'),
                    ),
                    if (_tunnelNote != null) ...[
                      const SizedBox(height: 6),
                      Text(_tunnelNote!,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ],
                  const SizedBox(height: 16),
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
                    onChanged: (_) {
                      if (_urlError != null) setState(() => _urlError = null);
                    },
                    decoration: InputDecoration(
                      labelText: 'Server URL',
                      hintText: _kind.example,
                      prefixIcon: const Icon(Icons.link),
                      errorText: _urlError,
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
                  if (_kind == ConnectionKind.tunnel) ...[
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('access-client-id'),
                      controller: _accessId,
                      decoration: const InputDecoration(
                        labelText: 'Cloudflare Access client ID (optional)',
                        hintText: 'Only if the tunnel is behind an Access policy',
                        prefixIcon: Icon(Icons.shield_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('access-client-secret'),
                      controller: _accessSecret,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Access client secret',
                        prefixIcon: Icon(Icons.password_outlined),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (_kind == ConnectionKind.lan) ...[
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
                    key: const Key('connect-button'),
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
