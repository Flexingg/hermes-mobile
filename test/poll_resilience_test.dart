import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/core/config/app_config.dart';
import 'package:hermes_mobile/data/api_failure.dart';
import 'package:hermes_mobile/data/app_repository.dart';
import 'package:hermes_mobile/data/models.dart';
import 'package:hermes_mobile/data/project_models.dart';
import 'package:hermes_mobile/features/chat/composer.dart';
import 'package:hermes_mobile/features/projects/projects_page.dart';
import 'package:hermes_mobile/state/app_state.dart';
import 'package:hermes_mobile/state/poll_schedule.dart';
import 'package:hermes_mobile/widgets/common.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The unreachable-bridge storm (#17): overlapping polls every few seconds,
/// each timing out after 15 s, each putting the banner back. These follow what
/// the user would see — how many requests leave the phone, how many strips and
/// log rows appear — rather than the internals.
class _Repo implements AppRepository {
  int projectCalls = 0;
  int inFlight = 0;
  int maxInFlight = 0;

  /// What the next `projects()` does; null answers with an empty list.
  Future<List<Project>> Function()? onProjects;

  bool statusUp = true;

  @override
  Future<List<Project>> projects() async {
    projectCalls++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      return await (onProjects?.call() ?? Future.value(<Project>[]));
    } finally {
      inFlight--;
    }
  }

  @override
  Future<ServerStatus> serverStatus() async {
    if (!statusUp) throw _offline('/api/v1/status');
    return ServerStatus(
      cpu: 0,
      memory: 0,
      disk: 0,
      uptime: '1m',
      gatewayUp: true,
      activeSessions: 0,
      version: 'test',
      fetchedAt: DateTime.now(),
    );
  }

  @override
  Future<void> registerDevice(String token) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_Repo: ${invocation.memberName}');
}

ApiFailure _offline(String path) =>
    ApiFailure('GET', path, 0, 'could not reach http://192.168.1.146:9130: timed out');

const _projects = 'projects';
const _normal = Duration(seconds: 15);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppConfig config;
  late _Repo repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      // What AppConfig persists for a paired bridge, so the strip can name it.
      'cfg_server_base': 'http://192.168.1.146:9130',
    });
    config = await AppConfig.load();
    repo = _Repo();
  });

  AppState stateWith() {
    final s = AppState(config)
      ..repo = repo
      ..connected = true;
    return s;
  }

  Future<void> tick(AppState state, {bool userInitiated = false}) => state.pollTick(
      _projects, () => state.loadProjects(),
      normal: _normal, userInitiated: userInitiated);

  group('PollSchedule', () {
    test('normal -> 30 s -> 60 s cap, and one success puts it back', () {
      for (final normal in const [5, 10, 15]) {
        final s = PollSchedule(Duration(seconds: normal));
        expect(s.interval, Duration(seconds: normal));
        expect(s.backedOff, isFalse);
        s.onFailure();
        expect(s.interval, PollSchedule.slow);
        expect(s.backedOff, isTrue);
        s.onFailure();
        expect(s.interval, PollSchedule.cap);
        s.onFailure();
        expect(s.interval, PollSchedule.cap);
        s.onSuccess();
        expect(s.interval, Duration(seconds: normal));
        s.onFailure();
        s.reset();
        expect(s.interval, Duration(seconds: normal));
      }
    });
  });

  test('a tick whose previous call is still running is skipped, not queued',
      () async {
    final state = stateWith();
    repo.onProjects = () => Completer<List<Project>>().future; // never answers

    unawaited(tick(state));
    unawaited(tick(state));
    await Future<void>.delayed(Duration.zero);

    expect(state.pollRuns(_projects), 1);
    expect(state.pollSkips(_projects), 1);
    expect(repo.projectCalls, 1);
  });

  testWidgets('ProjectsPage never stacks requests on a bridge slower than its poll',
      (tester) async {
    final state = stateWith();
    // Every answer takes as long as the poll interval itself.
    repo.onProjects = () =>
        Future<List<Project>>.delayed(const Duration(seconds: 15), () => const []);

    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const ProjectsPage(),
      ),
    ));
    const elapsed = Duration(minutes: 2);
    for (var t = Duration.zero; t < elapsed; t += const Duration(seconds: 1)) {
      await tester.pump(const Duration(seconds: 1));
    }

    expect(repo.maxInFlight, 1, reason: 'no overlapping requests');
    expect(repo.projectCalls, lessThanOrEqualTo(elapsed.inSeconds ~/ _normal.inSeconds + 1));
    expect(repo.projectCalls, greaterThan(1), reason: 'it still polls');

    // Tear down so the page's timer and the last slow answer don't outlive it.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 15));
  });

  group('cadence', () {
    test('backs off 30 s then 60 s and stays; the first success resets it', () async {
      final state = stateWith();
      repo.onProjects = () => Future.error(_offline('/api/v1/projects'));

      await tick(state);
      expect(state.pollInterval(_projects, _normal), const Duration(seconds: 30));

      // While disconnected nothing polls, so the interval holds.
      await tick(state);
      expect(repo.projectCalls, 1);
      expect(state.pollInterval(_projects, _normal), const Duration(seconds: 30));

      // A flapping bridge: something reconnected, then the next poll failed too.
      state.connected = true;
      await tick(state);
      expect(state.pollInterval(_projects, _normal), const Duration(seconds: 60));
      state.connected = true;
      await tick(state);
      expect(state.pollInterval(_projects, _normal), const Duration(seconds: 60));

      repo.onProjects = null; // the bridge answers
      state.connected = true;
      await tick(state);
      expect(state.pollInterval(_projects, _normal), _normal);
    });

    test('an answered failure (500) backs off without going offline', () async {
      final state = stateWith();
      repo.onProjects =
          () => Future.error(ApiFailure('GET', '/api/v1/projects', 500, 'boom'));

      await tick(state);
      await tick(state);
      await tick(state);
      expect(repo.projectCalls, 3);
      expect(state.pollInterval(_projects, _normal), const Duration(seconds: 60));
      expect(state.offline, isFalse);
      expect(state.connected, isTrue);
      expect(state.errorLog, hasLength(1));
      expect(state.errorLog.first, contains('(×3'));
    });

    test('a user-initiated refresh resets the cadence immediately', () async {
      final state = stateWith();
      repo.onProjects =
          () => Future.error(ApiFailure('GET', '/api/v1/projects', 500, 'boom'));
      await tick(state);
      await tick(state);
      expect(state.pollInterval(_projects, _normal), const Duration(seconds: 60));

      final answer = Completer<List<Project>>();
      repo.onProjects = () => answer.future;
      final pull = tick(state, userInitiated: true);
      // Reset as soon as the user asks, not when the answer comes back.
      expect(state.pollInterval(_projects, _normal), _normal);
      answer.complete(const []);
      await pull;
      expect(state.pollInterval(_projects, _normal), _normal);
    });
  });

  test('N failed polls are one offline strip and one log row with a count',
      () async {
    final state = stateWith();
    repo.onProjects = () => Future.error(_offline('/api/v1/projects'));
    var notifications = 0;

    const n = 8; // a 15 s poll's worth of failures over two minutes
    for (var i = 0; i < n; i++) {
      state.connected = true; // flapping: each poll finds a "connected" app
      await tick(state);
    }

    expect(repo.projectCalls, n);
    expect(state.offline, isTrue);
    expect(state.connected, isFalse);
    expect(state.offlineMessage, "Can't reach the bridge at 192.168.1.146:9130");
    expect(state.error, isNull, reason: 'a poll never raises the banner');
    expect(state.errorLog, hasLength(1));
    expect(state.errorLog.first, contains('(×$n'));

    // Closed by the user: the same condition must not bring it back.
    state.dismissOffline();
    state.addListener(() => notifications++);
    state.connected = true;
    await tick(state);
    expect(state.offlineDismissed, isTrue);
    expect(state.offlineMessage, "Can't reach the bridge at 192.168.1.146:9130");
    expect(state.errorLog, hasLength(1));
    expect(state.errorLog.first, contains('(×${n + 1}'));
    expect(notifications, lessThanOrEqualTo(2),
        reason: 'the loader and the tick; the strip itself does not re-fire');
  });

  test('user-triggered failures still get the banner', () async {
    final state = stateWith();
    state.reportError(_offline('/api/v1/sessions/s1/messages'), context: 'send');
    expect(state.error, contains('send'));
    expect(state.offline, isFalse);
  });

  group('nothing polls what cannot work', () {
    test('no call while the app is backgrounded', () async {
      final state = stateWith()..lifecycle = AppLifecycleState.paused;
      await tick(state);
      expect(repo.projectCalls, 0);
      state.lifecycle = AppLifecycleState.resumed;
      await tick(state);
      expect(repo.projectCalls, 1);
    });

    test('no call while disconnected', () async {
      final state = stateWith()..connected = false;
      await tick(state);
      expect(repo.projectCalls, 0);
    });
  });

  test('a missing route is named once as an older bridge and never re-polled',
      () async {
    final state = stateWith();
    repo.onProjects = () =>
        Future.error(ApiFailure('GET', '/api/v1/projects', 404, 'Not Found'));

    await tick(state);
    expect(state.error, contains('older build'));
    expect(state.error, contains('GET /api/v1/projects'));
    expect(state.errorLog, hasLength(1));
    expect(state.pollStopped(_projects), isTrue);
    expect(state.connected, isTrue, reason: 'the bridge answered; it is just old');

    for (var i = 0; i < 5; i++) {
      await tick(state);
    }
    expect(repo.projectCalls, 1);
    expect(state.errorLog, hasLength(1));

    // Even asked for again by hand, the same dead route is not re-announced.
    await tick(state, userInitiated: true);
    expect(repo.projectCalls, 2);
    expect(state.errorLog, hasLength(1));
  });

  test('Stop on a bridge without the route stays disabled instead of resetting',
      () async {
    final state = stateWith()
      ..activeSessionId = 's1'
      ..sending = true;
    final stopRepo = _StopRepo();
    state.repo = stopRepo;

    await state.stopTurn();
    expect(state.stopUnavailable, isTrue);
    expect(state.stopRequested, isFalse);
    expect(state.error, contains('older build'));

    // Tapping again (if anything could) sends nothing more.
    await state.stopTurn();
    await state.stopTurn(hard: true);
    expect(stopRepo.calls, 1);
    expect(state.errorLog, hasLength(1));
  });

  testWidgets('the Stop button shows it failed, and never re-invites the tap',
      (tester) async {
    final state = stateWith()
      ..activeSessionId = 's1'
      ..sending = true;
    state.repo = _StopRepo();
    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const Scaffold(body: MessageComposer()),
      ),
    ));
    await tester.tap(find.byKey(const Key('stop-turn')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('stop-turn')), findsNothing);
    final failed = tester.widget<IconButton>(find.byKey(const Key('stop-failed')));
    expect(failed.onPressed, isNull);
    expect(failed.tooltip, contains('older build'));
  });

  testWidgets('the offline strip carries a Retry', (tester) async {
    var retried = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ErrorBanner(
          offline: true,
          message: "Can't reach the bridge at 192.168.1.146:9130",
          onRetry: () => retried = true,
          onDismiss: () {},
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('offline-retry')));
    expect(retried, isTrue);
  });

  test('Retry after recovery clears the strip and polling resumes at normal pace',
      () async {
    final state = stateWith();
    repo.onProjects = () => Future.error(_offline('/api/v1/projects'));
    await tick(state);
    expect(state.offline, isTrue);
    expect(state.connected, isFalse);

    // Still down: Retry puts the strip back, never a banner.
    repo.statusUp = false;
    await state.retry();
    expect(state.offline, isTrue);
    expect(state.error, isNull);
    expect(state.connected, isFalse);

    // The bridge is back.
    repo.statusUp = true;
    repo.onProjects = null;
    await state.retry();
    expect(state.offline, isFalse);
    expect(state.offlineMessage, isNull);
    expect(state.connected, isTrue);
    expect(state.pollInterval(_projects, _normal), _normal);

    final before = repo.projectCalls;
    await tick(state);
    expect(repo.projectCalls, before + 1);
    expect(state.pollInterval(_projects, _normal), _normal);
  });
}

class _StopRepo implements AppRepository {
  int calls = 0;

  @override
  Future<String> stopTurn(String sessionId, {bool hard = false}) async {
    calls++;
    throw ApiFailure('POST', '/api/v1/sessions/$sessionId/stop', 404, 'Not Found');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_StopRepo: ${invocation.memberName}');
}
