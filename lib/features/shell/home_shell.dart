import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../chat/chat_list_page.dart';
import '../controller/controller_page.dart';
import '../dashboard/dashboard_page.dart';
import '../projects/projects_page.dart';
import '../settings/settings_page.dart';

/// Root scaffold. A Material 3 [NavigationBar] hosts the five sections.
/// Projects comes first: linked repos, their agents, and the work Hermes is
/// running for them. Chats keeps the Google-Messages-style conversations.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    // The ask bar creates its 'Assistant' session from its own engine, which
    // this app never hears about; without a reload on return the chat list
    // would not show the conversation the user just had. Skipped while
    // disconnected, where a reload could only put up an error banner.
    if (lifecycle != AppLifecycleState.resumed) return;
    final state = context.read<AppState>();
    if (state.connected) state.refreshSessions();
  }

  /// Work waiting on the user: PRs ready to test plus tasks that need them.
  int _attention(AppState state) => state.projects.fold(0, (n, p) => n + p.ready + p.needsYou);

  @override
  Widget build(BuildContext context) {
    final pages = const [
      ProjectsPage(),
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
        destinations: [
          NavigationDestination(
              icon: Badge(
                  isLabelVisible: _attention(state) > 0,
                  label: Text('${_attention(state)}'),
                  child: const Icon(Icons.folder_special_outlined)),
              selectedIcon: const Icon(Icons.folder_special),
              label: 'Projects'),
          const NavigationDestination(
              icon: Icon(Icons.forum_outlined),
              selectedIcon: Icon(Icons.forum),
              label: 'Chats'),
          const NavigationDestination(
              icon: Icon(Icons.play_circle_outline),
              selectedIcon: Icon(Icons.play_circle),
              label: 'Control'),
          const NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: 'Status'),
          const NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings'),
        ],
      ),
    );
  }
}
