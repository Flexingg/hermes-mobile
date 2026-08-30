import 'package:flutter/material.dart';
import 'command_palette.dart';
import 'cron_page.dart';
import 'memory_page.dart';
import 'skills_page.dart';
import 'tools_page.dart';
import 'webhooks_page.dart';

/// Control hub: command palette trigger + tabbed management surfaces
/// (Memory, Skills, Cron, Tools, Webhooks).
class ControllerPage extends StatefulWidget {
  const ControllerPage({super.key});

  @override
  State<ControllerPage> createState() => _ControllerPageState();
}

class _ControllerPageState extends State<ControllerPage> {
  int _tab = 0;
  final _memoryKey = GlobalKey<MemoryPageState>();

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
        bottom: TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          onTap: (i) => setState(() => _tab = i),
          tabs: const [
            Tab(text: 'Memory'),
            Tab(text: 'Skills'),
            Tab(text: 'Cron'),
            Tab(text: 'Tools'),
            Tab(text: 'Webhooks'),
          ],
        ),
      ),
      body: IndexedStack(index: _tab, children: pages),
      floatingActionButton: _tab == 0
          ? FloatingActionButton.small(
              heroTag: 'addmem',
              tooltip: 'Add memory',
              onPressed: () => _memoryKey.currentState?.showAddButton(context),
              child: const Icon(Icons.add),
            )
          : null,
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              useSafeArea: true,
              shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
              builder: (_) => const CommandPalette(),
            ),
            icon: const Icon(Icons.travel_explore_rounded),
            label: const Text('Search commands & tools'),
          ),
        ),
      ),
    );
  }
}
