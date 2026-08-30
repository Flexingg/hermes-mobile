/// Relative-time + formatting helpers.
library;

String formatRelativeTime(DateTime time, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final diff = n.difference(time);
  if (diff.inSeconds < 60) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays == 1) return 'yesterday';
  if (diff.inDays < 7) return '${diff.inDays}d';
  // Older than a week: show date.
  final two = _two;
  return '${two(time.month)}/${two(time.day)}/${two(time.year % 100)}';
}

String formatFullTime(DateTime time) {
  final two = _two;
  final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
  final ampm = time.hour < 12 ? 'AM' : 'PM';
  return '${two(time.month)}/${two(time.day)}/${two(time.year % 100)} · $hour:${two(time.minute)} $ampm';
}

String formatClock(DateTime time) {
  final two = _two;
  final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
  final ampm = time.hour < 12 ? 'AM' : 'PM';
  return '$hour:${two(time.minute)} $ampm';
}

String _two(int v) => v.toString().padLeft(2, '0');
