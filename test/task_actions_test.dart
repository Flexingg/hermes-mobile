import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/core/config/app_config.dart';
import 'package:hermes_mobile/data/app_repository.dart';
import 'package:hermes_mobile/data/hermes_repository.dart';
import 'package:hermes_mobile/data/models.dart';
import 'package:hermes_mobile/data/project_models.dart';
import 'package:hermes_mobile/features/chat/message_bubble.dart';
import 'package:hermes_mobile/features/connection/connect_server_page.dart';
import 'package:hermes_mobile/features/projects/task_card.dart';
import 'package:hermes_mobile/features/projects/task_detail_page.dart';
import 'package:hermes_mobile/state/app_state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Everything the task screens touch; anything else is a test bug.
class FakeRepo implements AppRepository {
  List<Project> projectList = [];
  List<ChatSession> projectChats = [];
  final List<Map<String, Object?>> intents = [];

  @override
  Future<List<Project>> projects() async => projectList;
  @override
  Future<Project> project(String id) async => projectList.firstWhere((p) => p.id == id);
  @override
  Future<List<ChatSession>> projectSessions(String id) async => projectChats;
  @override
  Future<ChatSession> createSession(String title, String? profile) async =>
      ChatSession(id: 'new', title: title, lastPreview: '', lastTimestamp: DateTime.now(), profileId: profile ?? 'hermes');
  @override
  Future<IntentResult> intent(String kind,
      {String? project, String? sessionId, Map<String, dynamic>? payload}) async {
    intents.add({'kind': kind, 'project': project, 'sessionId': sessionId, 'payload': payload});
    return const IntentResult(sessionId: 's', reply: 'Put it back on the task.');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeRepo: ${invocation.memberName}');
}

Project project() => Project.fromJson({
      'id': 'hermes-mobile',
      'name': 'hermes-mobile',
      'repo': 'Flexingg/hermes-mobile',
      'profile': 'dev-hermes-mobile',
      'coder': 'claude',
      'status': 'ready',
      'counts': {'ready': 1, 'needs_you': 0, 'working': 0, 'queued': 0},
    });

ProjectTask task(String phase, {int? pr = 9, DateTime? mergedAt}) => ProjectTask.fromJson({
      'id': 't_abc',
      'title': '#42 Auto-close the task',
      'phase': phase,
      'issue': 42,
      'issueUrl': 'https://github.com/Flexingg/hermes-mobile/issues/42',
      'prNumber': pr,
      'prUrl': pr == null ? null : 'https://github.com/Flexingg/hermes-mobile/pull/9',
      'ci': 'green',
      'branch': 'hermes-mobile/t_abc-auto-close',
      'mergedAt': mergedAt?.toIso8601String(),
    });

Future<(AppState, FakeRepo)> stateWith({List<Project>? projects}) async {
  SharedPreferences.setMockInitialValues({});
  final state = AppState(await AppConfig.load());
  final repo = FakeRepo()..projectList = projects ?? [];
  state.repo = repo;
  return (state, repo);
}

Widget host(AppState state, Widget child, {AppConfig? config}) {
  final c = config ?? state.config;
  return MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: state),
      ChangeNotifierProvider.value(value: c),
    ],
    child: MaterialApp(home: child),
  );
}

/// The detail page is a long ListView: give the test a tall surface so the lower
/// sections (suggest edits, follow-up issue) are actually built.
Future<void> pumpTall(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TaskPhase', () {
    test('says which phases are finished, and names them the way the scripts do', () {
      expect(TaskPhase.merged.isFinished, isTrue);
      expect(TaskPhase.closed.isFinished, isTrue);
      expect(TaskPhase.done.isFinished, isTrue);
      expect(TaskPhase.cancelled.isFinished, isTrue);
      expect(TaskPhase.review.isFinished, isFalse);
      expect(TaskPhase.ready.isFinished, isFalse); // still waiting on a person
      expect(TaskPhase.ciRetry.wire, 'ci_retry');
      expect(TaskPhase.needsYou.wire, 'needs_you');
      expect(TaskPhase.merged.wire, 'merged');
    });

    test('a merged task is offered a follow-up, not a retry', () {
      final merged = task('merged', mergedAt: DateTime.now());
      expect(merged.canRetry, isFalse);
      expect(merged.canCancel, isFalse);
      expect(merged.canFileFollowUp, isTrue);
      expect(merged.canSuggestEdit, isTrue);
      expect(task('needs_you').canRetry, isTrue);
      expect(task('queued').canSuggestEdit, isFalse);
      expect(merged.mergedAt, isNotNull);
    });
  });

  group('ConnectServerPage', () {
    testWidgets('offers the three ways to reach a server', (tester) async {
      final (state, _) = await stateWith();
      await tester.pumpWidget(host(state, const ConnectServerPage()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('connection-kind')), findsOneWidget);
      expect(find.text('Local network'), findsOneWidget);
      expect(find.text('Tailscale'), findsOneWidget);
      expect(find.text('Cloudflare tunnel'), findsOneWidget);
      // LAN is the kind that gets the mDNS scan; the others don't.
      await tester.tap(find.text('Local network'));
      await tester.pumpAndSettle();
      expect(find.text('Search your network'), findsOneWidget);
      expect(find.byKey(const Key('fetch-tunnel')), findsNothing);
    });

    testWidgets('a tunnel adds Access fields and a fetch-the-URL button', (tester) async {
      final (state, _) = await stateWith();
      await tester.pumpWidget(host(state, const ConnectServerPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cloudflare tunnel'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('access-client-id')), findsOneWidget);
      expect(find.byKey(const Key('access-client-secret')), findsOneWidget);
      expect(find.byKey(const Key('fetch-tunnel')), findsOneWidget);
      expect(find.text('Search your network'), findsNothing);
    });

    testWidgets('refuses an http tunnel URL before touching the network', (tester) async {
      final (state, _) = await stateWith();
      await pumpTall(tester, host(state, const ConnectServerPage()));
      await tester.tap(find.text('Cloudflare tunnel'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Server URL'), 'http://100.67.34.4:9130');
      await tester.ensureVisible(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      expect(find.text('A Cloudflare tunnel is always https.'), findsOneWidget);
      expect(state.connected, isFalse);
    });

    test('each kind validates the URL it expects', () {
      expect(ConnectionKind.tunnel.validate('https://x.trycloudflare.com'), isNull);
      expect(ConnectionKind.tunnel.validate('http://1.2.3.4:9130'), contains('https'));
      expect(ConnectionKind.lan.validate('http://192.168.1.146:9130'), isNull);
      expect(ConnectionKind.lan.validate('192.168.1.146:9130'), contains('URL'));
      expect(ConnectionKind.tailscale.validate(''), contains('Enter'));
      expect(ConnectionKind.parse('tunnel'), ConnectionKind.tunnel);
      expect(ConnectionKind.parse(null), ConnectionKind.lan);
    });
  });

  group('Cloudflare Access', () {
    test('the service token rides on every request and the WS handshake', () async {
      final seen = <Map<String, String>>[];
      final repo = HermesRepository(
        baseUrl: 'https://bridge.example.com',
        token: 't',
        accessClientId: 'id123.access',
        accessClientSecret: 'secret123',
        client: MockClient((req) async {
          seen.add(req.headers);
          return http.Response('{"up": true, "url": "https://x.trycloudflare.com"}', 200);
        }),
      );
      final t = await repo.tunnelStatus();
      expect(t.up, isTrue);
      expect(t.url, 'https://x.trycloudflare.com');
      expect(seen.single['CF-Access-Client-Id'], 'id123.access');
      expect(seen.single['CF-Access-Client-Secret'], 'secret123');
      expect(repo.accessHeaders.keys, containsAll(['CF-Access-Client-Id', 'CF-Access-Client-Secret']));
    });

    test('no Access token, no Access headers', () {
      final repo = HermesRepository(baseUrl: 'http://192.168.1.146:9130', token: 't');
      expect(repo.accessHeaders, isEmpty);
    });
  });

  group('TaskCard', () {
    testWidgets('opens the task detail page when tapped', (tester) async {
      final (state, _) = await stateWith();
      await tester.pumpWidget(host(state, Scaffold(body: TaskCard(project: project(), task: task('review')))));
      await tester.tap(find.byKey(const Key('open-t_abc')));
      await tester.pumpAndSettle();
      expect(find.byType(TaskDetailPage), findsOneWidget);
    });

    testWidgets('a merged task shows when it merged and drops the CI line', (tester) async {
      final (state, _) = await stateWith();
      final merged = task('merged', mergedAt: DateTime.now().subtract(const Duration(minutes: 5)));
      await tester.pumpWidget(host(state, Scaffold(body: TaskCard(project: project(), task: merged))));
      expect(find.textContaining('merged '), findsOneWidget);
      expect(find.text('CI passed'), findsNothing);
      expect(find.byKey(const Key('install-t_abc')), findsNothing);
    });
  });

  group('TaskDetailPage', () {
    testWidgets('sends the suggestion as an edit_task intent naming the task and PR', (tester) async {
      final (state, repo) = await stateWith();
      await pumpTall(tester, host(state, TaskDetailPage(project: project(), task: task('review'))));
      await tester.enterText(find.byKey(const Key('suggest-t_abc')), 'keep the header pinned');
      await tester.tap(find.byKey(const Key('send-suggestion-t_abc')));
      await tester.pumpAndSettle();
      final sent = repo.intents.single;
      expect(sent['kind'], 'edit_task');
      expect(sent['project'], 'hermes-mobile');
      final payload = sent['payload'] as Map<String, dynamic>;
      expect(payload['task'], 't_abc');
      expect(payload['note'], 'keep the header pinned');
      expect(payload['issue'], 42);
      expect(payload['pr'], 9);
      expect(payload['phase'], 'review');
      // The reply is shown, so the user can see what Hermes did with it.
      expect(find.text('Put it back on the task.'), findsOneWidget);
    });

    testWidgets('an empty suggestion sends nothing', (tester) async {
      final (state, repo) = await stateWith();
      await pumpTall(tester, host(state, TaskDetailPage(project: project(), task: task('review'))));
      await tester.tap(find.byKey(const Key('send-suggestion-t_abc')));
      await tester.pumpAndSettle();
      expect(repo.intents, isEmpty);
    });

    testWidgets('a merged task files a follow-up issue instead', (tester) async {
      final (state, repo) = await stateWith();
      final merged = task('merged', mergedAt: DateTime.now());
      await pumpTall(tester, host(state, TaskDetailPage(project: project(), task: merged)));
      expect(find.text('File a follow-up issue'), findsOneWidget);
      expect(find.textContaining('finished'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('followup-t_abc')), 'the card should keep the streak');
      await tester.tap(find.byKey(const Key('send-followup-t_abc')));
      await tester.pumpAndSettle();
      expect(repo.intents.single['kind'], 'followup_issue');
      expect((repo.intents.single['payload'] as Map)['note'], 'the card should keep the streak');
    });

    testWidgets('offers the project chat, the PR and the branch for any task', (tester) async {
      final (state, _) = await stateWith();
      await pumpTall(tester, host(state, TaskDetailPage(project: project(), task: task('review'))));
      expect(find.byKey(const Key('open-chat-t_abc')), findsOneWidget);
      expect(find.text('Open PR'), findsOneWidget);
      expect(find.text('#9'), findsOneWidget);
      expect(find.text('hermes-mobile/t_abc-auto-close'), findsOneWidget);
    });
  });

  group('session meta row', () {
    testWidgets('plumbing arrives as a collapsed row, not as the reply', (tester) async {
      final config = AppConfig.load();
      final (state, _) = await stateWith();
      final msg = ChatMessage(
        id: 'live-answer',
        sessionId: 's1',
        role: ChatMessageRole.assistant,
        text: 'You have 1,310 kcal left today.',
        timestamp: DateTime.now(),
        sessionMeta: const {
          'sessionId': '20260926_115626_c2787f',
          'title': 'Assistant',
          'duration': '19s',
          'messages': '2 (1 user, 0 tool calls)',
          'resumeCommand': 'hermes --resume 20260926_115626_c2787f',
        },
      );
      await tester.pumpWidget(host(state, Scaffold(body: MessageBubble(message: msg)), config: await config));
      await tester.pumpAndSettle();
      expect(find.text('You have 1,310 kcal left today.'), findsOneWidget);
      expect(find.text('Resume this session with:'), findsNothing);
      expect(find.byKey(const Key('session-meta')), findsOneWidget);
      expect(find.textContaining('19s · 2 (1 user, 0 tool calls)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('session-meta')));
      await tester.pumpAndSettle();
      expect(find.textContaining('hermes --resume 20260926_115626_c2787f'), findsOneWidget);
    });

    testWidgets('no meta, no row', (tester) async {
      final (state, _) = await stateWith();
      final msg = ChatMessage(
        id: 'm',
        sessionId: 's1',
        role: ChatMessageRole.assistant,
        text: 'plain answer',
        timestamp: DateTime.now(),
      );
      await tester.pumpWidget(host(state, Scaffold(body: MessageBubble(message: msg))));
      expect(find.byKey(const Key('session-meta')), findsNothing);
    });
  });

  group('repo plumbing', () {
    test('a stored reply carrying the banner is cleaned, and its facts kept', () async {
      final repo = HermesRepository(
        baseUrl: 'http://bridge.test',
        client: MockClient((req) async => http.Response(jsonEncode([
              {
                'id': 'm1',
                'sessionId': 's1',
                'role': 'assistant',
                'timestamp': '2026-09-26T11:57:00Z',
                'text': 'Here is what I found.\n'
                    'Session 20260926_115626_c2787f found but has no messages. Starting fresh.\n'
                    'Duration: 19s\n',
              }
            ]), 200)),
      );
      final msgs = await repo.messages('s1');
      expect(msgs.single.text, 'Here is what I found.');
      expect(msgs.single.sessionMeta['sessionId'], '20260926_115626_c2787f');
      expect(msgs.single.sessionMeta['duration'], '19s');
    });
  });


  group('test-first: a task parked before the push', () {
    ProjectTask parked({String? apk = '/k/apks/local-abc-local.apk'}) =>
        ProjectTask.fromJson({
          'id': 't_park',
          'title': '#7 Test it before the PR',
          'phase': 'awaiting_push',
          'issue': 7,
          'issueUrl': 'https://github.com/Flexingg/hermes-mobile/issues/7',
          'apk': apk,
          'blockedReason': 'Built and waiting: test build ready for #7. Nothing has been pushed.',
        });

    test('is its own phase, and knows it can be pushed', () {
      expect(TaskPhase.parse('awaiting_push'), TaskPhase.awaitingPush);
      expect(TaskPhase.awaitingPush.wire, 'awaiting_push');
      expect(TaskPhase.awaitingPush.isActive, isTrue); // still work, not finished
      expect(TaskPhase.awaitingPush.isFinished, isFalse);
      expect(parked().canPush, isTrue);
      expect(parked().canRetry, isFalse);
      expect(task('review').canPush, isFalse);
      expect(parked().prUrl, isNull);
    });

    test('a read-only project view of one shows the policy in force', () {
      final p = Project.fromJson({
        'id': 'hermes-mobile', 'repo': 'Flexingg/hermes-mobile', 'profile': 'dev-hermes-mobile',
        'pushPolicy': 'test-first',
      });
      expect(p.testsFirst, isTrue);
      expect(p.pushPolicy, 'test-first');
      expect(Project.fromJson({'id': 'x', 'repo': 'a/b', 'profile': 'p'}).testsFirst, isFalse);
    });

    testWidgets('offers the build to install and one tap to open the PR', (tester) async {
      final (state, repo) = await stateWith();
      final prj = Project.fromJson({
        'id': 'hermes-mobile',
        'name': 'hermes-mobile',
        'repo': 'Flexingg/hermes-mobile',
        'profile': 'dev-hermes-mobile',
        'coder': 'claude',
        'status': 'needs_you',
        'counts': {'ready': 0, 'needs_you': 1, 'working': 0, 'queued': 0},
      });
      await pumpTall(tester, host(state, Scaffold(body: TaskCard(project: prj, task: parked()))));

      expect(find.text('Built — not pushed'), findsOneWidget);
      expect(find.byKey(const Key('install-t_park')), findsOneWidget);
      expect(find.byKey(const Key('push-t_park')), findsOneWidget);
      expect(find.byKey(const Key('push-t_park')), findsOneWidget);
      // No PR exists yet, so there is nothing to open.
      expect(find.text('Open PR'), findsNothing);

      await tester.tap(find.byKey(const Key('push-t_park')));
      await tester.pumpAndSettle();
      expect(repo.intents.single['kind'], 'push_task');
      expect(repo.intents.single['project'], 'hermes-mobile');
      expect(repo.intents.single['payload'], {'task': 't_park'});
    });
  });
}
