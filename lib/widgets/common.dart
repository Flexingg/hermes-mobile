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
