import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/core/config/app_config.dart';
import 'package:hermes_mobile/data/app_repository.dart';
import 'package:hermes_mobile/data/hermes_repository.dart';
import 'package:hermes_mobile/data/models.dart';
import 'package:hermes_mobile/data/project_models.dart';
import 'package:hermes_mobile/features/chat/chat_thread_page.dart';
import 'package:hermes_mobile/features/projects/link_repo_sheet.dart';
import 'package:hermes_mobile/features/projects/projects_page.dart';
import 'package:hermes_mobile/state/app_state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Only what the project screens call; anything else is a test bug.
class FakeRepo implements AppRepository {
  List<Project> projectList = [];
  List<GithubRepo> repos = [];
  Map<String, List<ChatMessage>> threads = {};
  final List<Map<String, Object?>> intents = [];
  final Completer<void> intentGate = Completer<void>()..complete();

  @override
  Future<List<Project>> projects() async => projectList;
  @override
  Future<Project> project(String id) async => projectList.firstWhere((p) => p.id == id);
  @override
  Future<List<ChatSession>> projectSessions(String id) async => const [];
  @override
  Future<List<GithubRepo>> githubRepos() async => repos;
  @override
  Future<AgentSnapshot> agents() async => const AgentSnapshot(memAvailableMb: 6144);
  @override
  Future<IntentResult> intent(String kind,
      {String? project, String? sessionId, Map<String, dynamic>? payload}) async {
    intents.add({'kind': kind, 'project': project, 'sessionId': sessionId, 'payload': payload});
    await intentGate.future;
    return const IntentResult(sessionId: 's', reply: 'Filed #7 and queued it.');
  }

  @override
  Future<void> markRead(String sessionId) async {}
  @override
  Future<List<ChatMessage>> messages(String sessionId) async => threads[sessionId] ?? const [];
  @override
  Future<List<ChatSession>> sessions() async => const [];
  @override
  Future<List<MemoryEntry>> memoryEntries({String? category, String? profile}) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeRepo: ${invocation.memberName}');
}

Project project(String id, {String status = 'idle', int ready = 0, int needsYou = 0}) =>
    Project.fromJson({
      'id': id,
      'name': id,
      'repo': 'Flexingg/$id',
      'profile': 'dev-$id',
      'coder': 'claude',
      'status': status,
      'counts': {'ready': ready, 'needs_you': needsYou, 'working': 0, 'queued': 0},
    });

const draftText = 'Here is the plan.\n\n```issue-draft\n'
    '{"title": "Add a fasting card", "body": "## Why\\nTrack fasts.", '
    '"acceptance": ["Card shows hours fasted"], "labels": ["enhancement"]}\n```';

Future<AppState> stateWith(FakeRepo repo) async {
  SharedPreferences.setMockInitialValues({});
  final state = AppState(await AppConfig.load());
  state.repo = repo;
  return state;
}

Widget host(AppState state, Widget child) => ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(home: child),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IssueDraft', () {
    test('parses the draft block, last one wins, and strips it from the text', () {
      final text = '$draftText\n\nRevised:\n```issue-draft\n{"title": "Add a fasting card v2"}\n```';
      final d = IssueDraft.tryParse(text)!;
      expect(d.title, 'Add a fasting card v2');
      expect(IssueDraft.tryParse(draftText)!.acceptance, ['Card shows hours fasted']);
      expect(IssueDraft.strip(draftText), 'Here is the plan.');
    });

    test('malformed or title-less blocks are not drafts', () {
      expect(IssueDraft.tryParse('```issue-draft\n{not json}\n```'), isNull);
      expect(IssueDraft.tryParse('```issue-draft\n{"body": "x"}\n```'), isNull);
      expect(IssueDraft.tryParse('no draft here'), isNull);
    });
  });

  group('Project models', () {
    test('project and task parse the bridge view', () {
      final p = Project.fromJson({
        'id': 'lumen-launcher',
        'repo': 'Flexingg/lumen-launcher',
        'profile': 'dev-lumen-launcher',
        'coder': 'agy',
        'status': 'needs_you',
        'counts': {'needs_you': 1, 'ready': 2, 'working': 1, 'queued': 0},
        'lastTask': {'id': 't_1', 'title': '#3 x', 'phase': 'ci_retry', 'prNumber': 9, 'ci': 'red',
                     'failingChecks': ['test']},
      });
      expect(p.status, ProjectStatus.needsYou);
      expect((p.needsYou, p.ready, p.working), (1, 2, 1));
      expect(p.coderLabel, 'Antigravity');
      expect(p.lastTask!.phase, TaskPhase.ciRetry);
      expect(p.lastTask!.failingChecks, ['test']);
      expect(TaskPhase.parse('needs_you').label, 'Needs you');
      expect(ProjectTask.fromJson({'id': 't', 'title': 't', 'phase': 'needs_you'}).canRetry, isTrue);
      expect(ProjectTask.fromJson({'id': 't', 'title': 't', 'phase': 'working'}).canCancel, isFalse);
    });
  });

  group('HermesRepository', () {
    test('intent posts kind, project, session and payload', () async {
      late Map<String, dynamic> body;
      late Uri url;
      final repo = HermesRepository(
          baseUrl: 'http://bridge.test:9130',
          token: 't',
          client: MockClient((req) async {
            url = req.url;
            body = jsonDecode(req.body) as Map<String, dynamic>;
            return http.Response('{"sessionId": "s9", "reply": "done"}', 200);
          }));
      final r = await repo.intent('file_issue',
          project: 'lumen-launcher', sessionId: 'plan1', payload: {'draft': {'title': 'x'}});
      expect(url.path, '/api/v1/hermes/intent');
      expect(body, {
        'kind': 'file_issue',
        'project': 'lumen-launcher',
        'sessionId': 'plan1',
        'payload': {'draft': {'title': 'x'}},
      });
      expect((r.sessionId, r.reply), ('s9', 'done'));
    });

    test("a project's memory is asked for by profile", () async {
      late Uri url;
      final repo = HermesRepository(
          baseUrl: 'http://bridge.test:9130',
          client: MockClient((req) async {
            url = req.url;
            return http.Response('[]', 200);
          }));
      await repo.memoryEntries(profile: 'dev-lumen-launcher');
      expect(url.path, '/api/v1/memory');
      expect(url.queryParameters, {'profile': 'dev-lumen-launcher'});
    });
  });

  testWidgets('Projects lists the most urgent first under the pinned Hermes card', (tester) async {
    final repo = FakeRepo()
      ..projectList = [project('calm'), project('lumen', status: 'needs_you', needsYou: 1),
                       project('site', status: 'ready', ready: 1)];
    final state = await stateWith(repo);
    await tester.pumpWidget(host(state, const ProjectsPage()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('hermes-card')), findsOneWidget);
    expect(find.textContaining('1 need you'), findsOneWidget);
    expect(find.textContaining('6.0 GB free'), findsOneWidget);
    final order = ['lumen', 'site', 'calm']
        .map((n) => tester.getTopLeft(find.text(n).first).dy)
        .toList();
    expect(order, orderedEquals([...order]..sort()));

    await tester.pumpWidget(const SizedBox()); // dispose: stops the refresh timer
  });

  testWidgets('Link asks Hermes to link the repo with the chosen coder', (tester) async {
    final repo = FakeRepo()
      ..repos = const [GithubRepo(repo: 'Flexingg/lumen-launcher', language: 'Kotlin'),
                       GithubRepo(repo: 'Flexingg/hermes-mobile', linkedAs: 'hermes-mobile')];
    final state = await stateWith(repo);
    await tester.pumpWidget(host(state, const Scaffold(body: LinkRepoSheet())));
    await tester.pumpAndSettle();

    expect(find.text('Linked'), findsOneWidget); // already a project: no Link button
    await tester.tap(find.text('Antigravity'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Link'));
    await tester.pumpAndSettle();

    expect(repo.intents.single['kind'], 'link_repo');
    expect(repo.intents.single['payload'], {'repo': 'Flexingg/lumen-launcher', 'coder': 'agy'});
  });

  testWidgets('A Plan reply becomes an issue card, and Create issue asks the agent to file it',
      (tester) async {
    final lumen = project('lumen');
    final repo = FakeRepo()
      ..projectList = [lumen]
      ..threads = {
        'plan1': [
          ChatMessage(
              id: '41',
              sessionId: 'plan1',
              role: ChatMessageRole.assistant,
              text: draftText,
              timestamp: DateTime(2026, 9, 26)),
        ],
      };
    final state = await stateWith(repo);
    await tester.pumpWidget(host(
        state, ChatThreadPage(sessionId: 'plan1', name: 'lumen', project: lumen, planMode: true)));
    await tester.pumpAndSettle();

    // the bubble shows the prose, the card shows the draft (not the raw JSON)
    expect(find.textContaining('issue-draft'), findsNothing);
    expect(find.text('Add a fasting card'), findsOneWidget);
    expect(find.text('Card shows hours fasted'), findsOneWidget);
    expect(find.text('Plan mode · Flexingg/lumen'), findsOneWidget);

    // edit the title before filing
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Add a fasting card'), 'Add a fasting card to Home');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('create-issue')));
    await tester.pumpAndSettle();

    final call = repo.intents.single;
    expect(call['kind'], 'file_issue');
    expect(call['project'], 'lumen');
    expect(call['sessionId'], 'plan1');
    expect((call['payload'] as Map)['draft']['title'], 'Add a fasting card to Home');
    expect(find.text('Filed #7 and queued it.'), findsOneWidget);
    expect(find.byKey(const Key('create-issue')), findsNothing); // filed: no second tap

    await tester.pumpWidget(const SizedBox()); // dispose: stops the thread poll
  });
}
