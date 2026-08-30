import '../data/models.dart';

/// Resolves the agent/bot a session is with — used to pick its pet avatar.
String resolveAgentName(List<ServerProfile> servers, ChatSession s) {
  for (final server in servers) {
    for (final b in server.bots) {
      if (b.id == s.profileId) return b.name;
    }
  }
  final t = s.title;
  if (t.startsWith('@')) return t;
  return 'Hermes';
}

/// Maps an agent/bot name to a bundled pet image asset. Each agent gets its
/// own pet so avatars differ per conversation. Falls back to `boba`.
String petAssetForAgent(String agentName) {
  final a = agentName.toLowerCase();
  if (a.contains('boba')) return 'assets/pets/boba.png';
  if (a.contains('patrick') || a.contains('buff')) return 'assets/pets/scoop.png';
  if (a.contains('homie') || a.contains('home')) return 'assets/pets/boxcat.png';
  if (a.contains('hermes') || a.contains('nous')) return 'assets/pets/cosmo.png';
  if (a.contains('financ')) return 'assets/pets/cash-cuy.png';
  return 'assets/pets/boba.png';
}
