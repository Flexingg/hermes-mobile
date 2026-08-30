import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/config/app_config.dart';
import '../../core/notifications/push.dart';
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
                _SegRow<ThemePreference>(
                  icon: Icons.brightness_6_outlined,
                  label: 'Theme mode',
                  selected: config.themePreference,
                  onChanged: config.setThemePreference,
                  segments: const [
                    ButtonSegment(value: ThemePreference.system, label: Text('Auto')),
                    ButtonSegment(value: ThemePreference.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
                    ButtonSegment(value: ThemePreference.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
                  ],
                ),
                const Divider(height: 1),
                _SegRow<UiDensity>(
                  icon: Icons.space_dashboard_outlined,
                  label: 'Density',
                  selected: config.uiDensity,
                  onChanged: config.setUiDensity,
                  segments: const [
                    ButtonSegment(value: UiDensity.comfortable, label: Text('Comfy')),
                    ButtonSegment(value: UiDensity.compact, label: Text('Compact')),
                  ],
                ),
                const Divider(height: 1),
                _SegRow<CornerRadius>(
                  icon: Icons.rounded_corner,
                  label: 'Corner radius',
                  selected: config.cornerRadius,
                  onChanged: config.setCornerRadius,
                  segments: const [
                    ButtonSegment(value: CornerRadius.standard, label: Text('Standard')),
                    ButtonSegment(value: CornerRadius.sharp, label: Text('Sharp')),
                    ButtonSegment(value: CornerRadius.rounded, label: Text('Rounded')),
                  ],
                ),
                const Divider(height: 1),
                _SegRow<BubbleStyle>(
                  icon: Icons.chat_bubble_outline,
                  label: 'Sent bubble color',
                  selected: config.bubbleStyle,
                  onChanged: config.setBubbleStyle,
                  segments: const [
                    ButtonSegment(value: BubbleStyle.theme, label: Text('Theme')),
                    ButtonSegment(value: BubbleStyle.green, label: Text('Green')),
                    ButtonSegment(value: BubbleStyle.blue, label: Text('Blue')),
                  ],
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
                  title: const Text('Push notifications'),
                  subtitle: const Text(
                      'Get a notification when Hermes replies (even when the '
                      'app is closed). Requires permission.'),
                  value: config.notificationsEnabled,
                  onChanged: (v) async {
                    if (v) {
                      final granted = await PushService.requestPermission();
                      if (!granted) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'Notification permission was not granted. '
                                    'Enable it in system settings.')),
                          );
                        }
                        return; // leave it off
                      }
                    }
                    await config.setNotificationsEnabled(v);
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  enabled: config.notificationsEnabled,
                  leading: const Icon(Icons.send_outlined),
                  title: const Text('Send test push'),
                  subtitle: const Text('Fire a test notification to this device'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final st = context.read<AppState>();
                    try {
                      await st.repo.sendTestPush(
                          title: 'Mercury Messenger',
                          message: 'Push works ✅ from your Hermes bridge');
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Test push sent.')),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Test push failed: $e')),
                        );
                      }
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

/// A full-width settings row: icon + label, then a segmented control that
/// stretches across the width so long labels never wrap into vertical text.
class _SegRow<T> extends StatelessWidget {
  final IconData icon;
  final String label;
  final T selected;
  final List<ButtonSegment<T>> segments;
  final ValueChanged<T> onChanged;

  const _SegRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.segments,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Text(label, style: Theme.of(context).textTheme.titleSmall),
          ]),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<T>(
              segments: segments,
              selected: {selected},
              onSelectionChanged: (s) => onChanged(s.first),
              expandedInsets: EdgeInsets.zero,
              showSelectedIcon: false,
            ),
          ),
        ],
      ),
    );
  }
}

