import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import '../core/config/app_config.dart';
import '../core/notifications/notifications.dart';
import '../core/notifications/push.dart';
import '../data/app_repository.dart';
import '../data/hermes_repository.dart';
import '../data/models.dart';
import '../data/project_models.dart';

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

  // ---- Projects (Hermes orchestrates; this mirrors what it recorded) ----
  List<Project> projects = [];
  final Map<String, Project> _projectDetail = {};
  final Map<String, List<ChatSession>> _projectSessions = {};
  final Map<String, List<MemoryEntry>> _projectMemory = {};
  List<GithubRepo> githubRepos = [];
  AgentSnapshot? agents;
  String? orchestratorSessionId;
  // Requests Hermes is still working on (keys like 'link:owner/repo'), so the
  // UI can show progress on the right button instead of a global spinner.
  final Set<String> _pendingIntents = {};
  // Plan drafts that were filed: message id -> Hermes' reply ("Filed #42 …").
  final Map<String, String> _filedDrafts = {};

  Project? projectDetail(String id) => _projectDetail[id];
  Project? projectById(String id) {
    for (final p in projects) {
      if (p.id == id) return p;
    }
    return _projectDetail[id];
  }

  List<ChatSession> projectSessionsFor(String id) => _projectSessions[id] ?? const [];
  List<MemoryEntry> projectMemoryFor(String profile) => _projectMemory[profile] ?? const [];
  bool intentPending(String key) => _pendingIntents.contains(key);
  String? filedDraftReply(String messageId) => _filedDrafts[messageId];

  bool busy = false;
  String? error;
  bool _disposed = false;

  /// Bounded ring of recent failures, newest first — the in-app answer to
  /// "nothing happened". Only paths, status codes and the server's own message
  /// go in here: never a token, a URL carrying one, or a response body.
  static const int maxErrorLog = 50;
  final List<String> _errorLog = [];
  List<String> get errorLog => List.unmodifiable(_errorLog);

  /// Surface a failure instead of swallowing it. Sets [error] (the banner) and
  /// appends to the bounded log.
  void reportError(Object e, {String? context}) {
    final msg = context == null ? e.toString() : '$context: $e';
    error = msg;
    _errorLog.insert(0, '${DateTime.now().toIso8601String()}  $msg');
    if (_errorLog.length > maxErrorLog) {
      _errorLog.removeRange(maxErrorLog, _errorLog.length);
    }
    notifyListeners();
  }

  void clearError() {
    if (error == null && _errorLog.isEmpty) return;
    error = null;
    _errorLog.clear();
    notifyListeners();
  }

  /// Run a UI-triggered action and surface its failure.
  ///
  /// Every one of these call sites used to be `onPressed: () => state.doThing()`
  /// — an unawaited future with no error handler, so a 400/404/405 from the
  /// bridge produced no message anywhere: the row just reappeared or the dialog
  /// stayed open. Use this at every widget callback that mutates server state.
  Future<void> guard(Future<void> Function() job, {required String context}) async {
    try {
      await job();
    } catch (e) {
      reportError(e, context: context);
    }
  }

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
      } catch (e) {
        // A missing/broken push registration must never block chat — but it
        // must not vanish either.
        reportError(e, context: 'push registration');
      }
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
      reportError(e);
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
    projects = [];
    _projectDetail.clear();
    _projectSessions.clear();
    _projectMemory.clear();
    githubRepos = [];
    agents = null;
    orchestratorSessionId = null;
    notifyListeners();
  }

  List<ChatMessage> messagesFor(String sessionId) =>
      _messages[sessionId] ?? [];

  // ---- bootstrap / refresh ------------------------------------------
  Future<void> refreshServers() async {
    try {
      servers = await repo.servers();
    } catch (e) {
      reportError(e, context: 'load servers');
    }
    notifyListeners();
  }

  Future<void> refreshSessions() async {
    try {
      sessions = await repo.sessions();
    } catch (e) {
      reportError(e, context: 'load sessions');
    }
    notifyListeners();
  }

  /// True for messages that only exist on-device (optimistic, streaming,
  /// sending). These must be preserved across a server reload so an in-flight
  /// reply isn't clobbered by a refetch.
  bool _isEphemeral(String id) =>
      id.startsWith('u-') ||
      id.startsWith('live-') ||
      id.startsWith('opt-') ||
      id.startsWith('g-live-');

  /// Reload a session's messages from the server, keeping any local ephemeral
  /// messages (optimistic user text, in-flight streaming reply) that the
  /// server hasn't persisted yet. Fires when called, even if the cache exists —
  /// this is what prevents a stale thread after a pushed/background reply.
  Future<void> refreshThread(String sid) async {
    try {
      final fresh = await repo.messages(sid);
      final existing = _messages[sid] ?? const <ChatMessage>[];
      final ephemeral = existing
          .where((m) => _isEphemeral(m.id) && !fresh.any((f) => f.id == m.id))
          .toList();
      _messages[sid] = [...fresh, ...ephemeral];
    } catch (e) {
      // Keep whatever we already had; never disconnect on a reload failure —
      // but say so, so a dead bridge is not an empty thread with no message.
      reportError(e, context: 'reload thread');
    }
    notifyListeners();
  }

  Future<void> openSession(String id) async {
    activeSessionId = id;
    await repo.markRead(id);
    await refreshThread(id); // always reload, not just when the cache is empty
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
    } catch (e) {
      reportError(e, context: 'load groups');
    }
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
    } catch (e) {
      reportError(e, context: 'open group');
    }
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
    final gWatchdog = Timer(const Duration(seconds: 150), () {
      if (groupSending) {
        groupSending = false;
        _groupSub?.cancel();
        _reloadGroupThread(gid);
      }
    });
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
        gWatchdog.cancel();
        error = e.toString();
        groupSending = false;
        _reloadGroupThread(gid);
      },
      onDone: () {
        gWatchdog.cancel();
        groupSending = false;
        _reloadGroupThread(gid);
      },
    );
  }

  Future<void> _reloadGroupThread(String gid) async {
    try {
      _groupMessages[gid] = await repo.groupMessages(gid);
    } catch (e) {
      reportError(e, context: 'reload group');
    }
    await loadGroups();
    notifyListeners();
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
    } catch (e) {
      reportError(e, context: 'load bots');
    }
  }

  Future<void> loadBotPets() async {
    try {
      _botPets = await repo.botPets();
      notifyListeners();
    } catch (e) {
      reportError(e, context: 'load pets');
    }
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

  /// [mode]/[project]/[profile] are set in a project chat ('plan' = Plan mode).
  Future<void> sendMessage(String text,
      {List<Attachment> attachments = const [],
      String? mode,
      String? project,
      String? profile}) async {
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
    // Watchdog: if the stream never completes (e.g. WS hang), force a reload
    // from the server so the reply appears and the list refreshes without a
    // full app restart.
    final watchdog = Timer(const Duration(seconds: 150), () {
      if (sending) {
        sending = false;
        _sub?.cancel();
        _reloadThread(sid);
      }
    });
    _sub = repo
        .sendMessage(sid, text,
            attachments: attachments, mode: mode, project: project, profile: profile)
        .listen((m) {
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
      watchdog.cancel();
      error = e.toString();
      sending = false;
      _reloadThread(sid);
    }, onDone: () {
      watchdog.cancel();
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

  /// Reload a thread's messages from the server and refresh the session list.
  Future<void> _reloadThread(String sid) async {
    try {
      _messages[sid] = await repo.messages(sid);
    } catch (e) {
      reportError(e, context: 'reload thread');
    }
    await refreshSessions();
    notifyListeners();
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
      _safe(loadProjects),
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

  // ---- Projects --------------------------------------------------------
  Future<void> loadProjects() async {
    try {
      projects = await repo.projects();
    } catch (e) {
      reportError(e, context: 'load projects');
    }
    notifyListeners();
  }

  Future<void> loadProject(String id) async {
    try {
      final p = await repo.project(id);
      _projectDetail[id] = p;
      final i = projects.indexWhere((x) => x.id == id);
      if (i >= 0) projects[i] = p;
    } catch (e) {
      reportError(e, context: 'load project');
    }
    notifyListeners();
  }

  Future<void> loadProjectSessions(String id) async {
    try {
      _projectSessions[id] = await repo.projectSessions(id);
    } catch (e) {
      reportError(e, context: 'load project chats');
    }
    notifyListeners();
  }

  Future<void> loadGithubRepos() async {
    try {
      githubRepos = await repo.githubRepos();
    } catch (e) {
      reportError(e, context: 'load GitHub repos');
    }
    notifyListeners();
  }

  Future<void> loadAgents() async {
    try {
      agents = await repo.agents();
    } catch (e) {
      reportError(e, context: 'load agents');
    }
    notifyListeners();
  }

  /// The orchestrator's chat, created by the bridge on first use.
  Future<String?> openOrchestrator() async {
    try {
      orchestratorSessionId = await repo.orchestratorSession();
      notifyListeners();
      return orchestratorSessionId;
    } catch (e) {
      reportError(e, context: 'open Hermes');
      return null;
    }
  }

  /// A new chat with a project's agent (stored in that agent's own history).
  Future<String?> createProjectChat(Project p, String title) async {
    try {
      final s = await repo.createSession(title, p.profile);
      await loadProjectSessions(p.id);
      return s.id;
    } catch (e) {
      reportError(e, context: 'new project chat');
      return null;
    }
  }

  /// Ask Hermes to act, tracking [key] as pending while it works. Returns its
  /// reply, or null if the request failed (the failure is reported).
  Future<String?> _intent(String key, String kind,
      {String? project, String? sessionId, Map<String, dynamic>? payload}) async {
    if (_pendingIntents.contains(key)) return null;
    _pendingIntents.add(key);
    notifyListeners();
    try {
      final r = await repo.intent(kind, project: project, sessionId: sessionId, payload: payload);
      return r.reply;
    } catch (e) {
      reportError(e, context: 'ask Hermes ($kind)');
      return null;
    } finally {
      _pendingIntents.remove(key);
      notifyListeners();
      unawaited(loadProjects());
      if (project != null) unawaited(loadProject(project));
    }
  }

  Future<String?> linkRepo(String repoName, {String coder = 'claude'}) =>
      _intent('link:$repoName', 'link_repo', payload: {'repo': repoName, 'coder': coder});

  Future<String?> setProject(String id, {String? coder, String? gates}) =>
      _intent('set:$id', 'set_project', project: id,
          payload: {'coder': ?coder, 'gates': ?gates});

  Future<String?> unlinkProject(String id) async {
    final r = await _intent('unlink:$id', 'unlink', project: id);
    if (r != null) _projectDetail.remove(id);
    return r;
  }

  Future<String?> retryTask(String project, String task) =>
      _intent('task:$task', 'retry_task', project: project, payload: {'task': task});

  Future<String?> cancelTask(String project, String task) =>
      _intent('task:$task', 'cancel_task', project: project, payload: {'task': task});

  Future<String?> pauseAll() => _intent('pause', 'pause');
  Future<String?> resumeAll() => _intent('resume', 'resume');

  /// "Create issue" on a Plan draft: the project agent that drafted it files it.
  Future<String?> fileIssue(Project p, String sessionId, String messageId, IssueDraft draft) async {
    final reply = await _intent('file:$messageId', 'file_issue',
        project: p.id, sessionId: sessionId, payload: {'draft': draft.toJson()});
    if (reply != null) {
      _filedDrafts[messageId] = reply;
      notifyListeners();
      unawaited(refreshThread(sessionId));
    }
    return reply;
  }

  Future<void> loadProjectMemory(String profile) async {
    try {
      _projectMemory[profile] = await repo.memoryEntries(profile: profile);
    } catch (e) {
      reportError(e, context: 'load project memory');
    }
    notifyListeners();
  }

  Future<void> addProjectMemory(String profile, String content) async {
    await repo.addMemory('memory', content, profile: profile);
    await loadProjectMemory(profile);
  }

  Future<void> deleteProjectMemory(String profile, String id) async {
    await repo.deleteMemory(id, profile: profile);
    await loadProjectMemory(profile);
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
