import 'models.dart';

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
  Stream<ChatMessage> sendMessage(String sessionId, String text);
  Future<void> markRead(String sessionId);
  Future<void> togglePinned(String sessionId);
  Future<void> toggleStarred(String sessionId);
  Future<void> deleteSession(String sessionId);
  Future<List<ChatSession>> searchSessions(String query);

  // ---- Push notifications -------------------------------------------
  /// Registers this device's FCM token with the bridge so it can push to us.
  Future<void> registerDevice(String token);
  Future<void> sendTestPush({String? title, String? message});

  // ---- Cron jobs -----------------------------------------------------
  Future<List<CronJob>> cronJobs();
  Future<CronJob> createCronJob(CronJob job);
  Future<void> updateCronJob(CronJob job);
  Future<void> deleteCronJob(String id);
  Future<CronJob> runCronJob(String id);

  // ---- Skills --------------------------------------------------------
  Future<List<Skill>> skills();
  Future<void> toggleSkill(String id);

  // ---- Memory --------------------------------------------------------
  Future<List<MemoryEntry>> memoryEntries({String? category});
  Future<MemoryEntry> addMemory(String category, String content);
  Future<void> deleteMemory(String id);
  Future<List<MemoryEntry>> searchMemory(String query);

  // ---- Dashboard -----------------------------------------------------
  Future<ServerStatus> serverStatus();
  Future<List<LogEntry>> logs({int limit = 100});
  Future<List<ModelHealth>> modelHealth();

  // ---- Tools / activity ---------------------------------------------
  Future<List<ToolActivity>> toolActivities({String? sessionId});
  Future<List<String>> toolCatalog();

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
