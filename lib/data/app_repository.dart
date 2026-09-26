import 'models.dart';
import 'project_models.dart';

/// The single source of truth interface the whole app talks to.
///
/// [HermesRepository] is the only implementation — it connects to a real
/// Hermes bridge server over HTTP/WebSocket. The app requires a verified
/// server connection before any data is shown.
abstract class AppRepository {
  // ---- Servers & bots ------------------------------------------------
  Future<List<ServerProfile>> servers();
  Future<ServerProfile> addServer(ServerProfile profile);
  Future<void> updateServer(ServerProfile profile);
  Future<void> removeServer(String id);

  // ---- Sessions / chat ----------------------------------------------
  Future<List<ChatSession>> sessions();
  Future<List<ChatMessage>> messages(String sessionId);
  Future<ChatSession> createSession(String title, String profileId);
  /// Starts a real new conversation: the bridge runs `hermes chat` to create a
  /// genuine session and returns it (first message already sent).
  Future<ChatSession> startNewChat({
    required String name,
    required String text,
  });
  /// Sends a message and returns a stream of the assistant reply as it streams.
  /// In a project chat, [mode] 'plan' makes it a read-only Plan-mode turn that
  /// ends in an issue draft; [project]/[profile] say whose chat it is.
  Stream<ChatMessage> sendMessage(String sessionId, String text,
      {List<Attachment> attachments = const [],
      String? mode,
      String? project,
      String? profile});
  /// Uploads an image/file to the bridge so the agent can use it.
  Future<Attachment> uploadAttachment({
    required String localPath,
    required String name,
    String? mimeType,
  });
  /// Downloads a file from the bridge by path, streaming it to a local temp
  /// file. Returns the local file path on the device.
  Future<String> downloadFile(String serverPath);

  /// Web URL that serves an agent-produced file as an in-app preview
  /// (HTML/CSS/JS render interactively; relative assets resolve on the bridge).
  String previewUrl(String filePath);
  Future<void> markRead(String sessionId);
  Future<void> togglePinned(String sessionId);
  Future<void> toggleStarred(String sessionId);
  Future<void> deleteSession(String sessionId);
  Future<List<ChatSession>> searchSessions(String query);

  // ---- Groups (multi-agent chat) ------------------------------------
  Future<List<GroupChat>> groups();
  Future<GroupChat> createGroup({
    required String name,
    required List<String> agents,
  });
  Future<List<ChatMessage>> groupMessages(String gid);
  /// Sends to every agent in a group; streams each agent's tagged reply.
  Stream<ChatMessage> sendGroupMessage(String gid, String text);
  Future<void> deleteGroup(String gid);

  // ---- Bots (Hermes profiles) ----
  Future<List<Bot>> bots();
  Future<List<String>> botPets();
  Future<Bot> createBot({required String name, String? description});
  Future<Bot> updateBot(String id,
      {String? description, String? pet, String? soul});
  Future<void> deleteBot(String id);

  // ---- Push notifications -------------------------------------------
  /// Registers this device's FCM token with the bridge so it can push to us.
  Future<void> registerDevice(String token);
  Future<void> sendTestPush({String? title, String? message});

  // ---- Remote terminal ----------------------------------------------
  /// Runs a command on the host PC and returns its output.
  Future<TerminalResult> runCommand(String command,
      {String? cwd, int? timeout});

  // ---- Cron jobs -----------------------------------------------------
  Future<List<CronJob>> cronJobs();
  Future<CronJob> createCronJob(CronJob job);
  Future<void> updateCronJob(CronJob job);
  Future<void> deleteCronJob(String id);
  Future<void> runCronJob(String id);

  // ---- Skills --------------------------------------------------------
  Future<List<Skill>> skills();
  Future<void> toggleSkill(String id);

  // ---- Memory (a project's agent has its own: pass its [profile]) -------
  Future<List<MemoryEntry>> memoryEntries({String? category, String? profile});
  Future<MemoryEntry> addMemory(String category, String content, {String? profile});
  Future<void> deleteMemory(String id, {String? profile});
  Future<List<MemoryEntry>> searchMemory(String query);

  // ---- Dashboard -----------------------------------------------------
  Future<ServerStatus> serverStatus();
  Future<List<LogEntry>> logs({int limit = 100});
  Future<List<ModelHealth>> modelHealth();

  // ---- Tools / activity ---------------------------------------------
  Future<List<ToolActivity>> toolActivities({String? sessionId});
  Future<List<String>> toolCatalog();

  // ---- Projects --------------------------------------------------------
  // Hermes orchestrates projects. These read what it recorded and relay the
  // user's requests to it; none of them act on GitHub or the boards directly.
  Future<List<Project>> projects();
  /// One project, with its tasks.
  Future<Project> project(String id);
  /// The project agent's own chats (Chat and Plan).
  Future<List<ChatSession>> projectSessions(String id);
  Future<List<GithubRepo>> githubRepos();
  Future<AgentSnapshot> agents();
  /// The orchestrator's chat (the pinned "Hermes" conversation).
  Future<String> orchestratorSession();
  /// Ask Hermes to do something (link a repo, file an issue, retry a task…).
  /// Hermes answers in its chat; the reply comes back here too.
  Future<IntentResult> intent(String kind,
      {String? project, String? sessionId, Map<String, dynamic>? payload});
  Future<List<ProjectEvent>> events({String? since});

  // ---- Command palette / webhooks -----------------------------------
  Future<List<CommandItem>> commandPalette();
  Future<List<WebhookRoute>> webhooks();
  Future<void> triggerWebhook(String id);
}

/// A slash-command / quick action shown in the palette.
class CommandItem {
  final String id;
  final String label;
  final String description;
  final String icon; // icon name key
  const CommandItem({
    required this.id,
    required this.label,
    required this.description,
    required this.icon,
  });
}

/// A Hermes webhook route that can be fired from a button.
class WebhookRoute {
  final String id;
  final String name;
  final String description;
  final bool enabled;
  const WebhookRoute({
    required this.id,
    required this.name,
    required this.description,
    this.enabled = true,
  });
}
