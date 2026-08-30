import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/format.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';

/// A single chat bubble, styled like Google Messages:
///  - sent (user) → tinted bubble, right-aligned, tight corner top-right
///  - received (assistant) → surface bubble, left-aligned with avatar
///  - tool → monospace pill showing a tool call
///  - system → centered caption
class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final Color? avatarColor;
  final String? avatarEmoji;

  const MessageBubble({
    super.key,
    required this.message,
    this.avatarColor,
    this.avatarEmoji,
  });

  @override
  Widget build(BuildContext context) {
    switch (message.role) {
      case ChatMessageRole.user:
        return _SentBubble(message: message);
      case ChatMessageRole.assistant:
        return _ReceivedBubble(
          message: message,
          avatarColor: avatarColor,
          avatarEmoji: avatarEmoji,
        );
      case ChatMessageRole.tool:
        return _ToolBubble(message: message);
      case ChatMessageRole.system:
        return _SystemBubble(message: message);
    }
  }
}

class _SentBubble extends StatelessWidget {
  final ChatMessage message;
  const _SentBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<HermesColors>() ??
        const HermesColors(
            sentBubble: Color(0xFFE7FEDB),
            sentBubbleText: Color(0xFF001C06),
            receivedBubble: Colors.white);
    final bubbleColor = colors.sentBubble;
    final textColor = colors.sentBubbleText;
    final r = colors.bubbleRadius;

    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(top: 4, bottom: 4, left: 72),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(r),
            topRight: Radius.circular(r * 0.33),
            bottomLeft: Radius.circular(r),
            bottomRight: Radius.circular(r),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            _SelectableText(
                message.text, style: TextStyle(color: textColor, fontSize: 15)),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(formatClock(message.timestamp),
                    style: TextStyle(
                        fontSize: 11,
                        color: textColor.withValues(alpha: 0.55))),
                const SizedBox(width: 3),
                Icon(Icons.done_all,
                    size: 14,
                    color: textColor.withValues(alpha: 0.55)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReceivedBubble extends StatelessWidget {
  final ChatMessage message;
  final Color? avatarColor;
  final String? avatarEmoji;
  const _ReceivedBubble({
    required this.message,
    this.avatarColor,
    this.avatarEmoji,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = Theme.of(context).extension<HermesColors>();
    final bubbleColor = colors?.receivedBubble ??
        (Theme.of(context).brightness == Brightness.dark
            ? scheme.surfaceContainerHighest
            : Colors.white);
    final isStreaming =
        message.status == ChatMessageStatus.streaming;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 8),
            child: Avatar(
              label: '',
              color: avatarColor ?? scheme.primary,
              emoji: avatarEmoji,
              radius: 16,
            ),
          ),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(colors?.bubbleRadius ?? 18 * 0.33),
                  topRight: Radius.circular(colors?.bubbleRadius ?? 18),
                  bottomLeft: Radius.circular(colors?.bubbleRadius ?? 18),
                  bottomRight: Radius.circular(colors?.bubbleRadius ?? 18),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isStreaming && message.text.isEmpty)
                    const _TypingIndicator()
                  else if (isStreaming)
                    MarkdownBody(
                      data: '${message.text}▌',
                      selectable: true,
                      styleSheet: _mdStyle(context),
                    )
                  else
                    MarkdownBody(
                      data: message.text,
                      selectable: true,
                      styleSheet: _mdStyle(context),
                    ),
                  const SizedBox(height: 2),
                  Text(formatClock(message.timestamp),
                      style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.7))),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  MarkdownStyleSheet _mdStyle(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: const TextStyle(fontSize: 15, height: 1.35),
      code: TextStyle(
        fontFamily: 'monospace',
        fontSize: 13,
        color: scheme.onSurface,
        backgroundColor: scheme.surfaceContainerHighest,
      ),
      codeblockDecoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      blockquoteDecoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }
}

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat();
  late final Animation<double> _a =
      CurvedAnimation(parent: _c, curve: Curves.easeInOut);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _a,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = (_a.value + i * 0.2) % 1.0;
            final scale = 0.4 + 0.6 * (1 - (phase - 0.5).abs() * 2);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Opacity(
                opacity: 0.4 + 0.6 * phase,
                child: Transform.scale(
                  scale: scale,
                  child: const CircleAvatar(radius: 3),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class _ToolBubble extends StatefulWidget {
  final ChatMessage message;
  const _ToolBubble({required this.message});

  @override
  State<_ToolBubble> createState() => _ToolBubbleState();
}

class _ToolBubbleState extends State<_ToolBubble> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final config = context.watch<AppConfig>();
    final showAll = config.showTechnical;
    final visible = showAll || _expanded;
    final toolName = widget.message.toolName ?? 'tool';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 40),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        borderRadius: BorderRadius.circular(12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.handyman_outlined, size: 15, color: scheme.tertiary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                visible ? widget.message.text : toolName,
                maxLines: visible ? null : 1,
                overflow: visible ? null : TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              visible ? Icons.expand_less : Icons.expand_more,
              size: 15,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _SystemBubble extends StatelessWidget {
  final ChatMessage message;
  const _SystemBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 32),
      child: Text(
        message.text,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

class _SelectableText extends StatelessWidget {
  final String text;
  final TextStyle style;
  const _SelectableText(this.text, {required this.style});

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: Text(text, style: style),
    );
  }
}
