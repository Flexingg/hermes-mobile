import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../state/app_state.dart';
import 'servers_page.dart';

/// App settings: appearance (Material You), data mode, servers, about.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final config = context.watch<AppConfig>();
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings',
            style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Appearance', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.palette_outlined),
                  title: const Text('Material You dynamic color'),
                  subtitle: const Text('Theme follows your wallpaper'),
                  value: config.dynamicColor,
                  onChanged: (v) async {
                    await config.setDynamicColor(v);
                    if (v) await config.setSeedColor(null);
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.brightness_6_outlined),
                  title: const Text('Theme mode'),
                  trailing: SegmentedButton<ThemePreference>(
                    segments: const [
                      ButtonSegment(value: ThemePreference.system, label: Text('Auto')),
                      ButtonSegment(value: ThemePreference.light, icon: Icon(Icons.light_mode_outlined)),
                      ButtonSegment(value: ThemePreference.dark, icon: Icon(Icons.dark_mode_outlined)),
                    ],
                    selected: {config.themePreference},
                    onSelectionChanged: (s) =>
                        config.setThemePreference(s.first),
                  ),
                ),
              ],
            ),
          ),
          if (config.seedColor != null) ...[
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: Icon(Icons.color_lens_outlined,
                    color: config.seedColor),
                title: const Text('Custom accent active'),
                subtitle: Text(
                    '#${config.seedColor!.toARGB32().toRadixString(16).padLeft(8, '0')}'),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => config.setSeedColor(null),
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          Text('Connection', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('Servers & profiles'),
                  subtitle: Text('${state.servers.length} connected · '
                      '${state.servers.expand((s) => s.bots).length} agents'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ServersPage()),
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.science_outlined),
                  title: const Text('Demo mode'),
                  subtitle: const Text('Use built-in sample data (no server)'),
                  value: config.demoMode,
                  onChanged: (v) async {
                    await config.setDemoMode(v);
                    // State re-creates its repository on next launch.
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text('Security', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.lock_outline),
                  title: const Text('Biometric vault'),
                  subtitle: const Text(
                      'Lock the app with your fingerprint / face / PIN on launch'),
                  value: config.vaultEnabled,
                  onChanged: (v) async {
                    await config.setVaultEnabled(v);
                    if (!context.mounted) return;
                    if (v) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text(
                                'Vault enabled — app will lock on next launch.')),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text('About', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: Icon(Icons.smart_toy_outlined, color: scheme.primary),
              title: const Text('Hermes Mobile'),
              subtitle: const Text('Material You controller for Hermes Agent\nv1.0.0 · Android-optimized'),
              isThreeLine: true,
            ),
          ),
        ],
      ),
    );
  }
}
