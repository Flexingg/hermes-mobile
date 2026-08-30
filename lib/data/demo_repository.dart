import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'app_repository.dart';
import 'models.dart';

/// In-memory backend with realistic sample data and simulated latency, so the
/// whole UI is browsable offline with no server. Set `AppConfig.demoMode`.
class DemoRepository implements AppRepository {
  DemoRepository() {
    _seed();
  }

  final Random _rng = Random();
  final List<ServerProfile> _servers = [];
  final List<ChatSession> _sessions = [];
  final Map<String, List<ChatMessage>> _messages = {};
  final List<CronJob> _cronJobs = [];
  final List<Skill> _skills = [];
  final List<MemoryEntry> _memory = [];
  final List<LogEntry> _logs = [];
  final List<WebhookRoute> _webhooks = [];
  final List<CommandItem> _commands = [];
  final List<ModelHealth> _models = [];
  final Map<String, List<String>> _toolLog = {};

  static const _palette = [
    Color(0xFF6750A4),
    Color(0xFF00695C),
    Color(0xFFC2185B),
    Color(0xFF1565C0),
    Color(0xFFEF6C00),
    Color(0xFF2E7D32),
  ];

  String _id(String prefix) => '$prefix-${DateTime.now().microsecondsSinceEpoch}';

  void _seed() {
    _servers.addAll([
      const ServerProfile(
        id: 'srv-home',
        name: 'Hermes PC',
        baseUrl: 'http://192.168.1.146:9119',
        isDefault: true,
        accentColor: Color(0xFF00695C),
        bots: [
          BotProfile(
            id: 'bot-hermes',
            name: '@hermes',
            description: 'Main / default assistant',
            model: 'deepseek-v4-flash',
            emoji: '🧠',
          ),
          BotProfile(
            id: 'bot-patrick',
            name: '@buff_patrick',
            description: 'Fitness coach (SparkyFitness + Liftosaur)',
            model: 'deepseek-v4-flash',
            emoji: '💪',
          ),
          BotProfile(
            id: 'bot-homie',
            name: '@homie',
            description: 'Home Assistant controller',
            model: 'gpt-4o',
            emoji: '🏠',
          ),
        ],
      ),
    ]);

    final now = DateTime.now();
    _seedSession(
      id: 's1',
      title: '@hermes',
      profileId: 'bot-hermes',
      avatarColor: _palette[0],
      unread: 2,
      preview: 'I can set up that cron job for you — want it at 7am or 8am?',
      minutesAgo: 8,
      messages: [
        _msg('s1', 'hermes', 'user', 'Can you build a Flutter controller app for you?'),
        _msg('s1', 'hermes', 'assistant',
            'Absolutely! Here\'s a plan:\n\n1. Material You theming\n2. Google Messages-style UI\n3. Real-time streaming chat\n\nWant me to scaffold the repo?'),
        _msg('s1', 'hermes', 'tool', 'Ran: `gh repo create hermes-mobile` ✅', toolName: 'terminal'),
        _msg('s1', 'hermes', 'user', 'Yes! And make it Material Expressive.'),
        _msg('s1', 'hermes', 'assistant',
            'On it. Scaffolding the project now — Flutter 3.47, dynamic color from your wallpaper, springy motion. 🚀'),
      ],
    );
    _seedSession(
      id: 's2',
      title: '@buff_patrick',
      profileId: 'bot-patrick',
      avatarColor: _palette[2],
      unread: 0,
      preview: 'Great leg day. You hit 5x5 on squats — new PR! 💪',
      minutesAgo: 35,
      messages: [
        _msg('s2', 'patrick', 'user', 'Logging today\'s workout'),
        _msg('s2', 'patrick', 'assistant', 'Let\'s go! What\'s on the menu?'),
        _msg('s2', 'patrick', 'user', 'Squats 5x5 @ 225'),
        _msg('s2', 'patrick', 'assistant',
            '**5×5 @ 225 locked in** — that\'s a new PR 🎉\n\nNext: bench 3×8 @ 155, then some core.'),
      ],
    );
    _seedSession(
      id: 's3',
      title: '@homie',
      profileId: 'bot-homie',
      avatarColor: _palette[1],
      unread: 0,
      preview: 'Living room lights are now 60% warm white.',
      minutesAgo: 120,
      messages: [
        _msg('s3', 'homie', 'user', 'Dim the living room lights'),
        _msg('s3', 'homie', 'assistant', 'Done — turned them down to **60% warm white** ✨'),
      ],
    );
    _seedSession(
      id: 's4',
      title: 'Finances copilot',
      profileId: 'bot-hermes',
      avatarColor: _palette[5],
      unread: 0,
      pinned: true,
      preview: 'Your MTD spend is down 12% vs last month. Great job.',
      minutesAgo: 320,
      messages: [
        _msg('s4', 'hermes', 'user', 'How\'s my spending this month?'),
        _msg('s4', 'hermes', 'assistant',
            '📊 **MTD summary**\n- Spend: \$2,410 (-12% MoM)\n- Groceries: \$540\n- Biggest category: Eating out (\$680)\n\nWant me to auto-rule the recurring ones?'),
      ],
    );

    // Cron jobs mirroring buff_patrick's real routines.
    _cronJobs.addAll([
      CronJob(
        id: 'cron-1',
        name: 'Morning setup',
        schedule: '7:00 AM daily',
        prompt: 'Give @buff_patrick his day setup: weigh-in, workout plan, macros.',
        deliver: 'DM: bn9rwu9sfbnaddp616887qrboc',
        enabled: true,
        lastRun: now.subtract(const Duration(hours: 3)),
        lastStatus: '✅ Success',
      ),
      CronJob(
        id: 'cron-2',
        name: 'Evening recap',
        schedule: '8:00 PM daily',
        prompt: 'Day recap + call-to-action for @buff_patrick (workout/meals).',
        deliver: 'DM: bn9rwu9sfbnaddp616887qrboc',
        enabled: true,
        lastRun: now.subtract(const Duration(hours: 14)),
        lastStatus: '✅ Success',
      ),
      CronJob(
        id: 'cron-3',
        name: 'Finance backfill',
        schedule: '4:00 AM daily',
        prompt: 'Backfill SimpleFIN transactions via REST (quota-safe).',
        deliver: 'local',
        enabled: true,
        lastRun: now.subtract(const Duration(hours: 7)),
        lastStatus: '⚠️ Partial',
      ),
      CronJob(
        id: 'cron-4',
        name: 'Home watch',
        schedule: 'Every 30m',
        prompt: 'Check Home Assistant entity anomalies.',
        deliver: 'origin',
        enabled: false,
        lastRun: now.subtract(const Duration(days: 1)),
        lastStatus: '✅ Success',
      ),
    ]);

    _skills.addAll([
      Skill(id: 'sk1', name: 'hermes-agent', description: 'Use, configure, theme & orchestrate Hermes Agent.', tags: ['hermes', 'setup', 'orchestration']),
      Skill(id: 'sk2', name: 'mattermost-api', description: 'Operate Mattermost via its REST API.', tags: ['messaging', 'mattermost']),
      Skill(id: 'sk3', name: 'claude-code', description: 'Delegate coding to Claude Code CLI.', tags: ['coding', 'delegation']),
      Skill(id: 'sk4', name: 'firebase-firestore', description: 'Working with Firebase / Firestore.', tags: ['firebase', 'backend']),
      Skill(id: 'sk5', name: 'product-price-monitor', description: 'Watch prices and alert on targets.', tags: ['monitor', 'alerts']),
      Skill(id: 'sk6', name: 'sunshine-streaming-host', description: 'Set up Sunshine/Moonlight streaming host.', tags: ['streaming', 'games']),
    ]);

    _memory.addAll([
      MemoryEntry(id: 'mem1', category: 'user', content: 'User\'s GitHub: Flexingg. Commits as Jonathan Randall <j03randall@gmail.com>. SSH key auth.', createdAt: now.subtract(const Duration(days: 30))),
      MemoryEntry(id: 'mem2', category: 'memory', content: 'Mattermost bots on chat.randalls.cc: @hermes, @buff_patrick (deepseek), @homie (Home Assistant).', createdAt: now.subtract(const Duration(days: 20))),
      MemoryEntry(id: 'mem3', category: 'user', content: 'User prefers frequent progress updates (~every 10 min) during long autonomous builds.', createdAt: now.subtract(const Duration(days: 12))),
      MemoryEntry(id: 'mem4', category: 'memory', content: 'Finance Firestore free-tier write-quota exhaustion makes admin-SDK writes HANG — use REST (429 fast).', createdAt: now.subtract(const Duration(days: 6))),
      MemoryEntry(id: 'mem5', category: 'user', content: 'Self-hosts Hermes on hermes-pc (Ubuntu/GNOME Wayland). Gateway + dashboard as systemd user services.', createdAt: now.subtract(const Duration(days: 4))),
    ]);

    _logs.addAll([
      LogEntry(id: 'l1', level: 'INFO', message: 'Gateway started on 0.0.0.0:9119', source: 'gateway', timestamp: now.subtract(const Duration(days: 1))),
      LogEntry(id: 'l2', level: 'INFO', message: 'Session resumed: 20260829_070000', source: 'session', timestamp: now.subtract(const Duration(hours: 5))),
      LogEntry(id: 'l3', level: 'WARN', message: 'Firestore write quota 92% used (REST 429 rate-limiting)', source: 'finances', timestamp: now.subtract(const Duration(hours: 4))),
      LogEntry(id: 'l4', level: 'ERROR', message: 'Liftosaur MCP: DeepSeek key was empty in buff-patrick .env', source: 'buff-patrick', timestamp: now.subtract(const Duration(hours: 3))),
      LogEntry(id: 'l5', level: 'INFO', message: 'Cron fired: Morning setup → ✅ Success', source: 'cron', timestamp: now.subtract(const Duration(hours: 3))),
      LogEntry(id: 'l6', level: 'INFO', message: 'Webhook /finance-backfill triggered', source: 'webhook', timestamp: now.subtract(const Duration(hours: 2))),
      LogEntry(id: 'l7', level: 'INFO', message: 'Memory updated (4 entries)', source: 'memory', timestamp: now.subtract(const Duration(minutes: 40))),
    ]);

    _models.addAll([
      const ModelHealth(provider: 'DeepSeek', model: 'deepseek-v4-flash', online: true),
      const ModelHealth(provider: 'OpenAI', model: 'gpt-4o', online: true, quotaStatus: '87% left'),
      const ModelHealth(provider: 'Anthropic', model: 'claude-4-5-sonnet', online: true),
      const ModelHealth(provider: 'Google', model: 'gemini-2.5-pro', online: true),
    ]);

    _webhooks.addAll([
      WebhookRoute(id: 'wh1', name: '/finance-backfill', description: 'Backfill SimpleFIN transactions (REST, quota-safe)'),
      WebhookRoute(id: 'wh2', name: '/home-snapshot', description: 'Post current Home Assistant entity snapshot'),
      WebhookRoute(id: 'wh3', name: '/daily-digest', description: 'Generate and deliver daily digest'),
    ]);

    _commands.addAll([
      const CommandItem(id: 'c-session', label: '/session', description: 'Session management', icon: 'forum'),
      const CommandItem(id: 'c-memory', label: '/memory', description: 'View / edit persistent memory', icon: 'memory'),
      const CommandItem(id: 'c-skills', label: '/skills', description: 'List installed skills', icon: 'widgets'),
      const CommandItem(id: 'c-cron', label: '/cron', description: 'Scheduled routines', icon: 'schedule'),
      const CommandItem(id: 'c-doctor', label: '/doctor', description: 'Run health checks', icon: 'medical'),
      const CommandItem(id: 'c-model', label: '/model', description: 'Switch active model/provider', icon: 'smart_toy'),
      const CommandItem(id: 'c-config', label: '/config', description: 'View live configuration', icon: 'tune'),
      const CommandItem(id: 'c-logs', label: '/logs', description: 'Tail gateway/error logs', icon: 'terminal'),
    ]);

    _toolLog['s1'] = ['gh repo create hermes-mobile', 'flutter create --org com.randalls'];
  }

  void _seedSession({
    required String id,
    required String title,
    required String profileId,
    required Color avatarColor,
    required String preview,
    required int minutesAgo,
    required int unread,
    bool pinned = false,
    required List<ChatMessage> messages,
  }) {
    final ts = DateTime.now().subtract(Duration(minutes: minutesAgo));
    _sessions.add(ChatSession(
      id: id,
      title: title,
      profileId: profileId,
      lastPreview: preview,
      lastTimestamp: ts,
      unreadCount: unread,
      pinned: pinned,
      avatarColor: avatarColor,
    ));
    _messages[id] = messages;
  }

  ChatMessage _msg(String sessionId, String _from, String role, String text,
      {String? toolName}) {
    return ChatMessage(
      id: _id('m'),
      sessionId: sessionId,
      role: ChatMessageRole.values.firstWhere(
          (r) => r.name == role,
          orElse: () => ChatMessageRole.user),
      text: text,
      timestamp: DateTime.now().subtract(Duration(minutes: _rng.nextInt(60))),
      toolName: toolName,
    );
  }

  @override
  Future<List<ServerProfile>> servers() async => List.of(_servers);

  @override
  Future<ServerProfile> addServer(ServerProfile profile) async {
    _servers.add(profile);
    return profile;
  }

  @override
  Future<void> updateServer(ServerProfile profile) async {
    final i = _servers.indexWhere((s) => s.id == profile.id);
    if (i >= 0) _servers[i] = profile;
  }

  @override
  Future<void> removeServer(String id) async {
    _servers.removeWhere((s) => s.id == id);
  }

  @override
  Future<List<ChatSession>> sessions() async {
    await _delay();
    final list = List.of(_sessions);
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.lastTimestamp.compareTo(a.lastTimestamp);
    });
    return list;
  }

  @override
  Future<List<ChatMessage>> messages(String sessionId) async {
    await _delay(150);
    return List.of(_messages[sessionId] ?? []);
  }

  @override
  Future<ChatSession> createSession(String title, String profileId) async {
    final s = ChatSession(
      id: _id('s'),
      title: title,
      profileId: profileId,
      lastPreview: 'New conversation',
      lastTimestamp: DateTime.now(),
      avatarColor: _palette[_rng.nextInt(_palette.length)],
    );
    _sessions.add(s);
    _messages[s.id] = [];
    return s;
  }

  @override
  Stream<ChatMessage> sendMessage(String sessionId, String text) async* {
    final messages = _messages.putIfAbsent(sessionId, () => []);
    final userMsg = ChatMessage(
      id: _id('m'),
      sessionId: sessionId,
      role: ChatMessageRole.user,
      text: text,
      timestamp: DateTime.now(),
    );
    messages.add(userMsg);
    // Bump session preview.
    final si = _sessions.indexWhere((s) => s.id == sessionId);
    if (si >= 0) {
      _sessions[si] = _sessions[si]
          .copyWith(lastPreview: text, lastTimestamp: DateTime.now());
    }

    // Simulate the assistant thinking + tool call, then streaming a reply.
    yield* _simulateReply(sessionId, text);
  }

  Stream<ChatMessage> _simulateReply(String sessionId, String text) async* {
    final replyId = _id('m');
    final msgs = _messages[sessionId]!;

    // Thinking pause.
    await Future.delayed(const Duration(milliseconds: 700));
    yield ChatMessage(
      id: replyId,
      sessionId: sessionId,
      role: ChatMessageRole.assistant,
      text: '',
      timestamp: DateTime.now(),
      status: ChatMessageStatus.streaming,
    );

    final lower = text.toLowerCase();
    String full;
    if (lower.contains('cron') || lower.contains('schedule')) {
      full = 'Sure! I can schedule that.\n\nI\'ve set up a recurring job at **8:00 PM daily** delivering to your DM.\n\n`createCronJob(name: "Evening recap", schedule: "0 20 * * *")` ✅';
    } else if (lower.contains('memory')) {
      full = 'Here\'s what I remember about you:\n\n- GitHub: **Flexingg**\n- Prefers **frequent progress updates**\n- Self-hosts on **hermes-pc**\n\nTap the *Memory* tab to edit or add entries.';
    } else if (lower.contains('status') || lower.contains('health')) {
      full = '🟢 **All systems nominal**\n\n- Gateway: up (uptime 3d 4h)\n- CPU: 23% · RAM: 41% · Disk: 62%\n- Active sessions: 2\n\nDeepSeek and OpenAI providers online.';
    } else if (lower.contains('skill')) {
      full = 'I have **6 skills** installed, including `hermes-agent`, `mattermost-api`, `claude-code`, and `firebase-firestore`.\n\nWant to browse or toggle any of them?';
    } else {
      full = 'On it! Here\'s how I can help with *"$text"*:\n\nI\'ll break it into steps, call the right tools, and keep you posted as I work. ✅\n\nAnything specific you\'d like me to prioritize?';
    }

    // Stream the reply word by word.
    final words = full.split(' ');
    var acc = '';
    for (final w in words) {
      await Future.delayed(Duration(milliseconds: 40 + _rng.nextInt(50)));
      acc = acc.isEmpty ? w : '$acc $w';
      msgs.add(ChatMessage(
        id: replyId,
        sessionId: sessionId,
        role: ChatMessageRole.assistant,
        text: acc,
        timestamp: DateTime.now(),
        status: ChatMessageStatus.streaming,
      ));
      yield ChatMessage(
        id: replyId,
        sessionId: sessionId,
        role: ChatMessageRole.assistant,
        text: acc,
        timestamp: DateTime.now(),
        status: ChatMessageStatus.streaming,
      );
    }
    // Final committed message.
    msgs.removeWhere((m) => m.id == replyId && m.status == ChatMessageStatus.streaming);
    final finalMsg = ChatMessage(
      id: replyId,
      sessionId: sessionId,
      role: ChatMessageRole.assistant,
      text: full,
      timestamp: DateTime.now(),
      status: ChatMessageStatus.sent,
    );
    msgs.add(finalMsg);
    final si = _sessions.indexWhere((s) => s.id == sessionId);
    if (si >= 0) {
      _sessions[si] = _sessions[si].copyWith(
          lastPreview: full.replaceAll('\n', ' '), lastTimestamp: DateTime.now());
    }
    yield finalMsg;
  }

  @override
  Future<void> markRead(String sessionId) async {
    final i = _sessions.indexWhere((s) => s.id == sessionId);
    if (i >= 0) _sessions[i] = _sessions[i].copyWith(unreadCount: 0);
  }

  @override
  Future<void> togglePinned(String sessionId) async {
    final i = _sessions.indexWhere((s) => s.id == sessionId);
    if (i >= 0) {
      final s = _sessions[i];
      _sessions[i] = s.copyWith(pinned: !s.pinned);
    }
  }

  @override
  Future<void> toggleStarred(String sessionId) async {
    final i = _sessions.indexWhere((s) => s.id == sessionId);
    if (i >= 0) {
      final s = _sessions[i];
      _sessions[i] = s.copyWith(starred: !s.starred);
    }
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    _sessions.removeWhere((s) => s.id == sessionId);
    _messages.remove(sessionId);
  }

  @override
  Future<List<ChatSession>> searchSessions(String query) async {
    final q = query.toLowerCase();
    return _sessions
        .where((s) =>
            s.title.toLowerCase().contains(q) ||
            s.lastPreview.toLowerCase().contains(q))
        .toList();
  }

  @override
  Future<List<CronJob>> cronJobs() async => List.of(_cronJobs);

  @override
  Future<CronJob> createCronJob(CronJob job) async {
    _cronJobs.add(job);
    return job;
  }

  @override
  Future<void> updateCronJob(CronJob job) async {
    final i = _cronJobs.indexWhere((c) => c.id == job.id);
    if (i >= 0) _cronJobs[i] = job;
  }

  @override
  Future<void> deleteCronJob(String id) async {
    _cronJobs.removeWhere((c) => c.id == id);
  }

  @override
  Future<CronJob> runCronJob(String id) async {
    final i = _cronJobs.indexWhere((c) => c.id == id);
    if (i >= 0) {
      _cronJobs[i] = _cronJobs[i].copyWith(
        lastRun: DateTime.now(),
        lastStatus: '✅ Success',
      );
    }
    return _cronJobs[i];
  }

  @override
  Future<List<Skill>> skills() async => List.of(_skills);

  @override
  Future<void> toggleSkill(String id) async {
    final i = _skills.indexWhere((s) => s.id == id);
    if (i >= 0) {
      final s = _skills[i];
      _skills[i] = Skill(
        id: s.id,
        name: s.name,
        description: s.description,
        tags: s.tags,
        enabled: !s.enabled,
      );
    }
  }

  @override
  Future<List<MemoryEntry>> memoryEntries({String? category}) async {
    if (category == null) return List.of(_memory);
    return _memory.where((m) => m.category == category).toList();
  }

  @override
  Future<MemoryEntry> addMemory(String category, String content) async {
    final m = MemoryEntry(
      id: _id('mem'),
      category: category,
      content: content,
      createdAt: DateTime.now(),
    );
    _memory.insert(0, m);
    return m;
  }

  @override
  Future<void> deleteMemory(String id) async {
    _memory.removeWhere((m) => m.id == id);
  }

  @override
  Future<List<MemoryEntry>> searchMemory(String query) async {
    final q = query.toLowerCase();
    return _memory.where((m) => m.content.toLowerCase().contains(q)).toList();
  }

  @override
  Future<ServerStatus> serverStatus() async {
    return ServerStatus(
      cpu: (23 + _rng.nextInt(8)).toDouble(),
      memory: 41,
      disk: 62,
      uptime: '3d 4h 12m',
      gatewayUp: true,
      activeSessions: 2,
      version: '3.2.0',
      fetchedAt: DateTime.now(),
    );
  }

  @override
  Future<List<LogEntry>> logs({int limit = 100}) async =>
      List.of(_logs).reversed.take(limit).toList();

  @override
  Future<List<ModelHealth>> modelHealth() async => List.of(_models);

  @override
  Future<List<ToolActivity>> toolActivities({String? sessionId}) async {
    final list = _toolLog[sessionId] ?? [];
    return list
        .map((t) => ToolActivity(
              id: _id('ta'),
              toolName: 'terminal',
              status: 'done',
              detail: t,
              timestamp: DateTime.now().subtract(const Duration(minutes: 2)),
              sessionId: sessionId ?? '',
            ))
        .toList();
  }

  @override
  Future<List<String>> toolCatalog() async => const [
        'terminal',
        'web_search',
        'web_extract',
        'read_file',
        'write_file',
        'patch',
        'search_files',
        'browser_navigate',
        'cronjob',
        'delegate_task',
        'skill_manage',
      ];

  @override
  Future<List<CommandItem>> commandPalette() async => List.of(_commands);

  @override
  Future<List<WebhookRoute>> webhooks() async => List.of(_webhooks);

  @override
  Future<void> triggerWebhook(String id) async {
    // no-op in demo
  }

  Future<void> _delay([int ms = 250]) async {
    await Future.delayed(Duration(milliseconds: ms));
  }
}
