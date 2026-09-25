import 'package:flutter/material.dart';

/// Circular avatar used for sessions/bots, Google-Messages style.
class Avatar extends StatelessWidget {
  final String label;
  final Color color;
  final double radius;
  final String? emoji;
  final String? imagePath;
  final bool hasUnread;

  const Avatar({
    super.key,
    required this.label,
    required this.color,
    this.radius = 22,
    this.emoji,
    this.imagePath,
    this.hasUnread = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: radius,
          backgroundColor: color,
          child: imagePath != null
              ? ClipOval(
                  child: Image.asset(
                    imagePath!,
                    fit: BoxFit.cover,
                    width: radius * 2,
                    height: radius * 2,
                    errorBuilder: (_, _, _) => Text(
                      label.isEmpty ? '?' : label[0].toUpperCase(),
                      style: TextStyle(
                        fontSize: radius * 0.85,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                )
              : emoji != null
                  ? Text(emoji!, style: TextStyle(fontSize: radius * 0.95))
                  : Text(
                      label.isEmpty ? '?' : label[0].toUpperCase(),
                      style: TextStyle(
                        fontSize: radius * 0.85,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
        ),
        if (hasUnread)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: radius * 0.8,
              height: radius * 0.8,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 2),
              ),
            ),
          ),
      ],
    );
  }
}

/// A thin helper widget showing an empty / loading state.
class StatusMessage extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  const StatusMessage({
    super.key,
    required this.title,
    this.subtitle,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: scheme.outlineVariant),
            const SizedBox(height: 16),
            Text(title,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle!,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                  textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }
}

/// Persistent error strip shown at the top of the shell.
///
/// Every loader in [AppState] used to swallow its failure (`catch (_) {}`), so a
/// dead bridge, a 401 and a route that does not exist all looked like "nothing
/// happened". This renders the failure text the bridge actually sent, with a
/// dismiss action and an expandable list of recent failures.
class ErrorBanner extends StatelessWidget {
  final String message;
  final List<String> log;
  final VoidCallback onDismiss;

  const ErrorBanner({
    super.key,
    required this.message,
    required this.onDismiss,
    this.log = const [],
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: scheme.onErrorContainer, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
                ),
              ),
              if (log.length > 1)
                TextButton(
                  onPressed: () => _showLog(context),
                  child: Text('Log (${log.length})',
                      style: TextStyle(color: scheme.onErrorContainer)),
                ),
              IconButton(
                tooltip: 'Dismiss',
                icon: Icon(Icons.close, color: scheme.onErrorContainer, size: 20),
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showLog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Recent failures'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: log.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(log[i], style: const TextStyle(fontSize: 12)),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }
}
