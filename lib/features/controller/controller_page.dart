import 'package:flutter/material.dart';
import 'command_palette.dart';
import 'cron_page.dart';
import 'memory_page.dart';
import 'skills_page.dart';
import 'tools_page.dart';
import 'webhooks_page.dart';

/// Control hub: command palette trigger + tabbed management surfaces
/// (Memory, Skills, Cron, Tools, Webhooks). Uses a standard swipeable
/// [TabBarView] with actions in the app bar.
class ControllerPage extends StatefulWidget {
  const ControllerPage({super.key});

  @override
  State<ControllerPage> createState() => _ControllerPageState();
}

class _ControllerPageState extends State<ControllerPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  int _tab = 0;
  final _memoryKey = GlobalKey<MemoryPageState>();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging && mounted) {
        setState(() => _tab = _tabController.index);
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _openPalette(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => const CommandPalette(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      MemoryPage(key: _memoryKey),
      const SkillsPage(),
      const CronPage(),
      const ToolsPage(),
      const WebhooksPage(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Control',
            style: TextStyle(fontWeight: FontWeight.w600)),
        actions: [
          if (_tab == 0)
            IconButton(
              tooltip: 'Add memory',
              icon: const Icon(Icons.add),
              onPressed: () =>
                  _memoryKey.currentState?.showAddButton(context),
            ),
          IconButton(
            tooltip: 'Commands & tools',
            icon: const Icon(Icons.travel_explore_rounded),
            onPressed: () => _openPalette(context),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'Memory'),
            Tab(text: 'Skills'),
            Tab(text: 'Cron'),
            Tab(text: 'Tools'),
            Tab(text: 'Webhooks'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: pages,
      ),
    );
  }
}
