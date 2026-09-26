import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/core/config/app_config.dart';
import 'package:hermes_mobile/data/app_repository.dart';
import 'package:hermes_mobile/data/models.dart';
import 'package:hermes_mobile/features/assistant/ask_control.dart';
import 'package:hermes_mobile/features/assistant/ask_main.dart';
import 'package:hermes_mobile/features/assistant/assistant_bar.dart';
import 'package:hermes_mobile/features/assistant/assistant_session.dart';
import 'package:hermes_mobile/features/chat/input_actions.dart';
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

/// Records listen attempts instead of starting the platform recognizer.
class _FakeVoice extends VoiceInputController {
  int toggles = 0;

  @override
  Future<bool> toggle(void Function(String words) onWords) async {
    toggles++;
    return true;
  }
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
      // It survives a reload: the ask engine reads it from prefs.
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

  test('clearing the assistant session persists', () async {
    SharedPreferences.setMockInitialValues({});
    final config = await AppConfig.load();
    await config.setAssistantSessionId('asst');
    await config.setAssistantSessionId(null);
    expect((await AppConfig.load()).assistantSessionId, isNull);
  });

  group('AskArgs.fromMap', () {
    test('no extras open a plain, empty text bar', () {
      for (final map in <Map<Object?, Object?>?>[null, {}]) {
        final args = AskArgs.fromMap(map);
        expect(args.mode, 'text');
        expect(args.voice, isFalse);
        expect(args.text, '');
      }
    });

    test('mode voice listens; an unknown mode falls back to text', () {
      expect(AskArgs.fromMap({'mode': 'voice'}).voice, isTrue);
      expect(AskArgs.fromMap({'mode': 'nonsense'}).mode, 'text');
      expect(AskArgs.fromMap({'mode': 42}).mode, 'text');
    });

    test('text is a prefill', () {
      final args = AskArgs.fromMap({'text': 'what is on my calendar'});
      expect(args.text, 'what is on my calendar');
      expect(args.mode, 'text');
    });
  });

  group('ask intent in the bar', () {
    testWidgets('a prefill lands in the field and nothing is sent',
        (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(_host(AssistantAskBar(
        connected: true,
        initialText: 'what is on my calendar',
        onSend: (t) async => sent.add(t),
      )));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'what is on my calendar');
      expect(sent, isEmpty);
    });

    testWidgets('a second fire replaces the prefill, still without sending',
        (tester) async {
      final sent = <String>[];
      Widget bar(String text) => _host(AssistantAskBar(
            connected: true,
            initialText: text,
            onSend: (t) async => sent.add(t),
          ));
      await tester.pumpWidget(bar('first'));
      await tester.pumpWidget(bar('second'));
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'second');
      expect(sent, isEmpty);
    });

    testWidgets('voice mode starts exactly one listen', (tester) async {
      final voice = _FakeVoice();
      addTearDown(voice.dispose);
      await tester.pumpWidget(_host(AssistantAskBar(
        connected: true,
        autostartVoice: true,
        voiceInput: voice,
        onSend: (_) async {},
      )));
      await tester.pump();
      await tester.pump();
      expect(voice.toggles, 1);
    });

    testWidgets('voice mode waits for the probe: armed later, listens once',
        (tester) async {
      final voice = _FakeVoice();
      addTearDown(voice.dispose);
      Widget bar(bool listen) => _host(AssistantAskBar(
            connected: true,
            autostartVoice: listen,
            voiceInput: voice,
            onSend: (_) async {},
          ));
      await tester.pumpWidget(bar(false));
      await tester.pump();
      expect(voice.toggles, 0);
      await tester.pumpWidget(bar(true));
      await tester.pump();
      // A rebuild while still armed must not toggle the running listen off.
      await tester.pumpWidget(bar(true));
      await tester.pump();
      expect(voice.toggles, 1);
    });

    testWidgets('voice mode never listens while not connected', (tester) async {
      final voice = _FakeVoice();
      addTearDown(voice.dispose);
      await tester.pumpWidget(_host(AssistantAskBar(
        connected: false,
        autostartVoice: true,
        voiceInput: voice,
        onSend: (_) async {},
      )));
      await tester.pump();
      await tester.pump();
      expect(voice.toggles, 0);
    });

    testWidgets('AskApp with no server says not connected and offers no Send',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final config = await AppConfig.load();
      await tester.pumpWidget(AskApp(
        initial: (config: config, repo: null),
        args: const AskArgs(mode: 'voice', text: 'what is on my calendar'),
      ));
      await tester.pump();
      expect(find.text(AssistantAskBar.notConnectedText), findsOneWidget);
      expect(find.byTooltip('Send'), findsNothing);
      expect(find.byType(TextField), findsNothing);
    });
  });

  // `flutter test` runs from the package root, so these read the real files.
  group('Android wiring', () {
    test('the manifest has the ask intent and none of the overlay machinery',
        () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      for (final gone in [
        'SYSTEM_ALERT_WINDOW',
        'FOREGROUND_SERVICE',
        'OverlayService',
        'OverlayHostActivity',
        '<service',
      ]) {
        expect(manifest, isNot(contains(gone)), reason: gone);
      }
      expect(manifest, contains('com.randalls.hermes_mobile.action.ASK'));
      expect(manifest, contains('android.app.shortcuts'));
      expect(manifest, contains('android:name=".AskActivity"'));
    });

    test('both shortcuts target the installed package and the ask activity',
        () {
      final shortcuts =
          File('android/app/src/main/res/xml/shortcuts.xml').readAsStringSync();
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      final appId =
          RegExp(r'applicationId\s*=\s*"([^"]+)"').firstMatch(gradle)!.group(1)!;
      expect(shortcuts, contains('android:shortcutId="ask"'));
      expect(shortcuts, contains('android:shortcutId="ask_voice"'));
      expect(shortcuts, contains('android:value="text"'));
      expect(shortcuts, contains('android:value="voice"'));
      // Resources get no ${applicationId}: a shortcut aimed at the Kotlin
      // namespace instead would point at a package that isn't installed.
      expect(
          RegExp('android:targetPackage="([^"]+)"')
              .allMatches(shortcuts)
              .map((m) => m.group(1))
              .toList(),
          [appId, appId]);
      expect(
          'android:targetClass="com.randalls.hermes_mobile.AskActivity"'
              .allMatches(shortcuts)
              .length,
          2);
    });

    test('every label a shortcut references is a real string resource', () {
      // shortcutShortLabel/shortcutLongLabel are attribute references: a literal
      // label fails resource linking, which is a build-only failure no widget
      // test would ever catch (`flutter build apk` did).
      final shortcuts =
          File('android/app/src/main/res/xml/shortcuts.xml').readAsStringSync();
      final strings =
          File('android/app/src/main/res/values/strings.xml').readAsStringSync();
      final referenced = RegExp(r'@string/([A-Za-z0-9_]+)')
          .allMatches(shortcuts)
          .map((m) => m.group(1)!)
          .toSet();
      expect(referenced, isNotEmpty);
      for (final name in referenced) {
        expect(strings, contains('name="$name"'), reason: name);
      }
      for (final attr in ['shortcutShortLabel', 'shortcutLongLabel']) {
        expect(
            RegExp('android:$attr="(?!@string/)[^"]*"').hasMatch(shortcuts),
            isFalse,
            reason: '$attr must be a @string/ reference');
      }
    });
  });
}
