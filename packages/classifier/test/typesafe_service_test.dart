import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:classifier/judgments.dart';
import 'package:classifier/typesafe_classifier.dart';

class TestClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  int closeCount = 0;
  TestClient(this.handler);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
  @override
  void close() => closeCount++;
}

TypeMatcher<JudgmentException> failure(JudgmentFailure kind) =>
    isA<JudgmentException>().having((e) => e.failure, 'failure', kind);

void main() {
  final q = NoulQuestion('ready', instructions: 'Ready?');
  final request =
      JudgmentRequest(state: {'task': 'Unicode café'}, questions: [q]);
  Map<String, Object?> result() => {
        'model': 'jev-latest',
        'answers': {
          'ready': {'type': 'noul', 'noul': 0.9}
        },
        'usage': {'input_tokens': 50, 'output_tokens': 10},
      };
  http.StreamedResponse response(
          [Object? body,
          int status = 200,
          Map<String, String> headers = const {}]) =>
      http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(body ?? result()))), status,
          headers: headers);

  test(
      'POST uses separate model, bearer auth and exact endpoint; closes client',
      () async {
    late TestClient client;
    client = TestClient((base) async {
      final sent = base as http.Request;
      expect(sent.method, 'POST');
      expect(sent.url.toString(), 'https://api.typesafe.ai/v1/systemone');
      expect(sent.followRedirects, isFalse);
      expect(sent.headers['Authorization'], 'Bearer test-key');
      expect(sent.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(sent.body), request.toJson(model: 'jev-pinned'));
      return response();
    });
    final service = TypeSafeJudgmentService(
        config: TypeSafeConfig(apiKey: 'test-key', model: 'jev-pinned'),
        clientFactory: () => client);
    expect((await service.evaluate(request)).answer(q).noul, 0.9);
    expect(client.closeCount, 1);
    service.close();
    service.close();
    expect(client.closeCount, 1);
  });

  final statuses = {
    401: JudgmentFailure.authentication,
    403: JudgmentFailure.permission,
    422: JudgmentFailure.invalidRequest,
    429: JudgmentFailure.rateLimited,
    529: JudgmentFailure.unavailable,
    503: JudgmentFailure.unavailable,
    302: JudgmentFailure.http,
    404: JudgmentFailure.http,
  };
  for (final entry in statuses.entries) {
    test(
        'HTTP ${entry.key} has typed failure and no hidden retries/leaked body',
        () async {
      var attempts = 0;
      final client = TestClient((_) async {
        attempts++;
        return response({'error': 'secret-test-key private-state'}, entry.key,
            {'retry-after': '3'});
      });
      final service = TypeSafeJudgmentService(
          config: TypeSafeConfig(apiKey: 'secret-test-key'),
          clientFactory: () => client);
      await expectLater(
          service.evaluate(request),
          throwsA(failure(entry.value)
              .having((e) => e.statusCode, 'status', entry.key)
              .having(
                  (e) => e.retryAfter, 'retryAfter', const Duration(seconds: 3))
              .having((e) => e.isRetryable, 'retryable',
                  {429, 529, 503}.contains(entry.key))
              .having(
                  (e) => e.toString(),
                  'redacted',
                  allOf(isNot(contains('secret-test-key')),
                      isNot(contains('private-state'))))));
      expect(attempts, 1);
      expect(client.closeCount, 1);
    });
  }

  test('Retry-After dates use injected clock', () async {
    final now = DateTime.utc(2026, 9, 17);
    final service = TypeSafeJudgmentService(
        config: TypeSafeConfig(apiKey: 'key'),
        now: () => now,
        clientFactory: () => TestClient((_) async => response(
            {},
            429,
            {
              'retry-after':
                  HttpDate.format(now.add(const Duration(seconds: 12)))
            })));
    await expectLater(
        service.evaluate(request),
        throwsA(isA<JudgmentException>().having(
            (e) => e.retryAfter, 'retryAfter', const Duration(seconds: 12))));
  });

  test('invalid Retry-After does not hide the original HTTP failure', () async {
    for (final header in ['garbage', '-5', '']) {
      final service = TypeSafeJudgmentService(
        config: TypeSafeConfig(apiKey: 'key'),
        clientFactory: () =>
            TestClient((_) async => response({}, 429, {'retry-after': header})),
      );
      await expectLater(
          service.evaluate(request),
          throwsA(failure(JudgmentFailure.rateLimited)
              .having((e) => e.retryAfter, 'retryAfter', isNull)));
    }
  });

  test('malformed JSON, invalid schema and invalid UTF-8 are protocol errors',
      () async {
    for (final bytes in [
      utf8.encode('not json'),
      utf8.encode('{"answers":{}}'),
      [255]
    ]) {
      final client = TestClient(
          (_) async => http.StreamedResponse(Stream.value(bytes), 200));
      final service = TypeSafeJudgmentService(
          config: TypeSafeConfig(apiKey: 'key'), clientFactory: () => client);
      await expectLater(service.evaluate(request),
          throwsA(failure(JudgmentFailure.invalidResponse)));
      expect(client.closeCount, 1);
    }
  });

  test('arbitrary body chunk boundaries, including UTF-8, are handled',
      () async {
    final data = result()..['metadata'] = '☃';
    final bytes = utf8.encode(jsonEncode(data));
    final service = TypeSafeJudgmentService(
        config: TypeSafeConfig(apiKey: 'key'),
        clientFactory: () => TestClient((_) async => http.StreamedResponse(
            Stream.fromIterable(bytes.map((byte) => [byte])), 200)));
    expect((await service.evaluate(request)).answer(q).noul, 0.9);
  });

  test('response size is bounded with or without Content-Length', () async {
    for (final declared in [null, 100]) {
      final client = TestClient((_) async => http.StreamedResponse(
          Stream.value(List.filled(100, 32)), 200,
          contentLength: declared));
      final service = TypeSafeJudgmentService(
          config: TypeSafeConfig(apiKey: 'key', maxResponseBytes: 50),
          clientFactory: () => client);
      await expectLater(service.evaluate(request),
          throwsA(failure(JudgmentFailure.responseTooLarge)));
      expect(client.closeCount, 1);
    }
  });

  test('pre-cancelled request allocates no transport', () async {
    final token = JudgmentCancellation()..cancel();
    final service = TypeSafeJudgmentService(
        config: TypeSafeConfig(apiKey: 'key'),
        clientFactory: () => throw StateError('must not allocate'));
    await expectLater(service.evaluate(request, cancellation: token),
        throwsA(failure(JudgmentFailure.cancelled)
            .having((e) => e.attempted, 'attempted', false)));
  });

  test('cancelling one request leaves its sibling usable', () async {
    final pending = Completer<http.StreamedResponse>();
    final first = TestClient((_) => pending.future);
    final second = TestClient((_) async => response());
    var count = 0;
    final service = TypeSafeJudgmentService(
        config: TypeSafeConfig(apiKey: 'key'),
        clientFactory: () => count++ == 0 ? first : second);
    final token = JudgmentCancellation();
    final cancelled = service.evaluate(request, cancellation: token);
    final expected =
        expectLater(cancelled, throwsA(failure(JudgmentFailure.cancelled)));
    final sibling = service.evaluate(request);
    token.cancel();
    token.cancel();
    await expected;
    expect((await sibling).answer(q).noul, 0.9);
    expect(first.closeCount, 1);
    expect(second.closeCount, 1);
    // A late transport failure after cancellation must remain observed.
    pending.completeError(http.ClientException('late error with secret'));
    await Future<void>.delayed(Duration.zero);
  });

  test('deadline bounds stalled headers and stalled body, closes transport',
      () async {
    final pending = Completer<http.StreamedResponse>();
    final body = StreamController<List<int>>();
    for (final handler
        in <Future<http.StreamedResponse> Function(http.BaseRequest)>[
      (_) => pending.future,
      (_) async => http.StreamedResponse(body.stream, 200),
    ]) {
      final client = TestClient(handler);
      final service = TypeSafeJudgmentService(
          config: TypeSafeConfig(
              apiKey: 'key', timeout: const Duration(milliseconds: 20)),
          clientFactory: () => client);
      await expectLater(
          service.evaluate(request), throwsA(failure(JudgmentFailure.timeout)));
      expect(client.closeCount, 1);
    }
    pending.completeError(http.ClientException('late timeout cleanup'));
    await body.close();
  });

  test('service close settles all active calls and refuses new ones', () async {
    final pending = Completer<http.StreamedResponse>();
    final clients = <TestClient>[];
    final service = TypeSafeJudgmentService(
        config: TypeSafeConfig(apiKey: 'key'),
        clientFactory: () {
          final client = TestClient((_) => pending.future);
          clients.add(client);
          return client;
        });
    final futures = List.generate(
        3,
        (_) => expectLater(service.evaluate(request),
            throwsA(failure(JudgmentFailure.closed)
                .having((e) => e.attempted, 'attempted', true))));
    service.close();
    service.close();
    await Future.wait(futures);
    expect(clients.every((c) => c.closeCount == 1), isTrue);
    await expectLater(
        service.evaluate(request), throwsA(failure(JudgmentFailure.closed)
            .having((e) => e.attempted, 'attempted', false)));
    expect(clients.length, 3);
    pending.completeError(http.ClientException('closed'));
  });

  test('network errors are classified without exposing underlying text',
      () async {
    final client =
        TestClient((_) async => throw http.ClientException('secret-key'));
    final service = TypeSafeJudgmentService(
        config: TypeSafeConfig(apiKey: 'key'), clientFactory: () => client);
    await expectLater(
        service.evaluate(request),
        throwsA(failure(JudgmentFailure.transport).having(
            (e) => e.toString(), 'safe', isNot(contains('secret-key')))));
  });

  test('configuration rejects invalid credentials, endpoints and limits', () {
    for (final key in ['', ' ', 'key\r\nInjected:yes']) {
      expect(() => TypeSafeConfig(apiKey: key), throwsArgumentError);
    }
    for (final endpoint in [
      'http://api.typesafe.ai/v1/systemone',
      '/relative',
      'https://user:password@example.com',
      'https://example.com/?key=secret'
    ]) {
      expect(() => TypeSafeConfig(apiKey: 'key', endpoint: Uri.parse(endpoint)),
          throwsArgumentError);
    }
    expect(
        () => TypeSafeConfig(apiKey: 'key', model: ' '), throwsArgumentError);
    expect(() => TypeSafeConfig(apiKey: 'key', timeout: Duration.zero),
        throwsArgumentError);
    expect(() => TypeSafeConfig(apiKey: 'key', maxResponseBytes: 0),
        throwsArgumentError);
  });

  test('real HTTP adapter does not follow redirects or leak auth to target',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var redirected = false;
    server.listen((incoming) async {
      if (incoming.uri.path == '/target') redirected = true;
      incoming.response.statusCode = 302;
      incoming.response.headers.set('location', '/target');
      await incoming.response.close();
    });
    final service = TypeSafeJudgmentService(
        config: TypeSafeConfig(
            apiKey: 'key',
            endpoint:
                Uri.parse('http://127.0.0.1:${server.port}/v1/systemone')));
    await expectLater(
        service.evaluate(request), throwsA(failure(JudgmentFailure.http)));
    expect(redirected, isFalse);
  });
}
