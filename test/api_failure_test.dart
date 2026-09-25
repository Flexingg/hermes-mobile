import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/data/api_failure.dart';

void main() {
  group('parseApiDetail', () {
    test('reads the bridge\'s {"detail": ...}', () {
      expect(parseApiDetail('{"detail":"path outside allowed roots"}'),
          'path outside allowed roots');
      expect(parseApiDetail('{"detail":"unauthorized"}'), 'unauthorized');
    });

    test('reads the coach endpoints\' {"error": ...}', () {
      expect(parseApiDetail('{"error":"sparky unreachable"}'), 'sparky unreachable');
    });

    test('reads FastAPI 422 validation lists', () {
      final body = jsonEncode({
        'detail': [
          {'loc': ['body', 'name'], 'msg': 'field required', 'type': 'value_error'}
        ]
      });
      expect(parseApiDetail(body), 'field required');
    });

    test('falls back to the raw body and truncates it', () {
      expect(parseApiDetail('  gateway blew up  '), 'gateway blew up');
      expect(parseApiDetail('<html>${'x' * 500}')!.length, 301); // 300 + ellipsis
    });

    test('returns null for an empty body', () {
      expect(parseApiDetail(''), isNull);
      expect(parseApiDetail('   '), isNull);
      expect(parseApiDetail('{}'), isNull);
    });
  });

  group('ApiFailure', () {
    test('classifies auth / missing route / offline', () {
      expect(ApiFailure('GET', '/x', 401, null).isAuth, isTrue);
      expect(ApiFailure('GET', '/x', 403, null).isAuth, isTrue);
      expect(ApiFailure('GET', '/x', 404, null).isMissingRoute, isTrue);
      expect(ApiFailure('POST', '/x', 405, null).isMissingRoute, isTrue);
      expect(ApiFailure('POST', '/x', 501, null).isMissingRoute, isTrue);
      expect(ApiFailure('GET', '/x', 0, null).isOffline, isTrue);
      expect(ApiFailure('GET', '/x', 500, null).isOffline, isFalse);
    });

    test('says why, not just "exception"', () {
      // The old code threw Exception('GET /api/v1/cron → 404'); the bridge's own
      // explanation never reached the user.
      final e = ApiFailure('POST', '/api/v1/memory', 400, 'content required');
      expect(e.toString(), contains('content required'));
      expect(e.toString(), contains('POST'));
      expect(e.toString(), contains('400'));

      expect(ApiFailure('GET', '/x', 0, null).toString(), contains('no response'));
    });
  });
}
