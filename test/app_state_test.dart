import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/core/config/app_config.dart';
import 'package:hermes_mobile/data/api_failure.dart';
import 'package:hermes_mobile/data/app_repository.dart';
import 'package:hermes_mobile/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every method answers with a real bridge failure — the "the bridge is down /
/// that route does not exist" case that used to be swallowed silently.
class _ExplodingRepo implements AppRepository {
  _ExplodingRepo(this.failure);
  final Object failure;

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<Never>.error(failure);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppConfig config;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    config = await AppConfig.load();
  });

  test('a failing loader surfaces the error instead of swallowing it', () async {
    final state = AppState(config);
    state.repo = _ExplodingRepo(
        ApiFailure('GET', '/api/v1/groups', 404, '{"detail":"Not Found"}'));
    expect(state.error, isNull);

    await state.loadGroups();

    // Before: `catch (_) {}` — the screen just stayed empty.
    expect(state.error, isNotNull);
    expect(state.error, contains('404'));
    expect(state.errorLog, hasLength(1));
    expect(state.errorLog.first, contains('load groups'));
  });

  test('bot, pet and thread reloads all report their failures', () async {
    final state = AppState(config);
    state.repo = _ExplodingRepo(ApiFailure('GET', '/api/v1/bots', 0, 'refused'));

    await state.loadBots();
    await state.loadBotPets();
    await state.refreshThread('s1');

    expect(state.errorLog, hasLength(3));
    expect(state.errorLog.any((l) => l.contains('load bots')), isTrue);
    expect(state.errorLog.any((l) => l.contains('load pets')), isTrue);
    expect(state.errorLog.any((l) => l.contains('reload thread')), isTrue);
    expect(state.errorLog.first, contains('reload thread')); // newest first
  });

  test('the error log is bounded — a flapping bridge cannot grow it forever',
      () async {
    final state = AppState(config);
    for (var i = 0; i < AppState.maxErrorLog + 10; i++) {
      state.reportError('boom $i');
    }
    expect(state.errorLog, hasLength(AppState.maxErrorLog));
    // Newest kept, oldest dropped.
    expect(state.errorLog.first, contains('boom 59'));
    expect(state.errorLog.last, contains('boom 10'));
  });

  test('clearError resets both the banner and the log', () async {
    final state = AppState(config);
    state.reportError('nope');
    state.clearError();
    expect(state.error, isNull);
    expect(state.errorLog, isEmpty);
  });
}
