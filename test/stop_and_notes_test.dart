import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/core/config/app_config.dart';
import 'package:hermes_mobile/data/app_repository.dart';
import 'package:hermes_mobile/data/models.dart';
import 'package:hermes_mobile/data/project_models.dart';
import 'package:hermes_mobile/features/chat/composer.dart';
import 'package:hermes_mobile/features/projects/project_page.dart';
import 'package:hermes_mobile/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stop and Notes, the two things the user asked for by hand.
///
/// Stop is two-stage, and the tests follow the taps rather than the state:
/// tap one must ASK (graceful), tell nothing to the bridge that kills anything,
/// and change the button; tap two must confirm first and only then kill.
/// Notes must stay the user's own: they are stored and shown, never merged into
/// the agent's memory.
class _Repo implements AppRepository {
  final List<Map<String, Object?>> stopCalls = [];
  final List<String> added = [];
  List<ProjectNote> notes = [];
  List<Project> projectList = [];

  @override
  Future<String> stopTurn(String sessionId, {bool hard = false}) async {
    stopCalls.add({'session': sessionId, 'hard': hard});
    return hard ? 'hard' : 'graceful';
  }

  @override
  Future<List<ProjectNote>> projectNotes(String id) async => notes;

  @override
  Future<ProjectNote> addProjectNote(String id, String text) async {
    added.add(text);
    final n = ProjectNote(id: 'n-${notes.length}', text: text, at: DateTime.now());
    notes = [...notes, n];
    return n;
  }

  @override
  Future<ProjectNote> editProjectNote(String id, String noteId, String text) async {
    notes = notes.map((n) => n.id == noteId
        ? ProjectNote(id: n.id, text: text, at: n.at, updatedAt: DateTime.now())
        : n).toList();
    return notes.firstWhere((n) => n.id == noteId);
  }

  @override
  Future<void> deleteProjectNote(String id, String noteId) async {
    notes = notes.where((n) => n.id != noteId).toList();
  }

  @override
  Future<List<MemoryEntry>> memoryEntries({String? category, String? profile}) async => [];

  @override
  Future<List<Project>> projects() async => projectList;

  @override
  Future<Project> project(String id) async => projectList.firstWhere((p) => p.id == id);

  @override
  Future<List<ChatSession>> projectSessions(String id) async => [];

  @override
  Future<List<ChatSession>> sessions() async => [];

  /// A turn that finishes immediately, so onDone runs.
  @override
  Stream<ChatMessage> sendMessage(String sessionId, String text,
          {List<Attachment> attachments = const [],
          String? mode,
          String? project,
          String? profile}) =>
      const Stream<ChatMessage>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_Repo: ${invocation.memberName}');
}

Project _project() => Project.fromJson({
      'id': 'hermes-mobile',
      'name': 'hermes-mobile',
      'repo': 'Flexingg/hermes-mobile',
      'profile': 'dev-hermes-mobile',
      'coder': 'claude',
      'status': 'idle',
      'counts': {'ready': 0, 'needs_you': 0, 'working': 0, 'queued': 0},
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppConfig config;
  late _Repo repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    config = await AppConfig.load();
    repo = _Repo();
  });

  AppState stateWith() {
    final s = AppState(config);
    s.repo = repo;
    return s;
  }

  Future<void> pumpComposer(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const Scaffold(body: MessageComposer()),
      ),
    ));
    await tester.pump();
  }

  testWidgets('the first tap asks the turn to stop after this step', (tester) async {
    final state = stateWith()
      ..activeSessionId = 's1'
      ..sending = true;
    await pumpComposer(tester, state);

    expect(find.byKey(const Key('stop-turn')), findsOneWidget);
    expect(find.byKey(const Key('stop-kill')), findsNothing);

    await tester.tap(find.byKey(const Key('stop-turn')));
    await tester.pump();
    await tester.pump();

    expect(repo.stopCalls, [
      {'session': 's1', 'hard': false}
    ]);
    expect(state.stopStage, 1);
    expect(state.stoppingHard, isFalse);
    // The button changed shape: a different key, so a different widget.
    expect(find.byKey(const Key('stop-turn')), findsNothing);
    expect(find.byKey(const Key('stop-kill')), findsOneWidget);
  });

  testWidgets('the second tap confirms before it kills anything', (tester) async {
    final state = stateWith()
      ..activeSessionId = 's1'
      ..sending = true
      ..stopStage = 1;
    await pumpComposer(tester, state);

    await tester.tap(find.byKey(const Key('stop-kill')));
    await tester.pumpAndSettle();
    expect(find.text('Kill it now?'), findsOneWidget);

    // Backing out kills nothing.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repo.stopCalls, isEmpty);
    expect(state.stopStage, 1);

    await tester.tap(find.byKey(const Key('stop-kill')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('stop-kill-confirm')));
    await tester.pump(); // no pumpAndSettle: the confirmed button spins
    await tester.pump();

    expect(repo.stopCalls, [
      {'session': 's1', 'hard': true}
    ]);
    expect(state.stopStage, 2);
    expect(find.byKey(const Key('stop-confirmed')), findsOneWidget);
  });

  testWidgets('there is no Stop button when nothing is running', (tester) async {
    final state = stateWith()..activeSessionId = 's1';
    await pumpComposer(tester, state);
    expect(find.byKey(const Key('stop-turn')), findsNothing);
    expect(find.byKey(const Key('stop-kill')), findsNothing);
  });

  test('Stop is a no-op when nothing is running — it does not reset a stage it '
      'cannot see', () async {
    final state = stateWith()
      ..activeSessionId = 's1'
      ..stopStage = 2;
    await state.stopTurn();
    expect(repo.stopCalls, isEmpty);
    expect(state.stopStage, 2);
  });

  test('a finished turn puts Stop back to its first stage', () async {
    final state = stateWith()..activeSessionId = 's1';
    await state.sendMessage('hi');
    await Future<void>.delayed(Duration.zero);
    expect(state.sending, isFalse);
    expect(state.stopStage, 0);
  });

  testWidgets('the Notes tab is the user\'s own scratch space', (tester) async {
    repo.projectList = [_project()];
    repo.notes = [
      ProjectNote(id: 'n-0', text: 'maybe the stops should be a segmented control',
          at: DateTime.now().subtract(const Duration(minutes: 5))),
    ];
    final state = stateWith();
    await state.loadProjects();

    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const ProjectPage(projectId: 'hermes-mobile', initialTab: 2),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note-n-0')), findsOneWidget);
    expect(find.text('maybe the stops should be a segmented control'), findsOneWidget);
    // The agent's memory is a different tab with different content.
    expect(find.textContaining('Nothing here is sent to the agent'), findsOneWidget);
  });

  testWidgets('jotting a note saves it and shows it', (tester) async {
    repo.projectList = [_project()];
    final state = stateWith();
    await state.loadProjects();

    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const ProjectPage(projectId: 'hermes-mobile', initialTab: 2),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('No notes yet.'), findsOneWidget);

    await tester.tap(find.byTooltip('Jot a note'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'the gates could cache pub packages');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(repo.added, ['the gates could cache pub packages']);
    expect(find.text('the gates could cache pub packages'), findsOneWidget);
    expect(state.projectNotesFor('hermes-mobile'), hasLength(1));
  });
}
