import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/core/config/app_config.dart';
import 'package:hermes_mobile/data/app_repository.dart';
import 'package:hermes_mobile/data/models.dart';
import 'package:hermes_mobile/features/assistant/assistant_bar.dart';
import 'package:hermes_mobile/features/assistant/assistant_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

ChatSession _session(String id, {String profileId = 'lumen'}) => ChatSession(
      id: id,
      title: id,
      lastPreview: '',
      lastTimestamp: DateTime(2026),
      profileId: profileId,
    );

/// Answers only what the assistant bootstrap uses; anything else is a bug in
/// the code under test and fails loudly.
class _SessionRepo implements AppRepository {
  _SessionRepo(this.existing);
  final List<ChatSession> existing;
  final created = <({String title, String profileId})>[];

  @override
  Future<List<ChatSession>> sessions() async => existing;

  @override
  Future<ChatSession> createSession(String title, String profileId) async {
    created.add((title: title, profileId: profileId));
    return _session('new-${created.length}', profileId: profileId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AssistantAskBar', () {
    testWidgets('says it is not connected instead of showing a dead bar',
        (tester) async {
      await tester.pumpWidget(_host(AssistantAskBar(
        connected: false,
        onSend: (_) async {},
      )));
      expect(find.text('not connected — open Mercury'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('Send'), findsNothing);
    });

    testWidgets('connected: a text field and the input actions', (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(_host(AssistantAskBar(
        connected: true,
        onSend: (t) async => sent.add(t),
        onCamera: (_) async {},
      )));
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('not connected — open Mercury'), findsNothing);
      expect(find.byTooltip('Take photo'), findsOneWidget);
      expect(find.byTooltip('Voice input'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '  what time is it  ');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(sent, ['what time is it']);
    });

    testWidgets('a failed turn is shown in the bar', (tester) async {
      await tester.pumpWidget(_host(AssistantAskBar(
        connected: true,
        onSend: (_) async {},
        question: 'hi',
        reply: 'partial',
        error: 'the live stream ended before the reply finished',
      )));
      expect(find.text('partial'), findsOneWidget);
      expect(find.textContaining('live stream ended'), findsOneWidget);
    });
  });

  group('AssistantSession.ensure', () {
    late AppConfig config;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      config = await AppConfig.load();
    });

    test('reuses the persisted session while the server still has it', () async {
      await config.setAssistantSessionId('asst');
      final repo = _SessionRepo([_session('proj-chat'), _session('asst')]);

      final id = await AssistantSession.ensure(config: config, repo: repo);

      expect(id, 'asst');
      expect(repo.created, isEmpty);
      expect(config.assistantSessionId, 'asst');
    });

    test('replaces a stale id with a new Assistant session and persists it',
        () async {
      await config.setAssistantSessionId('deleted');
      final repo = _SessionRepo([_session('proj-chat', profileId: 'lumen')]);

      final id = await AssistantSession.ensure(config: config, repo: repo);

      expect(id, 'new-1');
      expect(repo.created.single.title, AssistantSession.sessionName);
      expect(repo.created.single.profileId, 'lumen');
      expect(config.assistantSessionId, 'new-1');
      // It survives a reload: the overlay engine reads it from prefs.
      expect((await AppConfig.load()).assistantSessionId, 'new-1');
    });

    test('creates one on first use without inventing a profile', () async {
      final repo = _SessionRepo([]);

      final id = await AssistantSession.ensure(config: config, repo: repo);

      expect(id, 'new-1');
      expect(repo.created.single.profileId, '');
      expect(config.assistantSessionId, 'new-1');
    });

    test('never picks the last-open or a project chat', () async {
      final repo = _SessionRepo([_session('proj-chat'), _session('recent')]);

      final id = await AssistantSession.ensure(config: config, repo: repo);

      expect(id, isNot(anyOf('proj-chat', 'recent')));
      expect(repo.created, hasLength(1));
    });

    test('uses a list the caller already has instead of refetching', () async {
      await config.setAssistantSessionId('asst');
      final repo = _SessionRepo([]); // would force a create if consulted

      final id = await AssistantSession.ensure(
          config: config, repo: repo, sessions: [_session('asst')]);

      expect(id, 'asst');
      expect(repo.created, isEmpty);
    });
  });

  test('overlay is off by default and the flag persists', () async {
    SharedPreferences.setMockInitialValues({});
    final config = await AppConfig.load();
    expect(config.overlayEnabled, isFalse);
    await config.setOverlayEnabled(true);
    expect((await AppConfig.load()).overlayEnabled, isTrue);
    await config.setAssistantSessionId(null);
    expect((await AppConfig.load()).assistantSessionId, isNull);
  });
}
