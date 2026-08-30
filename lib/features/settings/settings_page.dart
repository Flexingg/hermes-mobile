import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/config/app_config.dart';
import '../../core/notifications/notifications.dart';
import '../../core/theme/app_theme.dart';
import '../../state/app_state.dart';
import 'servers_page.dart';

/// Selectable Material seed colors for the accent picker.
const List<Color> _accentSwatches = [
  Color(0xFF6750A4), // purple
  Color(0xFF00695C), // teal
  Color(0xFF1565C0), // blue
  Color(0xFF2E7D32), // green
  Color(0xFFEF6C00), // orange
  Color(0xFFC2185B), // pink
  Color(0xFFD32F2F), // red
  Color(0xFF5D4037), // brown
  Color(0xFF37474F), // blue grey
];

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
                    onSelectionChanged: (s) => config.setThemePreference(s.first),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.space_dashboard_outlined),
                  title: const Text('Density'),
                  trailing: SegmentedButton<UiDensity>(
                    segments: const [
                      ButtonSegment(value: UiDensity.comfortable, label: Text('Comfy')),
                      ButtonSegment(value: UiDensity.compact, label: Text('Compact')),
                    ],
                    selected: {config.uiDensity},
                    onSelectionChanged: (s) => config.setUiDensity(s.first),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.rounded_corner),
                  title: const Text('Corner radius'),
                  trailing: SegmentedButton<CornerRadius>(
                    style: ButtonStyle(visualDensity: VisualDensity.compact),
                    segments: const [
                      ButtonSegment(value: CornerRadius.standard, label: Text('Standard')),
                      ButtonSegment(value: CornerRadius.sharp, label: Text('Sharp')),
                      ButtonSegment(value: CornerRadius.rounded, label: Text('Rounded')),
                    ],
                    selected: {config.cornerRadius},
                    onSelectionChanged: (s) => config.setCornerRadius(s.first),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: const Text('Sent bubble color'),
                  trailing: SegmentedButton<BubbleStyle>(
                    style: ButtonStyle(visualDensity: VisualDensity.compact),
                    segments: const [
                      ButtonSegment(value: BubbleStyle.theme, label: Text('Theme')),
                      ButtonSegment(value: BubbleStyle.green, label: Text('Green')),
                      ButtonSegment(value: BubbleStyle.blue, label: Text('Blue')),
                    ],
                    selected: {config.bubbleStyle},
                    onSelectionChanged: (s) => config.setBubbleStyle(s.first),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(Icons.color_lens_outlined,
                            color: scheme.onSurfaceVariant),
                        const SizedBox(width: 16),
                        const Text('Accent color'),
                        const Spacer(),
                        if (config.seedColor != null)
                          TextButton(
                            onPressed: () => config.setSeedColor(null),
                            child: const Text('Wallpaper'),
                          ),
                      ]),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final c in _accentSwatches)
                            InkWell(
                              key: ValueKey(c),
                              borderRadius: BorderRadius.circular(20),
                              onTap: () {
                                config.setDynamicColor(false);
                                config.setSeedColor(c);
                              },
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: c,
                                  shape: BoxShape.circle,
                                  border: config.seedColor == c
                                      ? Border.all(
                                          color: scheme.onSurface, width: 3)
                                      : null,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => config.resetAppearance(),
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Reset appearance'),
                    ),
                  ),
                ),
              ],
            ),
          ),
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
                ListTile(
                  leading: Icon(Icons.link, color: scheme.primary),
                  title: Text(config.serverName ?? 'Connected server'),
                  subtitle: Text(config.serverBaseUrl ?? '',
                      style: const TextStyle(fontFamily: 'monospace')),
                  trailing: TextButton(
                    onPressed: () => context.read<AppState>().disconnect(),
                    child: const Text('Disconnect'),
                  ),
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
                      'Off by default. Lock the app with fingerprint / face / PIN on launch'),
                  value: config.vaultEnabled,
                  onChanged: (v) async {
                    if (v) {
                      // Confirm so it's a deliberate opt-in, never an accident.
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Enable biometric lock?'),
                          content: const Text(
                              'The app will lock on launch and require your '
                              'fingerprint, face, or device PIN to open. '
                              'You can disable it anytime from the lock screen.'),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Cancel')),
                            FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Enable')),
                          ],
                        ),
                      );
                      if (ok != true) return;
                    }
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
          Text('Notifications', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_outlined),
                  title: const Text('Notify on new replies'),
                  subtitle: const Text(
                      'Show a notification when Hermes finishes replying'),
                  value: config.notificationsEnabled,
                  onChanged: (v) {
                    if (v) NotificationsService.requestPermission();
                    config.setNotificationsEnabled(v);
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
              subtitle: const Text(
                  'Material You controller for Hermes Agent\nAndroid-optimized'),
              isThreeLine: true,
            ),
          ),
        ],
      ),
    );
  }
}
