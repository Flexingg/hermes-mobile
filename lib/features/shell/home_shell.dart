import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../chat/chat_list_page.dart';
import '../controller/controller_page.dart';
import '../dashboard/dashboard_page.dart';
import '../settings/settings_page.dart';

/// Root scaffold. A Material 3 [NavigationBar] hosts the four sections.
/// Chats is the Google-Messages-style primary surface.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = const [
      ChatListPage(),
      ControllerPage(),
      DashboardPage(),
      SettingsPage(),
    ];
    final state = context.watch<AppState>();
    return Scaffold(
      body: Column(
        children: [
          // Failures used to disappear into `catch (_) {}`; a visible strip is
          // the difference between "the bridge is down" and "nothing happened".
          if (state.error != null)
            ErrorBanner(
              message: state.error!,
              log: state.errorLog,
              onDismiss: state.clearError,
            ),
          Expanded(child: IndexedStack(index: _index, children: pages)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.forum_outlined),
              selectedIcon: Icon(Icons.forum),
              label: 'Chats'),
          NavigationDestination(
              icon: Icon(Icons.play_circle_outline),
              selectedIcon: Icon(Icons.play_circle),
              label: 'Control'),
          NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: 'Status'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings'),
        ],
      ),
    );
  }
}
