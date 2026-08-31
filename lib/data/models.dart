import 'dart:ui';

/// Core domain models for the Hermes mobile controller.
/// These are plain immutable value objects shared across the app.

/// A single chat message within a session.
enum ChatMessageStatus { sending, streaming, sent, error }

enum ChatMessageRole { user, assistant, system, tool }

/// What kind of content a streamed assistant message holds. Lets the UI
/// separate the final answer from Hermes' thinking and tool/status noise.
enum ChatMessageType { answer, thinking, technical }

class Attachment {
  final String name;
  final String url;
  final String mimeType;
  final int? sizeBytes;
  final String? path; // server path (uploads / agent-produced) for sending + download
  final String? kind; // 'image' | 'file'
  final String? localPath; // local cached copy (for previews)
  const Attachment({
    required this.name,
    required this.url,
    required this.mimeType,
    this.sizeBytes,
    this.path,
    this.kind,
    this.localPath,
  });
}

class ChatMessage {
  final String id;
  final String sessionId;
  final ChatMessageRole role;
  final String text;
  final DateTime timestamp;
  final List<Attachment> attachments;
  final ChatMessageStatus status;
  final String? toolName; // for role == tool
  final String? agent; // for group chats: which agent produced this message
  final ChatMessageType type; // for streamed assistant content

  const ChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.text,
    required this.timestamp,
    this.attachments = const [],
    this.status = ChatMessageStatus.sent,
    this.toolName,
    this.agent,
    this.type = ChatMessageType.answer,
  });

  bool get isUser => role == ChatMessageRole.user;
  bool get isAssistant => role == ChatMessageRole.assistant;

  ChatMessage copyWith({
    String? text,
    ChatMessageStatus? status,
  }) {
    return ChatMessage(
      id: id,
      sessionId: sessionId,
      role: role,
      text: text ?? this.text,
      timestamp: timestamp,
      attachments: attachments,
      status: status ?? this.status,
      toolName: toolName,
      agent: agent,
      type: type,
    );
  }
}

/// A conversation/session thread.
class ChatSession {
  final String id;
  final String title;
  final String lastPreview;
  final DateTime lastTimestamp;
  final int unreadCount;
  final bool pinned;
  final bool starred;
  final String profileId;
  final Color avatarColor;

  const ChatSession({
    required this.id,
    required this.title,
    required this.lastPreview,
    required this.lastTimestamp,
    required this.profileId,
    this.unreadCount = 0,
    this.pinned = false,
    this.starred = false,
    this.avatarColor = const Color(0xFF6750A4),
  });

  ChatSession copyWith({
    String? lastPreview,
    DateTime? lastTimestamp,
    int? unreadCount,
    bool? pinned,
    bool? starred,
  }) {
    return ChatSession(
      id: id,
      title: title,
      lastPreview: lastPreview ?? this.lastPreview,
      lastTimestamp: lastTimestamp ?? this.lastTimestamp,
      unreadCount: unreadCount ?? this.unreadCount,
      pinned: pinned ?? this.pinned,
      starred: starred ?? this.starred,
      profileId: profileId,
      avatarColor: avatarColor,
    );
  }
}

/// A multi-agent group conversation (fan-out to several agents).
class GroupChat {
  final String id;
  final String name;
  final List<String> agents;
  final String lastPreview;
  final DateTime lastTimestamp;
  final int messageCount;
  const GroupChat({
    required this.id,
    required this.name,
    required this.agents,
    required this.lastPreview,
    required this.lastTimestamp,
    this.messageCount = 0,
  });
}

/// A Hermes agent/bot (a Hermes profile) manageable from the app.
class Bot {
  final String id;
  final String name;
  final String description;
  final String? model;
  final String? provider;
  final String? pet;
  final String soul;
  final bool isDefault;

  const Bot({
    required this.id,
    required this.name,
    required this.description,
    this.model,
    this.provider,
    this.pet,
    this.soul = '',
    this.isDefault = false,
  });
}

/// A connected Hermes server (gateway).
class ServerProfile {
  final String id;
  final String name;
  final String baseUrl;
  final bool isDefault;
  final Color accentColor;
  final List<BotProfile> bots;

  const ServerProfile({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.bots,
    this.isDefault = false,
    this.accentColor = const Color(0xFF6750A4),
  });

  ServerProfile copyWith({
    String? name,
    String? baseUrl,
    bool? isDefault,
    Color? accentColor,
    List<BotProfile>? bots,
  }) {
    return ServerProfile(
      id: id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      isDefault: isDefault ?? this.isDefault,
      accentColor: accentColor ?? this.accentColor,
      bots: bots ?? this.bots,
    );
  }
}

/// A Hermes agent/bot profile on a server (e.g. @hermes, @buff_patrick, @homie).
class BotProfile {
  final String id;
  final String name;
  final String description;
  final String model;
  final String emoji;
  const BotProfile({
    required this.id,
    required this.name,
    required this.description,
    required this.model,
    required this.emoji,
  });
}

/// A scheduled cron routine.
class CronJob {
  final String id;
  final String name;
  final String schedule;
  final String prompt;
  final bool enabled;
  final DateTime? lastRun;
  final String? lastStatus;
  final String deliver;

  const CronJob({
    required this.id,
    required this.name,
    required this.schedule,
    required this.prompt,
    required this.deliver,
    this.enabled = true,
    this.lastRun,
    this.lastStatus,
  });

  CronJob copyWith({
    bool? enabled,
    DateTime? lastRun,
    String? lastStatus,
  }) {
    return CronJob(
      id: id,
      name: name,
      schedule: schedule,
      prompt: prompt,
      deliver: deliver,
      enabled: enabled ?? this.enabled,
      lastRun: lastRun ?? this.lastRun,
      lastStatus: lastStatus ?? this.lastStatus,
    );
  }
}

/// An installed Hermes skill.
class Skill {
  final String id;
  final String name;
  final String description;
  final List<String> tags;
  final bool enabled;
  const Skill({
    required this.id,
    required this.name,
    required this.description,
    required this.tags,
    this.enabled = true,
  });
}

/// A persistent memory entry.
class MemoryEntry {
  final String id;
  final String category; // 'memory' | 'user'
  final String content;
  final DateTime createdAt;
  const MemoryEntry({
    required this.id,
    required this.category,
    required this.content,
    required this.createdAt,
  });
}

/// A live tool call activity.
class ToolActivity {
  final String id;
  final String toolName;
  final String status; // running | done | error
  final String detail;
  final DateTime timestamp;
  final String sessionId;
  const ToolActivity({
    required this.id,
    required this.toolName,
    required this.status,
    required this.detail,
    required this.timestamp,
    required this.sessionId,
  });
}

/// Result of a command run on the host PC via the remote terminal.
class TerminalResult {
  final String command;
  final String cwd;
  final String stdout;
  final String stderr;
  final int exitCode;
  final int durationMs;
  final bool timedOut;
  const TerminalResult({
    required this.command,
    required this.cwd,
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.durationMs,
    required this.timedOut,
  });

  String get combined => stdout.isNotEmpty ? '$stdout\n$stderr' : stderr;
}

/// Server / gateway health snapshot.
class ServerStatus {
  final double cpu;
  final double memory;
  final double disk;
  final String uptime;
  final bool gatewayUp;
  final int activeSessions;
  final String version;
  final DateTime fetchedAt;
  const ServerStatus({
    required this.cpu,
    required this.memory,
    required this.disk,
    required this.uptime,
    required this.gatewayUp,
    required this.activeSessions,
    required this.version,
    required this.fetchedAt,
  });
}

/// A server log entry.
class LogEntry {
  final String id;
  final String level; // INFO | WARN | ERROR | DEBUG
  final String message;
  final String source;
  final DateTime timestamp;
  const LogEntry({
    required this.id,
    required this.level,
    required this.message,
    required this.source,
    required this.timestamp,
  });
}

/// Model + provider health entry.
class ModelHealth {
  final String provider;
  final String model;
  final bool online;
  final String? quotaStatus;
  const ModelHealth({
    required this.provider,
    required this.model,
    required this.online,
    this.quotaStatus,
  });
}
