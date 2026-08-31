import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import '../core/config/app_config.dart';
import '../core/notifications/notifications.dart';
import '../core/notifications/push.dart';
import '../data/app_repository.dart';
import '../data/hermes_repository.dart';
import '../data/models.dart';

/// Central reactive store driving the UI. Pages watch this notifier and call
/// its methods; it owns the repository instance and streaming subscriptions.
///
/// There is no demo backend — [repo] always talks to a real Hermes server via
/// [HermesRepository]. The app shows no data until the user connects to a
/// server (see `connect()`).
class AppState extends ChangeNotifier {
  final AppConfig config;
  late AppRepository repo;

  // ---- chat / sessions ----
  List<ChatSession> sessions = [];
  final Map<String, List<ChatMessage>> _messages = {};
  String? activeSessionId;
  bool sending = false;

  // Optimistic new-chat flow: a thread opens under a temp id, then swaps to
  // the real session once the bridge creates it.
  String? _newChatTargetId;
  bool _creatingChat = false;

  String? get newChatTargetId => _newChatTargetId;
  bool get creatingChat => _creatingChat;
  StreamSubscription<ChatMessage>? _sub;

  // ---- Group chats (multi-agent) ----
  List<GroupChat> _groups = [];
  final Map<String, List<ChatMessage>> _groupMessages = {};
  bool groupSending = false;
  StreamSubscription<ChatMessage>? _groupSub;
  List<GroupChat> get groups => List.unmodifiable(_groups);
  List<ChatMessage> groupMessagesFor(String gid) => _groupMessages[gid] ?? [];

  // ---- Bots (Hermes profiles) ----
  List<Bot> _bots = [];
  List<Bot> get bots => List.unmodifiable(_bots);
  List<String> _botPets = const [];
  List<String> get botPets => _botPets;
  String? _selectedPet = 'boba';
  String? get selectedPet => _selectedPet;
  set selectedPet(String? v) {
    _selectedPet = v;
    notifyListeners();
  }

  // ---- cached domain data (controller + dashboard) ----
  List<CronJob> cronJobs = [];
  List<Skill> skills = [];
  List<MemoryEntry> memory = [];
  List<MemoryEntry> userMemory = [];
  ServerStatus? status;
  List<LogEntry> logs = [];
  List<ModelHealth> models = [];
  List<ToolActivity> activities = [];
  List<CommandItem> commands = [];
  List<WebhookRoute> webhooks = [];
  List<ServerProfile> servers = [];

  bool busy = false;
  String? error;
  bool _disposed = false;

  /// True once a real server has been reached successfully.
  bool connected = false;

  /// Guarded notify: never fire after dispose (avoids the `_dependents.isEmpty`
  /// assertion when a subtree is being torn down).
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  AppState(this.config);

  /// Called after the first frame: if a server is already configured, connect
  /// and load real data. Otherwise the app stays on the connect screen.
  Future<void> init() async {
    if (!config.hasServer) {
      connected = false;
      notifyListeners();
      return;
    }
    final token = await config.serverToken;
    repo = HermesRepository(
      baseUrl: config.serverBaseUrl!,
      token: token,
    );
    await _connect();
  }

  /// Validate + connect to a server, persisting it, then load real data.
  Future<void> connect({
    required String name,
    required String baseUrl,
    required String token,
  }) async {
    await config.setServer(name: name, baseUrl: baseUrl, token: token);
    repo = HermesRepository(baseUrl: baseUrl, token: token);
    await _connect();
  }

  Future<void> _connect() async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final s = await repo.serverStatus();
      status = s;
      // Connection is verified by a live status response — this is what gates
      // the app into the connected state. Individual data loads below must not
      // undo it if a single endpoint is missing or errors.
      connected = true;
    } catch (e) {
      connected = false;
      error = 'Could not reach server: $e';
      busy = false;
      notifyListeners();
      return;
    }
    await loadAll(); // resilient: never throws, never disconnects
    // Let the bridge push to this device once we're connected.
    PushService.tokenSink = repo.registerDevice;
    if (PushService.token != null) {
      try {
        await repo.registerDevice(PushService.token!);
      } catch (_) {}
    }
    busy = false;
    notifyListeners();
  }

  /// Runs a loader, swallowing errors so one failing endpoint can't abort the
  /// rest or disconnect the app. Errors are surfaced via [error].
  Future<void> _safe(Future<void> Function() job) async {
    try {
      await job();
    } catch (e) {
      error = e.toString();
    }
  }

  Future<void> disconnect() async {
    await config.clearServer();
    connected = false;
    _sub?.cancel();
    sessions = [];
    _messages.clear();
    cronJobs = [];
    skills = [];
    memory = [];
    status = null;
    logs = [];
    models = [];
    activities = [];
    commands = [];
    webhooks = [];
    servers = [];
    _groups = [];
    _groupMessages.clear();
    _groupSub?.cancel();
    _bots = [];
    _botPets = const [];
    notifyListeners();
  }

  List<ChatMessage> messagesFor(String sessionId) =>
      _messages[sessionId] ?? [];

  // ---- bootstrap / refresh ------------------------------------------
  Future<void> refreshServers() async {
    try {
      servers = await repo.servers();
    } catch (e) {
      error = e.toString();
    }
    notifyListeners();
  }

  Future<void> refreshSessions() async {
    try {
      sessions = await repo.sessions();
    } catch (e) {
      error = e.toString();
    }
    notifyListeners();
  }

  Future<void> openSession(String id) async {
    activeSessionId = id;
    await repo.markRead(id);
    if (!_messages.containsKey(id)) {
      _messages[id] = await repo.messages(id);
    }
    await refreshSessions();
    notifyListeners();
  }

  Future<void> createSession(String title, String profileId) async {
    final s = await repo.createSession(title, profileId);
    await refreshSessions();
    notifyListeners();
    await openSession(s.id);
  }

  /// Optimistic start of a brand-new conversation. The thread already shows
  /// the user's message under [pendingId]; this creates the real session and,
  /// when ready, points [newChatTargetId] at it so the thread swaps over.
  Future<void> createNewChat({
    required String name,
    required String text,
    required String pendingId,
  }) async {
    _creatingChat = true;
    _newChatTargetId = null;
    _messages[pendingId] = [
      ChatMessage(
        id: 'opt-${DateTime.now().millisecondsSinceEpoch}',
        sessionId: pendingId,
        role: ChatMessageRole.user,
        text: text,
        timestamp: DateTime.now(),
        status: ChatMessageStatus.sent,
      ),
    ];
    notifyListeners();
    try {
      final session = await repo.startNewChat(name: name, text: text);
      _newChatTargetId = session.id;
      await refreshSessions();
      await openSession(session.id);
    } catch (e) {
      final list = List<ChatMessage>.from(_messages[pendingId] ?? const []);
      list.add(ChatMessage(
        id: 'opt-err-${DateTime.now().millisecondsSinceEpoch}',
        sessionId: pendingId,
        role: ChatMessageRole.assistant,
        text: 'Could not start chat: $e',
        timestamp: DateTime.now(),
        status: ChatMessageStatus.error,
      ));
      _messages[pendingId] = list;
    } finally {
      _creatingChat = false;
      notifyListeners();
    }
  }

  Future<void> deleteSession(String id) async {
    await repo.deleteSession(id);
    _messages.remove(id);
    if (activeSessionId == id) activeSessionId = null;
    await refreshSessions();
  }

  Future<void> togglePinned(String id) async {
    await repo.togglePinned(id);
    await refreshSessions();
  }

  // ---- Group chats (multi-agent) ------------------------------------
  Future<void> loadGroups() async {
    try {
      _groups = await repo.groups();
      notifyListeners();
    } catch (_) {}
  }

  Future<GroupChat> createGroup({
    required String name,
    required List<String> agents,
  }) async {
    final g = await repo.createGroup(name: name, agents: agents);
    _groups = [g, ..._groups.where((x) => x.id != g.id)];
    notifyListeners();
    return g;
  }

  Future<void> openGroup(String gid) async {
    try {
      _groupMessages[gid] = await repo.groupMessages(gid);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> sendGroupMessage(String gid, String text) async {
    if (groupSending) return;
    groupSending = true;
    notifyListeners();
    final userMsg = ChatMessage(
      id: 'u-${DateTime.now().microsecondsSinceEpoch}',
      sessionId: gid,
      role: ChatMessageRole.user,
      text: text,
      timestamp: DateTime.now(),
    );
    _groupMessages.putIfAbsent(gid, () => []).add(userMsg);
    notifyListeners();

    await _groupSub?.cancel();
    _groupSub = repo.sendGroupMessage(gid, text).listen(
      (m) {
        final list = _groupMessages.putIfAbsent(gid, () => []);
        final idx = list.indexWhere((x) => x.id == m.id);
        if (idx >= 0) {
          list[idx] = m;
        } else {
          list.add(m);
        }
        notifyListeners();
      },
      onError: (e) {
        error = e.toString();
        groupSending = false;
        notifyListeners();
      },
      onDone: () {
        groupSending = false;
        notifyListeners();
      },
    );
  }

  Future<void> deleteGroup(String gid) async {
    await repo.deleteGroup(gid);
    _groupMessages.remove(gid);
    _groups = _groups.where((g) => g.id != gid).toList();
    notifyListeners();
  }

  // ---- Bots (Hermes profiles) -----------------------------------------
  Future<void> loadBots() async {
    try {
      _bots = await repo.bots();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> loadBotPets() async {
    try {
      _botPets = await repo.botPets();
      notifyListeners();
    } catch (_) {}
  }

  Future<Bot> createBot({required String name, String? description}) async {
    final b = await repo.createBot(name: name, description: description);
    await loadBots();
    return b;
  }

  Future<void> updateBot(String id,
      {String? description, String? pet, String? soul}) async {
    await repo.updateBot(id,
        description: description, pet: pet, soul: soul);
    await loadBots();
  }

  Future<void> deleteBot(String id) async {
    await repo.deleteBot(id);
    await loadBots();
  }

  Future<void> toggleStarred(String id) async {
    await repo.toggleStarred(id);
    await refreshSessions();
  }

  Future<void> sendMessage(String text, {List<Attachment> attachments = const []}) async {
    final sid = activeSessionId;
    if (sid == null || sending) return;
    sending = true;
    notifyListeners();

    final userMsg = ChatMessage(
      id: 'u-${DateTime.now().microsecondsSinceEpoch}',
      sessionId: sid,
      role: ChatMessageRole.user,
      text: text,
      timestamp: DateTime.now(),
      attachments: attachments,
    );
    _messages.putIfAbsent(sid, () => []).add(userMsg);
    notifyListeners();

    await _sub?.cancel();
    _sub = repo.sendMessage(sid, text, attachments: attachments).listen((m) {
      final list = _messages.putIfAbsent(sid, () => []);
      // Replace a streaming placeholder with the same id, else append.
      final idx = list.indexWhere((x) => x.id == m.id);
      if (idx >= 0) {
        list[idx] = m;
      } else {
        list.add(m);
      }
      notifyListeners();
    }, onError: (e) {
      error = e.toString();
      sending = false;
      notifyListeners();
    }, onDone: () {
      sending = false;
      _sub = null;
      // If notifications are enabled, ping when the assistant reply lands.
      if (config.notificationsEnabled) {
        final list = _messages[sid] ?? const [];
        final last = list.isNotEmpty ? list.last : null;
        if (last != null && last.isAssistant && last.text.trim().isNotEmpty) {
          final title = _sessionTitleFor(sid);
          NotificationsService.showReply(
            title,
            last.text.trim().length > 120
                ? '${last.text.trim().substring(0, 120)}…'
                : last.text.trim(),
          );
        }
      }
      notifyListeners();
      refreshSessions();
    });
  }

  String _sessionTitleFor(String sid) {
    for (final s in sessions) {
      if (s.id == sid) return s.title;
    }
    return 'Hermes';
  }

  // ---- controller / dashboard loaders -------------------------------
  Future<void> loadAll() async {
    busy = true;
    notifyListeners();
    await Future.wait([
      _safe(refreshServers),
      _safe(refreshSessions),
      _safe(loadCron),
      _safe(loadSkills),
      _safe(loadMemory),
      _safe(loadStatus),
      _safe(loadLogs),
      _safe(loadModels),
      _safe(loadActivities),
      _safe(loadCommands),
      _safe(loadWebhooks),
      _safe(loadGroups),
      _safe(loadBots),
      _safe(loadBotPets),
    ]);
    busy = false;
    notifyListeners();
  }

  Future<void> loadCron() async {
    cronJobs = await repo.cronJobs();
    notifyListeners();
  }

  Future<void> loadSkills() async {
    skills = await repo.skills();
    notifyListeners();
  }

  Future<void> loadMemory() async {
    memory = await repo.memoryEntries();
    userMemory = await repo.memoryEntries(category: 'user');
    notifyListeners();
  }

  Future<void> loadStatus() async {
    status = await repo.serverStatus();
    notifyListeners();
  }

  Future<void> loadLogs() async {
    logs = await repo.logs();
    notifyListeners();
  }

  Future<void> loadModels() async {
    models = await repo.modelHealth();
    notifyListeners();
  }

  Future<void> loadActivities() async {
    activities = await repo.toolActivities();
    notifyListeners();
  }

  Future<void> loadCommands() async {
    commands = await repo.commandPalette();
    notifyListeners();
  }

  Future<void> loadWebhooks() async {
    webhooks = await repo.webhooks();
    notifyListeners();
  }

  // ---- mutations that hit the repo then refresh ----------------------
  Future<void> addMemoryEntry(String category, String content) async {
    await repo.addMemory(category, content);
    await loadMemory();
  }

  Future<void> deleteMemoryEntry(String id) async {
    await repo.deleteMemory(id);
    await loadMemory();
  }

  Future<void> toggleSkillById(String id) async {
    await repo.toggleSkill(id);
    await loadSkills();
  }

  Future<void> createCron(CronJob job) async {
    await repo.createCronJob(job);
    await loadCron();
  }

  Future<void> updateCron(CronJob job) async {
    await repo.updateCronJob(job);
    await loadCron();
  }

  Future<void> deleteCron(String id) async {
    await repo.deleteCronJob(id);
    await loadCron();
  }

  Future<void> runCron(String id) async {
    await repo.runCronJob(id);
    await loadCron();
  }

  Future<void> triggerWebhookById(String id) async {
    await repo.triggerWebhook(id);
  }

  Color avatarColorFor(String sessionId) {
    final s = sessions.firstWhere(
      (x) => x.id == sessionId,
      orElse: () => ChatSession(
        id: sessionId,
        title: '?',
        lastPreview: '',
        lastTimestamp: DateTime.now(),
        profileId: '',
      ),
    );
    return s.avatarColor;
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}
