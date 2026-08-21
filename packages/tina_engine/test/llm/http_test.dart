import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:tina_engine/tina_engine.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  group('parseRetryAfter', () {
    test('integer seconds', () {
      expect(parseRetryAfter('5'), const Duration(seconds: 5));
      expect(parseRetryAfter('0'), Duration.zero);
    });

    test('whitespace tolerated', () {
      expect(parseRetryAfter('  12  '), const Duration(seconds: 12));
    });

    test('null and unparseable return null', () {
      expect(parseRetryAfter(null), isNull);
      expect(parseRetryAfter(''), isNull);
      expect(parseRetryAfter('soon'), isNull);
      // HTTP-date form intentionally unsupported — providers we target
      // don't use it. Treat as null rather than misparsing.
      expect(parseRetryAfter('Wed, 21 Oct 2026 07:28:00 GMT'), isNull);
    });

    test('negative is rejected', () {
      expect(parseRetryAfter('-5'), isNull);
    });

    test('clamps at 60s so a bad upstream cannot hang us for hours', () {
      expect(parseRetryAfter('99999'), const Duration(seconds: 60));
    });
  });

  group('humanizeException', () {
    test('SocketException with osError includes both messages', () {
      const sock = SocketException(
        'failed connect',
        osError: OSError('Connection refused', 111),
      );
      final out = humanizeException(sock);
      expect(out, contains('Network error'));
      expect(out, contains('failed connect'));
      expect(out, contains('Connection refused'));
    });

    test('SocketException without osError omits the parenthetical', () {
      const sock = SocketException('host down');
      expect(humanizeException(sock), 'Network error: host down');
    });

    test('TimeoutException with message passes through', () {
      expect(
        humanizeException(TimeoutException('request exceeded 30s ...')),
        'request exceeded 30s ...',
      );
    });

    test('anonymous TimeoutException (message \'\') falls back to legacy phrase', () {
      expect(
        humanizeException(TimeoutException('', const Duration(seconds: 30))),
        'Request timed out',
      );
    });

    test('unknown error falls back to toString', () {
      expect(humanizeException(StateError('boom')), contains('boom'));
    });
  });

  group('humanizeHttpError', () {
    test('extracts error.message and error.type from Anthropic-shaped JSON',
        () {
      final body = jsonEncode({
        'error': {
          'type': 'rate_limit_error',
          'message': 'slow down',
        },
      });
      expect(humanizeHttpError('Anthropic', 429, body),
          'Anthropic 429 (rate_limit_error): slow down');
    });

    test('handles message-only error shape', () {
      final body = jsonEncode({
        'error': {'message': 'bad request'},
      });
      expect(humanizeHttpError('OpenAI', 400, body),
          'OpenAI 400: bad request');
    });

    test('handles top-level message field', () {
      final body = jsonEncode({'message': 'forbidden'});
      expect(humanizeHttpError('X', 403, body), 'X 403: forbidden');
    });

    test('falls back to a body preview when not JSON', () {
      const body = '<html>500 Server Error</html>';
      final out = humanizeHttpError('X', 500, body);
      expect(out, contains('500'));
      expect(out, contains('html'));
    });

    test('truncates oversized previews', () {
      final big = 'x' * 1000;
      final out = humanizeHttpError('X', 502, big);
      expect(out.length, lessThan(280));
      expect(out, endsWith('…'));
    });
  });

  group('sendWithRetry', () {
    test('returns immediately on 200', () async {
      final client = _FakeClient([_ok('hello')]);
      final resp = await sendWithRetry(client, _buildReq);
      expect(resp.statusCode, 200);
      expect(client.callCount, 1);
    });

    test('retries on 429 and returns the eventual 200', () async {
      final client = _FakeClient([
        _status(429),
        _ok('hello'),
      ]);
      final resp = await sendWithRetry(client, _buildReq);
      expect(resp.statusCode, 200);
      expect(client.callCount, 2);
    });

    test('retries on SocketException', () async {
      final client = _FakeClient([
        _throw(const SocketException('reset')),
        _ok('hello'),
      ]);
      final resp = await sendWithRetry(client, _buildReq);
      expect(resp.statusCode, 200);
      expect(client.callCount, 2);
    });

    // #23b regression guard: socket exceptions keep the transport-internal
    // retry schedule (they DO clear); only wall-clock timeouts are terminal.
    test('retries on HttpException', () async {
      final client = _FakeClient([
        _throw(const HttpException('connection closed')),
        _ok('hello'),
      ]);
      final resp = await sendWithRetry(client, _buildReq);
      expect(resp.statusCode, 200);
      expect(client.callCount, 2);
    });

    test('gives up after exhausting attempts and returns the last response',
        () async {
      // 4 attempts = initial + 3 retries; all 429 → last 429 surfaces.
      final client = _FakeClient(List.generate(4, (_) => _status(429)));
      final resp = await sendWithRetry(client, _buildReq);
      expect(resp.statusCode, 429);
      expect(client.callCount, 4);
    });

    test('honors Retry-After in preference to the local backoff schedule',
        () async {
      // Local first-attempt delay is 250ms; Retry-After=1 should bump it to
      // ~1s. Loose lower bound (800ms) to avoid flake while still catching
      // the "we ignored the header" regression.
      final client = _FakeClient([
        _status(429, headers: const {'retry-after': '1'}),
        _ok('done'),
      ]);
      final sw = Stopwatch()..start();
      final resp = await sendWithRetry(client, _buildReq);
      sw.stop();
      expect(resp.statusCode, 200);
      expect(sw.elapsed, greaterThan(const Duration(milliseconds: 800)),
          reason: 'expected to wait ≈1s per Retry-After, not the 250ms default');
    });

    // #23b: timeout is TERMINAL — the retry loop must NOT burn the
    // schedule re-sending the same payload; it surfaces as a named
    // TimeoutException instead. (Previously this retried; now it doesn't.)
    test('request timeout on headers is terminal, names --request-timeout',
        () async {
      final client = _FakeClient([
        _hang(),
        // Would be attempt 2 if retries happened — must NOT reach.
        _ok('never reached'),
      ]);
      await expectLater(
        () => sendWithRetry(
          client,
          _buildReq,
          requestTimeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<TimeoutException>().having(
          (e) => e.message,
          'message',
          contains('--request-timeout'),
        )),
      );
      expect(client.callCount, 1,
          reason: 'timeout is terminal — no doomed retry');
    });

    // #23b: a TimeoutException thrown while awaiting response HEADERS is
    // TERMINAL for the retry loop — re-sending the same payload into the
    // same wall burns the 250/750/2250 schedule for nothing. It must NOT
    // retry, and the message must name --request-timeout.
    test('timeout on headers is terminal: exactly ONE attempt, named message',
        () async {
      final client = _FakeClient([
        _throw(TimeoutException(
          'request exceeded 2s without response headers — '
          'raise with --request-timeout',
          const Duration(seconds: 2),
        )),
        // A second attempt would confirm retry happened — must NOT run.
        _ok('never reached'),
      ]);
      await expectLater(
        () => sendWithRetry(
          client,
          _buildReq,
          requestTimeout: const Duration(seconds: 2),
        ),
        throwsA(isA<TimeoutException>()
            .having(
              (e) => e.message,
              'message',
              contains('--request-timeout'),
            )
            .having(
              (e) => e.duration,
              'duration',
              const Duration(seconds: 2),
            )),
      );
      expect(client.callCount, 1,
          reason: 'timeout must NOT retry — doomed re-send of same payload');
    });

    test('non-transient exception is rethrown without retry', () async {
      final client = _FakeClient([_throw(StateError('boom'))]);
      await expectLater(
        () => sendWithRetry(client, _buildReq),
        throwsA(isA<StateError>()),
      );
      expect(client.callCount, 1);
    });

    test('does not retry 501 Not Implemented', () async {
      final client = _FakeClient([_status(501)]);
      final resp = await sendWithRetry(client, _buildReq);
      expect(resp.statusCode, 501);
      expect(client.callCount, 1);
    });

    test('does not retry 505 HTTP Version Not Supported', () async {
      final client = _FakeClient([_status(505)]);
      final resp = await sendWithRetry(client, _buildReq);
      expect(resp.statusCode, 505);
      expect(client.callCount, 1);
    });

    test('still retries other 5xx (500/502/503)', () async {
      final client = _FakeClient([
        _status(502),
        _status(503),
        _ok('hello'),
      ]);
      final resp = await sendWithRetry(client, _buildReq);
      expect(resp.statusCode, 200);
      expect(client.callCount, 3);
    });
  });

  group('sendOnce', () {
    test('names --request-timeout on header timeout', () async {
      final client = _FakeClient([
        // First attempt hangs forever → timeout after 100ms.
        _hang(),
      ]);
      await expectLater(
        () => sendOnce(
          client,
          _buildReq,
          requestTimeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<TimeoutException>()
            .having(
              (e) => e.message,
              'message',
              contains('--request-timeout'),
            )),
      );
      expect(client.callCount, 1);
    });
  });

  group('applyBackoffJitter', () {
    test('stays within [base/2, base]', () {
      const base = Duration(milliseconds: 250);
      for (var i = 0; i < 200; i++) {
        final d = applyBackoffJitter(base);
        expect(d.inMilliseconds, greaterThanOrEqualTo(125));
        expect(d.inMilliseconds, lessThanOrEqualTo(250));
      }
    });

    test('produces variation with a real RNG', () {
      const base = Duration(milliseconds: 2250);
      final seen = <int>{};
      for (var i = 0; i < 50; i++) {
        seen.add(applyBackoffJitter(base).inMilliseconds);
      }
      expect(seen.length, greaterThan(1));
    });

    test('is deterministic with a seeded RNG', () {
      const base = Duration(milliseconds: 250);
      final a = applyBackoffJitter(base, Random(42));
      final b = applyBackoffJitter(base, Random(42));
      expect(a, b);
      expect(a.inMilliseconds, greaterThanOrEqualTo(125));
      expect(a.inMilliseconds, lessThanOrEqualTo(250));
    });
  });
}

// --- helpers --------------------------------------------------------------

http.Request _buildReq() =>
    http.Request('POST', Uri.parse('http://example.invalid/v1/x'))
      ..body = '{}';

/// One scripted response per call. Each entry produces *one* outcome.
class _FakeClient extends http.BaseClient {
  final List<_Outcome> _script;
  int callCount = 0;
  _FakeClient(this._script);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (callCount >= _script.length) {
      throw StateError(
          '_FakeClient ran out of scripted responses at call ${callCount + 1}');
    }
    final outcome = _script[callCount++];
    return outcome.produce();
  }
}

sealed class _Outcome {
  Future<http.StreamedResponse> produce();
}

class _StatusOutcome implements _Outcome {
  final int code;
  final String body;
  final Map<String, String> headers;
  _StatusOutcome(this.code, this.body, this.headers);

  @override
  Future<http.StreamedResponse> produce() async {
    final bytes = utf8.encode(body);
    return http.StreamedResponse(
      Stream.value(bytes),
      code,
      headers: headers,
      contentLength: bytes.length,
    );
  }
}

class _ThrowOutcome implements _Outcome {
  final Object error;
  _ThrowOutcome(this.error);

  @override
  Future<http.StreamedResponse> produce() => Future.error(error);
}

class _HangOutcome implements _Outcome {
  @override
  Future<http.StreamedResponse> produce() => Completer<http.StreamedResponse>().future;
}

_Outcome _ok(String body) =>
    _StatusOutcome(200, body, const {'content-type': 'text/plain'});
_Outcome _status(int code, {Map<String, String> headers = const {}}) =>
    _StatusOutcome(code, '', headers);
_Outcome _throw(Object e) => _ThrowOutcome(e);
_Outcome _hang() => _HangOutcome();
