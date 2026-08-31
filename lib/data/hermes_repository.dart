import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:path_provider/path_provider.dart';
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

  Future<dynamic> _patch(String path, [Map<String, dynamic>? body]) async {
    final res = await _client.patch(Uri.parse('$baseUrl$path'),
        headers: _headers, body: jsonEncode(body ?? {}))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode >= 400) throw Exception('PATCH $path → ${res.statusCode}');
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
    // The bridge runs `hermes chat -q <text> --pass-session-id` SYNCHRONOUSLY
    // (it returns only after the full agent run — tool calls included —
    // finishes, server timeout is 180s). The generic _post helper times out at
    // 15s, which used to make the app throw "TimeoutException ... Future not
    // completed" while the session was actually created server-side. Use a
    // matching long timeout here so a real new chat (which can take a minute+)
    // completes instead of erroring out.
    final res = await _client
        .post(Uri.parse('$baseUrl/api/v1/chat/start'),
            headers: _headers, body: jsonEncode({'name': name, 'text': text}))
        .timeout(const Duration(seconds: 185));
    if (res.statusCode >= 400) {
      throw Exception('POST /api/v1/chat/start → ${res.statusCode}');
    }
    return _sessionFromJson(jsonDecode(res.body) as Map<String, dynamic>);
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
  Future<TerminalResult> runCommand(String command,
      {String? cwd, int? timeout}) async {
    final uri = Uri.parse('$baseUrl/api/v1/terminal/run');
    final res = await _client
        .post(uri,
            headers: _headers,
            body: jsonEncode({
              'command': command,
              'cwd': cwd ?? '',
              'timeout': timeout ?? 300,
            }))
        .timeout(Duration(seconds: (timeout ?? 300) + 30));
    if (res.statusCode >= 400) {
      throw Exception('POST /terminal/run → ${res.statusCode}: ${res.body}');
    }
    final d = jsonDecode(res.body) as Map<String, dynamic>;
    return TerminalResult(
      command: d['command']?.toString() ?? command,
      cwd: d['cwd']?.toString() ?? cwd ?? '',
      stdout: d['stdout']?.toString() ?? '',
      stderr: d['stderr']?.toString() ?? '',
      exitCode: (d['exitCode'] as num?)?.toInt() ?? -1,
      durationMs: (d['durationMs'] as num?)?.toInt() ?? 0,
      timedOut: d['timedOut'] == true,
    );
  }

  /// Strips `MEDIA:<path>` references from agent text and turns them into
  /// downloadable attachments, so files the agent hands over render as chips
  /// in real-time during streaming (not only after a reload). Dedupes by path.
  ({String text, List<Attachment> attachments}) _parseMedia(String raw) {
    final re = RegExp(r'MEDIA:\s*(\S+)');
    final seen = <String>{};
    final attachments = <Attachment>[];
    final cleaned = raw.replaceAllMapped(re, (m) {
      final p = (m.group(1) ?? '').trim();
      if (p.isNotEmpty && seen.add(p)) {
        final name = p.split('/').last;
        final isHtml = name.toLowerCase().endsWith('.html') ||
            name.toLowerCase().endsWith('.htm');
        attachments.add(Attachment(
          name: name.isEmpty ? 'file' : name,
          url: p,
          mimeType: isHtml
              ? 'text/html'
              : 'application/octet-stream',
          path: p,
          kind: isHtml ? 'html' : 'file',
        ));
      }
      return '';
    }).trim();
    return (text: cleaned, attachments: attachments);
  }

  /// Web URL that serves an agent-produced file as an in-app preview (HTML/CSS/
  /// JS/images render interactively; relative assets resolve against the real
  /// file path on the bridge).
  @override
  String previewUrl(String filePath) {
    final segs = filePath
        .split('/')
        .where((s) => s.isNotEmpty)
        .map((s) => Uri.encodeComponent(s))
        .join('/');
    return '$baseUrl/html/$segs';
  }

  Attachment _attachmentFromJson(Map<String, dynamic> m) {
    final name = m['name']?.toString() ?? 'file';
    final isHtml = name.toLowerCase().endsWith('.html') ||
        name.toLowerCase().endsWith('.htm');
    return Attachment(
      name: name,
      url: m['path']?.toString() ?? '',
      mimeType: isHtml ? 'text/html' : 'application/octet-stream',
      path: m['path']?.toString(),
      kind: m['kind']?.toString() ?? (isHtml ? 'html' : 'file'),
    );
  }

  @override
  Stream<ChatMessage> sendMessage(String sessionId, String text,
      {List<Attachment> attachments = const []}) async* {
    // 1) Connect the WebSocket FIRST so the bridge's per-session queue is
    //    registered before we trigger hermes. Otherwise a fast reply's chunks
    //    and "done" are broadcast to no listener and are lost — the UI then
    //    never updates until the app is restarted.
    final wsUrl = baseUrl
        .replaceFirst('http', 'ws')
        .replaceFirst('https', 'wss');
    final channel = WebSocketChannel.connect(
        Uri.parse('$wsUrl/ws/chat/$sessionId'));

    // 2) Persist the user message (this spawns hermes on the bridge).
    await _post('/api/v1/sessions/$sessionId/messages', {
      'text': text,
      'attachments': attachments
          .where((a) => a.path != null)
          .map((a) => {'path': a.path, 'name': a.name, 'kind': a.kind})
          .toList(),
    });

    // 3) Stream the assistant reply over WebSocket. Hermes' CLI output is
    //    divided by the bridge into answer / thinking / technical chunks; we
    //    render each phase as its own bubble (stable id per phase).
    final baseId = 'live-${DateTime.now().millisecondsSinceEpoch}';
    final accs = {'answer': '', 'thinking': '', 'technical': ''};
    String? curType;

    ChatMessage msg(String type, String text, ChatMessageStatus status) {
      final parsed = type == 'answer'
          ? _parseMedia(text)
          : (text: text, attachments: <Attachment>[]);
      return ChatMessage(
        id: '$baseId-$type',
        sessionId: sessionId,
        role: ChatMessageRole.assistant,
        text: parsed.text,
        timestamp: DateTime.now(),
        status: status,
        type: type == 'thinking'
            ? ChatMessageType.thinking
            : type == 'technical'
                ? ChatMessageType.technical
                : ChatMessageType.answer,
        attachments: parsed.attachments,
      );
    }

    await for (final raw in channel.stream) {
      final data = jsonDecode(raw as String);
      final event = data['event'] as String? ?? 'chunk';
      if (event == 'done') break;
      final type = (data['type'] as String?) ?? 'answer';
      final delta = data['delta'] as String? ?? '';
      if (type != curType) {
        if (curType != null && (accs[curType] ?? '').trim().isNotEmpty) {
          yield msg(curType, accs[curType]!, ChatMessageStatus.sent);
        }
        curType = type;
      }
      accs[type] = (accs[type] ?? '') + delta;
      yield msg(type, accs[type]!, ChatMessageStatus.streaming);
    }
    await channel.sink.close();

    if (curType != null && (accs[curType] ?? '').trim().isNotEmpty) {
      yield msg(curType, accs[curType]!, ChatMessageStatus.sent);
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
  Future<String> downloadFile(String serverPath) async {
    final uri = Uri.parse(
        '$baseUrl/api/v1/files?path=${Uri.encodeQueryComponent(serverPath)}');
    // Long timeout — a large APK over Tailscale/cellular can take minutes,
    // and the old 90s cap was cutting transfers off mid-body.
    const timeout = Duration(minutes: 5);
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final streamed = await _client
            .send(http.Request('GET', uri)..headers.addAll(_headers))
            .timeout(timeout);
        if (streamed.statusCode >= 400) {
          throw Exception('GET /files → ${streamed.statusCode}');
        }
        final dir = await getTemporaryDirectory();
        final name = serverPath.split('/').last.trim();
        final safe = name.isEmpty ? 'download' : name;
        final f = File(
            '${dir.path}/mercury_${DateTime.now().millisecondsSinceEpoch}_$safe');
        final sink = f.openWrite();
        try {
          await streamed.stream.pipe(sink).timeout(timeout);
        } finally {
          await sink.close();
        }
        return f.path;
      } on Exception catch (e) {
        lastError = e;
        // Retry once: large transfers over Tailscale/cellular can drop mid-body.
      }
    }
    throw Exception('Download failed: ${lastError ?? 'unknown error'}');
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
            .map((m) => _attachmentFromJson(m))
            .toList(),
      );

  @override
  Stream<ChatMessage> sendGroupMessage(String gid, String text) async* {
    // Connect the WS first so the bridge's queue is registered before the
    // fan-out starts (same fast-reply race as sendMessage).
    final wsUrl = baseUrl.replaceFirst('http', 'ws').replaceFirst('https', 'wss');
    final channel =
        WebSocketChannel.connect(Uri.parse('$wsUrl/ws/group/$gid'));
    await _post('/api/v1/groups/$gid/messages', {'text': text});
    final acc = <String, String>{};
    try {
      await for (final raw in channel.stream) {
        final data = jsonDecode(raw as String);
        final event = data['event'] as String? ?? 'chunk';
        final agent = data['agent'] as String?;
        if (event == 'chunk' && agent != null) {
          final type = (data['type'] as String?) ?? 'answer';
          final delta = data['delta'] as String? ?? '';
          final id = 'g-live-$agent-$type';
          acc[id] = (acc[id] ?? '') + delta;
          yield _groupStreamMsg(gid, agent, type, acc[id]!,
              ChatMessageStatus.streaming);
        } else if (event == 'done' && agent != null) {
          for (final t in ['answer', 'thinking', 'technical']) {
            final id = 'g-live-$agent-$t';
            if ((acc[id] ?? '').trim().isNotEmpty) {
              yield _groupStreamMsg(gid, agent, t, acc[id]!,
                  ChatMessageStatus.sent);
            }
          }
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

  // ---- Bots (Hermes profiles) -----------------------------------------
  @override
  Future<List<Bot>> bots() async {
    final data = await _get('/api/v1/bots') as List;
    return data
        .cast<Map<String, dynamic>>()
        .map(_botFromJson)
        .toList();
  }

  @override
  Future<List<String>> botPets() async {
    final data = await _get('/api/v1/bots/pets') as List;
    return data.cast<String>().toList();
  }

  @override
  Future<Bot> createBot(
      {required String name, String? description}) async {
    final data = await _post('/api/v1/bots', {
      'name': name,
      if (description != null && description.isNotEmpty)
        'description': description,
    });
    return _botFromJson(data as Map<String, dynamic>);
  }

  @override
  Future<Bot> updateBot(String id,
      {String? description, String? pet, String? soul}) async {
    final data = await _patch('/api/v1/bots/$id', {
      'description': ?description,
      'pet': ?pet,
      'soul': ?soul,
    });
    return _botFromJson(data as Map<String, dynamic>);
  }

  @override
  Future<void> deleteBot(String id) async => _delete('/api/v1/bots/$id');

  Bot _botFromJson(Map<String, dynamic> j) => Bot(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
        model: j['model']?.toString(),
        provider: j['provider']?.toString(),
        pet: j['pet']?.toString(),
        soul: j['soul']?.toString() ?? '',
        isDefault: j['isDefault'] == true,
      );

  ChatMessage _groupStreamMsg(String gid, String agent, String type, String text,
      ChatMessageStatus status) {
    final parsed = type == 'answer'
        ? _parseMedia(text)
        : (text: text, attachments: <Attachment>[]);
    return ChatMessage(
      id: 'g-live-$agent-$type',
      sessionId: gid,
      role: ChatMessageRole.assistant,
      text: parsed.text,
      timestamp: DateTime.now(),
      status: status,
      agent: agent,
      type: type == 'thinking'
          ? ChatMessageType.thinking
          : type == 'technical'
              ? ChatMessageType.technical
              : ChatMessageType.answer,
      attachments: parsed.attachments,
    );
  }

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
            .map((m) => _attachmentFromJson(m))
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
