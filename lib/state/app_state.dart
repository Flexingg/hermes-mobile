import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import '../core/config/app_config.dart';
import '../data/app_repository.dart';
import '../data/demo_repository.dart';
import '../data/hermes_repository.dart';
import '../data/models.dart';

/// Central reactive store driving the UI. Pages watch this notifier and call
/// its methods; it owns the repository instance and streaming subscriptions.
class AppState extends ChangeNotifier {
  final AppConfig config;
  late AppRepository repo;

  // ---- chat / sessions ----
  List<ChatSession> sessions = [];
  final Map<String, List<ChatMessage>> _messages = {};
  String? activeSessionId;
  bool sending = false;
  StreamSubscription<ChatMessage>? _sub;

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

  AppState(this.config) {
    repo = config.demoMode
        ? DemoRepository()
        : HermesRepository(baseUrl: _defaultBase, token: _defaultToken);
  }

  static const _defaultBase = 'http://192.168.1.146:9119';
  static const _defaultToken = ''; // set via UI / settings later

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

  Future<void> toggleStarred(String id) async {
    await repo.toggleStarred(id);
    await refreshSessions();
  }

  Future<void> sendMessage(String text) async {
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
    );
    _messages.putIfAbsent(sid, () => []).add(userMsg);
    notifyListeners();

    await _sub?.cancel();
    _sub = repo.sendMessage(sid, text).listen((m) {
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
      notifyListeners();
      refreshSessions();
    });
  }

  // ---- controller / dashboard loaders -------------------------------
  Future<void> loadAll() async {
    busy = true;
    notifyListeners();
    await Future.wait([
      refreshServers(),
      refreshSessions(),
      loadCron(),
      loadSkills(),
      loadMemory(),
      loadStatus(),
      loadLogs(),
      loadModels(),
      loadActivities(),
      loadCommands(),
      loadWebhooks(),
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
    _sub?.cancel();
    super.dispose();
  }
}
