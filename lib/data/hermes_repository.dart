import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'app_repository.dart';
import 'models.dart';

/// Real HTTP/WebSocket connector to a Hermes bridge server. The bridge fronts
/// the Hermes gateway and exposes the REST + WS contract documented in the
/// README. Point it at `baseUrl` with a bearer token.
///
/// Expected REST contract (documented in README):
///   GET  /api/v1/servers, /sessions, /sessions/:id/messages, /cron, /skills,
///        /memory, /status, /logs, /models, /tools, /commands, /webhooks
///   POST /api/v1/sessions, /sessions/:id/messages, /cron, /memory, /webhooks/:id/trigger
///   WS   /ws/chat/{sessionId}   -> streamed assistant tokens
///
/// This is the only backend — the app requires a verified connection.
class HermesRepository implements AppRepository {
  final String baseUrl;
  final String? token;
  final http.Client _client;

  HermesRepository({required this.baseUrl, this.token, http.Client? client})
      : _client = client ?? http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<dynamic> _get(String path) async {
    final res = await _client
        .get(Uri.parse('$baseUrl$path'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode >= 400) throw Exception('GET $path → ${res.statusCode}');
    return jsonDecode(res.body);
  }

  Future<dynamic> _post(String path, [Map<String, dynamic>? body]) async {
    final res = await _client.post(Uri.parse('$baseUrl$path'),
        headers: _headers, body: jsonEncode(body ?? {}))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode >= 400) throw Exception('POST $path → ${res.statusCode}');
    return jsonDecode(res.body);
  }

  Future<dynamic> _delete(String path) async {
    final res = await _client
        .delete(Uri.parse('$baseUrl$path'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode >= 400) throw Exception('DELETE $path → ${res.statusCode}');
    return res.body.isEmpty ? null : jsonDecode(res.body);
  }

  // ---- Servers --------------------------------------------------------
  @override
  Future<List<ServerProfile>> servers() async {
    final data = (await _get('/api/v1/servers') as List)
        .cast<Map<String, dynamic>>();
    return data.map(_serverFromJson).toList();
  }

  @override
  Future<ServerProfile> addServer(ServerProfile profile) async {
    final data = await _post('/api/v1/servers', _serverToJson(profile));
    return _serverFromJson(data);
  }

  @override
  Future<void> updateServer(ServerProfile profile) async =>
      _post('/api/v1/servers/${profile.id}', _serverToJson(profile));

  @override
  Future<void> removeServer(String id) async => _delete('/api/v1/servers/$id');

  // ---- Sessions -------------------------------------------------------
  @override
  Future<List<ChatSession>> sessions() async {
    final data = (await _get('/api/v1/sessions') as List)
        .cast<Map<String, dynamic>>();
    return data.map(_sessionFromJson).toList();
  }

  @override
  Future<List<ChatMessage>> messages(String sessionId) async {
    final data = (await _get('/api/v1/sessions/$sessionId/messages') as List)
        .cast<Map<String, dynamic>>();
    return data.map(_messageFromJson).toList();
  }

  @override
  Future<ChatSession> createSession(String title, String profileId) async {
    final data = await _post('/api/v1/sessions',
        {'title': title, 'profileId': profileId});
    return _sessionFromJson(data);
  }

  @override
  Future<ChatSession> startNewChat({
    required String name,
    required String text,
  }) async {
    final data = await _post('/api/v1/chat/start', {'name': name, 'text': text});
    return _sessionFromJson(data as Map<String, dynamic>);
  }

  @override
  Future<void> registerDevice(String token) async {
    await _post('/api/v1/devices/register', {'token': token, 'platform': 'android'});
  }

  @override
  Future<void> sendTestPush({String? title, String? message}) async {
    await _post('/api/v1/devices/test', {'title': ?title, 'message': ?message});
  }

  @override
  Stream<ChatMessage> sendMessage(String sessionId, String text,
      {List<Attachment> attachments = const []}) async* {
    // 1) Persist the user message.
    await _post('/api/v1/sessions/$sessionId/messages', {
      'text': text,
      'attachments': attachments
          .where((a) => a.path != null)
          .map((a) => {'path': a.path, 'name': a.name, 'kind': a.kind})
          .toList(),
    });

    // 2) Stream the assistant reply over WebSocket.
    final wsUrl = baseUrl
        .replaceFirst('http', 'ws')
        .replaceFirst('https', 'wss');
    final channel = WebSocketChannel.connect(
        Uri.parse('$wsUrl/ws/chat/$sessionId'));
    final replyId = 'live-${DateTime.now().millisecondsSinceEpoch}';
    String acc = '';
    var started = false;

    await for (final raw in channel.stream) {
      final data = jsonDecode(raw as String);
      final event = data['event'] as String? ?? 'chunk';
      final delta = data['delta'] as String? ?? data['text'] as String? ?? '';
      if (!started) {
        started = true;
        yield ChatMessage(
          id: replyId,
          sessionId: sessionId,
          role: ChatMessageRole.assistant,
          text: '',
          timestamp: DateTime.now(),
          status: ChatMessageStatus.streaming,
        );
      }
      acc += delta;
      yield ChatMessage(
        id: replyId,
        sessionId: sessionId,
        role: ChatMessageRole.assistant,
        text: acc,
        timestamp: DateTime.now(),
        status: ChatMessageStatus.streaming,
      );
      if (event == 'done') break;
    }
    await channel.sink.close();

    if (acc.isNotEmpty) {
      yield ChatMessage(
        id: replyId,
        sessionId: sessionId,
        role: ChatMessageRole.assistant,
        text: acc,
        timestamp: DateTime.now(),
        status: ChatMessageStatus.sent,
      );
    }
  }

  @override
  Future<Attachment> uploadAttachment({
    required String localPath,
    required String name,
    String? mimeType,
  }) async {
    final req = http.MultipartRequest(
        'POST', Uri.parse('$baseUrl/api/v1/attachments'));
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    req.files.add(await http.MultipartFile.fromPath('file', localPath,
        filename: name,
        contentType: mimeType != null ? MediaType.parse(mimeType) : null));
    final streamed = await req.send().timeout(const Duration(seconds: 90));
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode >= 400) {
      throw Exception('POST /attachments → ${res.statusCode}');
    }
    final d = jsonDecode(res.body) as Map<String, dynamic>;
    return Attachment(
      name: d['name'] as String? ?? name,
      url: d['path'] as String? ?? '',
      mimeType: mimeType ?? 'application/octet-stream',
      sizeBytes: d['size'] as int?,
      path: d['path'] as String?,
      kind: d['kind'] as String?,
      localPath: localPath,
    );
  }

  @override
  Future<Uint8List> downloadFile(String serverPath) async {
    final uri = Uri.parse(
        '$baseUrl/api/v1/files?path=${Uri.encodeQueryComponent(serverPath)}');
    final res = await _client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 90));
    if (res.statusCode >= 400) throw Exception('GET /files → ${res.statusCode}');
    return res.bodyBytes;
  }

  @override
  Future<void> markRead(String sessionId) async =>
      _post('/api/v1/sessions/$sessionId/read');

  @override
  Future<void> togglePinned(String sessionId) async =>
      _post('/api/v1/sessions/$sessionId/pin');

  @override
  Future<void> toggleStarred(String sessionId) async =>
      _post('/api/v1/sessions/$sessionId/star');

  @override
  Future<void> deleteSession(String sessionId) async =>
      _delete('/api/v1/sessions/$sessionId');

  @override
  Future<List<ChatSession>> searchSessions(String query) async =>
      sessions().then((s) => s.where((x) =>
          x.title.toLowerCase().contains(query.toLowerCase())).toList());

  // ---- Groups (multi-agent chat) --------------------------------------
  @override
  Future<List<GroupChat>> groups() async {
    final data = await _get('/api/v1/groups') as List<dynamic>;
    return data.cast<Map<String, dynamic>>().map(_groupFromJson).toList();
  }

  GroupChat _groupFromJson(Map<String, dynamic> j) => GroupChat(
        id: (j['id'] ?? '').toString(),
        name: j['name']?.toString() ?? 'Group',
        agents: (j['agents'] as List? ?? [])
            .map((a) => a.toString())
            .toList(),
        lastPreview: j['lastPreview']?.toString() ?? '',
        lastTimestamp: _dt(j['lastTimestamp']),
        messageCount: (j['messageCount'] as num?)?.toInt() ?? 0,
      );

  @override
  Future<GroupChat> createGroup({
    required String name,
    required List<String> agents,
  }) async {
    final data = await _post('/api/v1/groups', {'name': name, 'agents': agents});
    return _groupFromJson(data as Map<String, dynamic>);
  }

  @override
  Future<List<ChatMessage>> groupMessages(String gid) async {
    final data = await _get('/api/v1/groups/$gid/messages') as List<dynamic>;
    return data
        .cast<Map<String, dynamic>>()
        .map((j) => _groupMessageFromJson(j, gid))
        .toList();
  }

  ChatMessage _groupMessageFromJson(Map<String, dynamic> j, String gid) =>
      ChatMessage(
        id: (j['id'] ?? '').toString(),
        sessionId: gid,
        role: j['role'] == 'user' ? ChatMessageRole.user : ChatMessageRole.assistant,
        text: j['text']?.toString() ?? '',
        timestamp: _dt(j['timestamp']),
        agent: j['agent']?.toString(),
        attachments: (j['media'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map((m) => Attachment(
                  name: m['name']?.toString() ?? 'file',
                  url: m['path']?.toString() ?? '',
                  mimeType: 'application/octet-stream',
                  path: m['path']?.toString(),
                  kind: 'file',
                ))
            .toList(),
      );

  @override
  Stream<ChatMessage> sendGroupMessage(String gid, String text) async* {
    await _post('/api/v1/groups/$gid/messages', {'text': text});
    final wsUrl = baseUrl.replaceFirst('http', 'ws').replaceFirst('https', 'wss');
    final channel =
        WebSocketChannel.connect(Uri.parse('$wsUrl/ws/group/$gid'));
    final acc = <String, String>{};
    try {
      await for (final raw in channel.stream) {
        final data = jsonDecode(raw as String);
        final event = data['event'] as String? ?? 'chunk';
        final agent = data['agent'] as String?;
        final delta = data['delta'] as String? ?? '';
        final id = 'g-live-${agent ?? 'x'}';
        if (event == 'start' && agent != null) {
          acc[agent] = '';
          yield ChatMessage(
              id: id, sessionId: gid, role: ChatMessageRole.assistant,
              text: '', timestamp: DateTime.now(),
              status: ChatMessageStatus.streaming, agent: agent);
        } else if (event == 'chunk' && agent != null) {
          acc[agent] = (acc[agent] ?? '') + delta;
          yield ChatMessage(
              id: id, sessionId: gid, role: ChatMessageRole.assistant,
              text: acc[agent]!, timestamp: DateTime.now(),
              status: ChatMessageStatus.streaming, agent: agent);
        } else if (event == 'done' && agent != null) {
          yield ChatMessage(
              id: id, sessionId: gid, role: ChatMessageRole.assistant,
              text: acc[agent] ?? '', timestamp: DateTime.now(),
              status: ChatMessageStatus.sent, agent: agent);
        } else if (event == 'complete') {
          break;
        }
      }
    } finally {
      await channel.sink.close();
    }
  }

  @override
  Future<void> deleteGroup(String gid) async => _delete('/api/v1/groups/$gid');

  // ---- Cron / skills / memory ----------------------------------------
  @override
  Future<List<CronJob>> cronJobs() async {
    final data =
        (await _get('/api/v1/cron') as List).cast<Map<String, dynamic>>();
    return data.map(_cronFromJson).toList();
  }

  @override
  Future<CronJob> createCronJob(CronJob job) async {
    final data = await _post('/api/v1/cron', _cronToJson(job));
    return _cronFromJson(data);
  }

  @override
  Future<void> updateCronJob(CronJob job) async =>
      _post('/api/v1/cron/${job.id}', _cronToJson(job));

  @override
  Future<void> deleteCronJob(String id) async => _delete('/api/v1/cron/$id');

  @override
  Future<CronJob> runCronJob(String id) async {
    final data = await _post('/api/v1/cron/$id/run');
    return _cronFromJson(data);
  }

  @override
  Future<List<Skill>> skills() async {
    final data = await _get('/api/v1/skills') as List;
    return data
        .map((s) => Skill(
              id: s['id'],
              name: s['name'],
              description: s['description'] ?? '',
              tags: (s['tags'] as List?)?.cast<String>() ?? [],
              enabled: s['enabled'] ?? true,
            ))
        .toList();
  }

  @override
  Future<void> toggleSkill(String id) async => _post('/api/v1/skills/$id/toggle');

  @override
  Future<List<MemoryEntry>> memoryEntries({String? category}) async {
    final path = category == null
        ? '/api/v1/memory'
        : '/api/v1/memory?category=$category';
    final data =
        (await _get(path) as List).cast<Map<String, dynamic>>();
    return data.map(_memoryFromJson).toList();
  }

  @override
  Future<MemoryEntry> addMemory(String category, String content) async {
    final data =
        await _post('/api/v1/memory', {'category': category, 'content': content});
    return _memoryFromJson(data);
  }

  @override
  Future<void> deleteMemory(String id) async => _delete('/api/v1/memory/$id');

  @override
  Future<List<MemoryEntry>> searchMemory(String query) async {
    final data = (await _get('/api/v1/memory/search?q=$query') as List)
        .cast<Map<String, dynamic>>();
    return data.map(_memoryFromJson).toList();
  }

  // ---- Dashboard ------------------------------------------------------
  @override
  Future<ServerStatus> serverStatus() async {
    final d = await _get('/api/v1/status') as Map<String, dynamic>;
    return ServerStatus(
      cpu: (d['cpu'] as num).toDouble(),
      memory: (d['memory'] as num).toDouble(),
      disk: (d['disk'] as num).toDouble(),
      uptime: d['uptime'] ?? '',
      gatewayUp: d['gatewayUp'] ?? true,
      activeSessions: d['activeSessions'] ?? 0,
      version: d['version'] ?? '',
      fetchedAt: DateTime.now(),
    );
  }

  @override
  Future<List<LogEntry>> logs({int limit = 100}) async {
    final data = (await _get('/api/v1/logs?limit=$limit') as List)
        .cast<Map<String, dynamic>>();
    return data.map(_logFromJson).toList();
  }

  @override
  Future<List<ModelHealth>> modelHealth() async {
    final data = await _get('/api/v1/models') as List;
    return data
        .map((m) => ModelHealth(
              provider: m['provider'],
              model: m['model'],
              online: m['online'] ?? true,
              quotaStatus: m['quotaStatus'],
            ))
        .toList();
  }

  @override
  Future<List<ToolActivity>> toolActivities({String? sessionId}) async {
    final path = sessionId == null
        ? '/api/v1/activity'
        : '/api/v1/activity?sessionId=$sessionId';
    final data = await _get(path) as List;
    return data
        .map((a) => ToolActivity(
              id: a['id'],
              toolName: a['toolName'],
              status: a['status'],
              detail: a['detail'],
              timestamp: DateTime.parse(a['timestamp']),
              sessionId: a['sessionId'] ?? '',
            ))
        .toList();
  }

  @override
  Future<List<String>> toolCatalog() async {
    final data = await _get('/api/v1/tools') as List;
    return data.cast<String>();
  }

  @override
  Future<List<CommandItem>> commandPalette() async {
    final data = await _get('/api/v1/commands') as List;
    return data
        .map((c) => CommandItem(
              id: c['id'],
              label: c['label'],
              description: c['description'],
              icon: c['icon'],
            ))
        .toList();
  }

  @override
  Future<List<WebhookRoute>> webhooks() async {
    final data = await _get('/api/v1/webhooks') as List;
    return data
        .map((w) => WebhookRoute(
              id: w['id'],
              name: w['name'],
              description: w['description'] ?? '',
              enabled: w['enabled'] ?? true,
            ))
        .toList();
  }

  @override
  Future<void> triggerWebhook(String id) async =>
      _post('/api/v1/webhooks/$id/trigger');

  // ---- JSON helpers ---------------------------------------------------
  ServerProfile _serverFromJson(Map<String, dynamic> j) => ServerProfile(
        id: j['id'],
        name: j['name'],
        baseUrl: j['baseUrl'],
        isDefault: j['isDefault'] ?? false,
        accentColor: _color(j['accent']),
        bots: (j['bots'] as List? ?? [])
            .map((b) => BotProfile(
                  id: b['id'],
                  name: b['name'],
                  description: b['description'] ?? '',
                  model: b['model'] ?? '',
                  emoji: b['emoji'] ?? '🤖',
                ))
            .toList(),
      );
  Map<String, dynamic> _serverToJson(ServerProfile s) => {
        'id': s.id,
        'name': s.name,
        'baseUrl': s.baseUrl,
        'isDefault': s.isDefault,
        'accent': s.accentColor.toARGB32(),
        'bots': s.bots
            .map((b) => {
                  'id': b.id,
                  'name': b.name,
                  'description': b.description,
                  'model': b.model,
                  'emoji': b.emoji,
                })
            .toList(),
      };

  ChatSession _sessionFromJson(Map<String, dynamic> j) => ChatSession(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? 'Conversation').toString(),
        lastPreview: j['lastPreview']?.toString() ?? '',
        lastTimestamp: _dt(j['lastTimestamp']),
        unreadCount: (j['unreadCount'] as num?)?.toInt() ?? 0,
        pinned: j['pinned'] == true,
        starred: j['starred'] == true,
        profileId: (j['profileId'] ?? '').toString(),
        avatarColor: _color(j['color']),
      );

  ChatMessage _messageFromJson(Map<String, dynamic> j) => ChatMessage(
        id: (j['id'] ?? '').toString(),
        sessionId: (j['sessionId'] ?? '').toString(),
        role: ChatMessageRole.values.asNameMap()[j['role']] ??
            ChatMessageRole.user,
        text: j['text']?.toString() ?? '',
        timestamp: _dt(j['timestamp']),
        toolName: j['toolName']?.toString(),
        attachments: (j['media'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map((m) => Attachment(
                  name: m['name']?.toString() ?? 'file',
                  url: m['path']?.toString() ?? '',
                  mimeType: 'application/octet-stream',
                  path: m['path']?.toString(),
                  kind: 'file',
                ))
            .toList(),
      );

  /// Tolerant date parse — never throws on missing/malformed timestamps
  /// (a single bad row must not break the whole list).
  DateTime _dt(dynamic v) {
    if (v is String) {
      final d = DateTime.tryParse(v);
      if (d != null) return d;
    } else if (v is num) {
      return DateTime.fromMillisecondsSinceEpoch(v.round());
    }
    return DateTime.now();
  }

  CronJob _cronFromJson(Map<String, dynamic> j) => CronJob(
        id: j['id'],
        name: j['name'],
        schedule: j['schedule'],
        prompt: j['prompt'],
        deliver: j['deliver'],
        enabled: j['enabled'] ?? true,
        lastRun: j['lastRun'] == null ? null : DateTime.parse(j['lastRun']),
        lastStatus: j['lastStatus'],
      );
  Map<String, dynamic> _cronToJson(CronJob c) => {
        'id': c.id,
        'name': c.name,
        'schedule': c.schedule,
        'prompt': c.prompt,
        'deliver': c.deliver,
        'enabled': c.enabled,
        'lastRun': c.lastRun?.toIso8601String(),
        'lastStatus': c.lastStatus,
      };

  MemoryEntry _memoryFromJson(Map<String, dynamic> j) => MemoryEntry(
        id: j['id'],
        category: j['category'],
        content: j['content'],
        createdAt: DateTime.parse(j['createdAt']),
      );

  LogEntry _logFromJson(Map<String, dynamic> j) => LogEntry(
        id: j['id'],
        level: j['level'],
        message: j['message'],
        source: j['source'],
        timestamp: DateTime.parse(j['timestamp']),
      );

  Color _color(dynamic v) => v is int ? Color(v) : const Color(0xFF6750A4);

  void dispose() => _client.close();
}
