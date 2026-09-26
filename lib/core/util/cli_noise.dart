/// Hermes' CLI chrome is not the agent talking.
///
/// `hermes chat` prints a session banner around the reply ("Session `id` found
/// but has no messages. Starting fresh.", a "Resume this session with:" hint and
/// a "Title:/Duration:/Messages:" summary). The bridge strips it server-side and
/// sends the facts as a `session_meta` event instead; these functions are the
/// app-side guard, so an older bridge (or a path that doesn't scrub) can never
/// put plumbing text in a bubble as if the assistant had said it.
library;

final RegExp _ansi = RegExp(r'\x1b\[[0-9;]*[a-zA-Z]');

const List<String> _prefixes = [
  'Query:',
  'Initializing agent',
  'Session:',
  'session_id:',
  'Title:',
  'Duration:',
  'Messages:',
  'Tools:',
  'Model:',
  'Profile:',
  'Tokens:',
  'Resume with:',
  'Resume this session with:',
  'Connected to',
  '🔗',
];

final List<RegExp> _patterns = [
  RegExp(r'^Session\s+\S+\s+found but has no messages'),
  RegExp(r'^attaching\s+\d+\s+image\(s\)'),
  RegExp(r'^hermes\s+(--resume|-c)\b'),
  RegExp(r'^\d+\s*\(\d+\s+user.*tool call'),
  RegExp(r'^\S+\s+·\s+\d+s$'),
  // The bare filename the "attaching N image(s)" banner wraps onto, e.g.
  // "ac095b29_scaled_….jpg" on its own line. A line that is only a filename is a
  // file reference (the app shows those as chips), never the agent's prose.
  RegExp(r'^[\w.\-]+\.(png|jpe?g|gif|webp|bmp|heic|pdf|txt|md|csv|json|apk|zip)$',
      caseSensitive: false),
];

/// True for one line of Hermes CLI chrome — never shown as the agent's words.
bool isPlumbingLine(String line) {
  final s = line.replaceAll(_ansi, '').trim();
  if (s.isEmpty) return false;
  for (final p in _prefixes) {
    if (s.startsWith(p)) return true;
  }
  for (final r in _patterns) {
    if (r.hasMatch(s)) return true;
  }
  return false;
}

/// [text] with Hermes' CLI chrome removed.
String stripPlumbing(String text) {
  final kept = text
      .replaceAll(_ansi, '')
      .split('\n')
      .where((l) => !isPlumbingLine(l))
      .toList();
  return kept.join('\n').trim();
}

/// Everything in [text] that is CLI chrome (for tests and diagnostics).
List<String> plumbingLines(String text) => text
    .replaceAll(_ansi, '')
    .split('\n')
    .where(isPlumbingLine)
    .toList();

/// The session facts a banner carries, as `label -> value` (lowercased labels).
///
/// Used when the reply arrives as raw text rather than as a `session_meta`
/// event. Empty when there was no banner.
Map<String, String> parseSessionMeta(String text) {
  const keys = {
    'session': 'sessionId',
    'session_id': 'sessionId',
    'title': 'title',
    'duration': 'duration',
    'messages': 'messages',
    'model': 'model',
    'profile': 'profile',
  };
  final meta = <String, String>{};
  for (final raw in text.replaceAll(_ansi, '').split('\n')) {
    final s = raw.trim();
    final fresh = RegExp(r'^Session\s+(\S+)\s+found but has no messages').firstMatch(s);
    if (fresh != null) {
      meta.putIfAbsent('sessionId', () => fresh.group(1)!);
      meta.putIfAbsent('note', () => 'no messages in this session yet — started fresh');
      continue;
    }
    final cmd = RegExp(r'^hermes\s+--resume\s+(\S+)').firstMatch(s);
    if (cmd != null) {
      meta['resumeCommand'] = 'hermes --resume ${cmd.group(1)}';
      meta.putIfAbsent('sessionId', () => cmd.group(1)!);
      continue;
    }
    final kv = RegExp(r'^([A-Za-z_]+):\s*(.+)$').firstMatch(s);
    if (kv != null) {
      final key = keys[kv.group(1)!.trim().toLowerCase()];
      if (key != null) meta.putIfAbsent(key, () => kv.group(2)!.trim());
    }
  }
  final sid = meta['sessionId'];
  if (sid != null) meta.putIfAbsent('resumeCommand', () => 'hermes --resume $sid');
  return meta;
}
