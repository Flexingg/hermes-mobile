import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/data/api_failure.dart';
import 'package:hermes_mobile/data/hermes_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

HermesRepository repoFor(MockClient client, {String? token = 'tok'}) =>
    HermesRepository(baseUrl: 'http://bridge.test:9130', token: token, client: client);

void main() {
  group('HTTP failures', () {
    test('carries the server detail instead of a bare status code', () async {
      final repo = repoFor(MockClient((_) async =>
          http.Response('{"detail":"path outside allowed roots"}', 403)));
      await expectLater(
        repo.downloadFile('/etc/passwd'),
        throwsA(isA<ApiFailure>()
            .having((e) => e.status, 'status', 403)
            .having((e) => e.detail, 'detail', 'path outside allowed roots')),
      );
    });

    test('a 404 is reported as a missing route, not as "offline"', () async {
      final repo = repoFor(MockClient((_) async =>
          http.Response('{"detail":"Not Found"}', 404)));
      try {
        await repo.cronJobs();
        fail('expected ApiFailure');
      } on ApiFailure catch (e) {
        expect(e.isMissingRoute, isTrue);
        expect(e.isOffline, isFalse);
        expect(e.toString(), contains('/api/v1/cron'));
      }
    });

    test('a dead socket is offline (status 0), not a made-up HTTP code', () async {
      final repo = repoFor(MockClient((_) async => throw const SocketException('refused')));
      try {
        await repo.sessions();
        fail('expected ApiFailure');
      } on ApiFailure catch (e) {
        expect(e.isOffline, isTrue);
        expect(e.detail, contains('could not reach'));
      }
    });
  });

  group('previewUrl', () {
    test('carries the token as ?token= (a WebView cannot send a header)', () {
      final repo = repoFor(MockClient((_) async => http.Response('{}', 200)),
          token: 'a b&c');
      final url = repo.previewUrl('/home/hermes/report card.html');
      expect(url, startsWith('http://bridge.test:9130/html/'));
      expect(url, contains('report%20card.html'));
      // Query-encoded, because a raw '&'/' ' would corrupt the query string.
      expect(url, endsWith('?token=a+b%26c'));
    });

    test('omits the query entirely when no token is configured', () {
      final repo = repoFor(MockClient((_) async => http.Response('{}', 200)), token: null);
      expect(repo.previewUrl('/tmp/a.html'), 'http://bridge.test:9130/html/tmp/a.html');
    });
  });

  group('reconnect', () {
    test('backoff doubles then caps at 8s', () {
      expect(HermesRepository.reconnectDelay(0), const Duration(milliseconds: 250));
      expect(HermesRepository.reconnectDelay(1), const Duration(milliseconds: 500));
      expect(HermesRepository.reconnectDelay(2), const Duration(seconds: 1));
      expect(HermesRepository.reconnectDelay(3), const Duration(seconds: 2));
      expect(HermesRepository.reconnectDelay(4), const Duration(seconds: 4));
      expect(HermesRepository.reconnectDelay(5), const Duration(seconds: 8));
      expect(HermesRepository.reconnectDelay(9), const Duration(seconds: 8));
    });

    test('gives up with an ApiFailure that says how many attempts were made',
        () async {
      // Port 1 is reserved and refuses connections.
      final repo = HermesRepository(baseUrl: 'http://127.0.0.1:1', token: 't');
      try {
        await repo.openSocket('/ws/chat/x', attempts: 2);
        fail('expected ApiFailure');
      } on ApiFailure catch (e) {
        expect(e.method, 'WS');
        expect(e.isOffline, isTrue);
        expect(e.detail, contains('after 2 attempts'));
      }
    });
  });

  group('WebSocket streaming', () {
    late HttpServer server;
    late StreamSubscription<HttpRequest> sub;
    String? seenAuth;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      sub = server.listen((req) async {
        if (!WebSocketTransformer.isUpgradeRequest(req)) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        seenAuth = req.headers.value('authorization');
        final ws = await WebSocketTransformer.upgrade(req);
        ws.add(jsonEncode({'event': 'chunk', 'type': 'answer', 'delta': 'hi '}));
        ws.add(jsonEncode({'event': 'chunk', 'type': 'answer', 'delta': 'there'}));
        ws.add(jsonEncode({'event': 'done'}));
        await ws.close();
      });
    });

    tearDown(() async {
      await sub.cancel();
      await server.close(force: true);
    });

    test('sendMessage authenticates the upgrade and streams the reply', () async {
      final repo = HermesRepository(
        baseUrl: 'http://127.0.0.1:${server.port}',
        token: 'tok',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      final msgs = await repo.sendMessage('s1', 'hello').toList();

      // The bridge authenticates the WebSocket handshake itself — an HTTP
      // middleware never runs for the WS scope — so the bearer must be on it.
      expect(seenAuth, 'Bearer tok');
      expect(msgs, isNotEmpty);
      expect(msgs.last.text, 'hi there');
      expect(msgs.last.isAssistant, isTrue);
    });

    test('a stream that never opens does not hang the app', () async {
      final repo = HermesRepository(baseUrl: 'http://127.0.0.1:1', token: 't');
      await expectLater(
        repo.sendMessage('s1', 'hello').toList(),
        throwsA(isA<ApiFailure>()),
      );
    });

    test('a reply cut off mid-stream is an error, not a finished answer',
        () async {
      // Server sends a chunk and then the socket dies WITHOUT `done` — the old
      // code just ended the loop, so a truncated reply was marked "sent".
      final dying = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sub2 = dying.listen((req) async {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.add(jsonEncode({'event': 'chunk', 'type': 'answer', 'delta': 'half an answ'}));
        await ws.close();
      });
      addTearDown(() async {
        await sub2.cancel();
        await dying.close(force: true);
      });

      final repo = HermesRepository(
        baseUrl: 'http://127.0.0.1:${dying.port}',
        token: 'tok',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await expectLater(
        repo.sendMessage('s1', 'hello').toList(),
        throwsA(isA<ApiFailure>()
            .having((e) => e.detail, 'detail', contains('ended before the reply finished'))),
      );
    });

    test('runCronJob tolerates the bridge\'s {"ok": true} response', () async {
      // It used to build a CronJob from that body — a TypeError thrown *after*
      // the run had already been queued.
      final repo = repoFor(MockClient((_) async => http.Response('{"ok":true}', 200)));
      await repo.runCronJob('abc123456789');
    });
  });
}
