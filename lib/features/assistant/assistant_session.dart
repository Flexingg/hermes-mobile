import '../../core/config/app_config.dart';
import '../../data/app_repository.dart';
import '../../data/models.dart';

/// The floating assistant's own conversation.
///
/// Overlay turns must never post into a project chat or into whichever thread
/// the app last had open, so the overlay keeps one dedicated session and
/// remembers its id in [AppConfig].
class AssistantSession {
  static const sessionName = 'Assistant';

  /// Returns the dedicated assistant session id, reusing the one persisted in
  /// [config] when the server still has it, creating one otherwise.
  ///
  /// [sessions] can be passed when the caller already has a fresh list.
  static Future<String> ensure({
    required AppConfig config,
    required AppRepository repo,
    List<ChatSession>? sessions,
  }) async {
    final known = sessions ?? await repo.sessions();
    final saved = config.assistantSessionId;
    if (saved != null && known.any((s) => s.id == saved)) return saved;
    // Take the profile of an existing session when there is one; an empty id
    // leaves the choice to the bridge rather than inventing a profile here.
    final profileId = known.isEmpty ? '' : known.first.profileId;
    final created = await repo.createSession(sessionName, profileId);
    await config.setAssistantSessionId(created.id);
    return created.id;
  }
}
