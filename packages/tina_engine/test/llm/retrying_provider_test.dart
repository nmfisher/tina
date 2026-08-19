import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// A provider whose n-th [send] yields the n-th scripted attempt, then
/// completes — the shape the retry layer sees: wire failures arrive as
/// terminal [StreamError] events on otherwise-completing streams.
class _ScriptedAttemptsProvider extends LlmProvider {
  final List<List<StreamEvent>> attempts;
  final List<DateTime> starts = [];
  int calls = 0;

  _ScriptedAttemptsProvider(this.attempts) : super('scripted');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    starts.add(DateTime.now());
    final i = calls++;
    for (final e in attempts[i]) {
      yield e;
    }
  }
}

const _ok = [
  TextDelta('recovered'),
  MessageComplete(
    content: [TextBlock('recovered')],
    stopReason: 'end_turn',
    usage: TokenUsage.zero,
  ),
];

Future<List<StreamEvent>> _drain(Stream<StreamEvent> s) => s.toList();

void main() {
  group('RetryingProvider', () {
    test('retries a retryable failure that precedes any content', () async {
      final inner = _ScriptedAttemptsProvider([
        [const StreamError('NIM 429: Too Many Requests',
            statusCode: 429, retryAfter: Duration(milliseconds: 30))],
        _ok,
      ]);
      final provider = RetryingProvider(inner);
      final events = await _drain(provider.send(
          system: 's', messages: const [], tools: const []));

      expect(inner.calls, 2, reason: 'exactly one re-attempt');
      expect(events.whereType<StreamError>(), isEmpty,
          reason: 'the failed attempt is invisible — nothing duplicated');
      expect(
          events.whereType<MessageComplete>().single.content.single,
          isA<TextBlock>(),
          reason: 'the retry\'s answer is the send\'s answer');
      // Retry-After honored: the second start waits out the hint.
      final gap = inner.starts[1].difference(inner.starts[0]).inMilliseconds;
      expect(gap, greaterThanOrEqualTo(25),
          reason: 'the server hint spaces the re-attempt');
    });

    test('a transient connection failure is retried too', () async {
      final inner = _ScriptedAttemptsProvider([
        [const StreamError('Network error: connection reset', transient: true)],
        _ok,
      ]);
      final events = await _drain(RetryingProvider(inner)
          .send(system: 's', messages: const [], tools: const []));
      expect(inner.calls, 2);
      expect(events.whereType<StreamError>(), isEmpty);
    });

    test('without a hint, the local backoff schedule spaces the retry',
        () async {
      final inner = _ScriptedAttemptsProvider([
        [const StreamError('boom', statusCode: 503)],
        _ok,
      ]);
      await _drain(RetryingProvider(inner)
          .send(system: 's', messages: const [], tools: const []));
      final gap = inner.starts[1].difference(inner.starts[0]).inMilliseconds;
      // First schedule slot is 250ms with equal jitter → [125, 250].
      expect(gap, greaterThanOrEqualTo(100),
          reason: 'local backoff applies when the server sends no hint');
    });

    test('a failure after content has streamed is NOT retried', () async {
      // Once a delta reached the consumer, re-sending would duplicate it —
      // the mid-stream error surfaces instead (the transport-retry semantics
      // this layer inherited).
      final inner = _ScriptedAttemptsProvider([
        [const TextDelta('partial'), const StreamError('cut off', statusCode: 429)],
      ]);
      final events = await _drain(RetryingProvider(inner)
          .send(system: 's', messages: const [], tools: const []));
      expect(inner.calls, 1, reason: 'no re-attempt after streamed content');
      expect(events.whereType<TextDelta>(), isNotEmpty);
      expect(events.whereType<StreamError>().single.statusCode, 429);
    });

    test('non-retryable failures surface immediately', () async {
      final inner = _ScriptedAttemptsProvider([
        [const StreamError('OpenAI 400: bad request', statusCode: 400)],
      ]);
      final events = await _drain(RetryingProvider(inner)
          .send(system: 's', messages: const [], tools: const []));
      expect(inner.calls, 1);
      expect(events.whereType<StreamError>().single.statusCode, 400);
    });

    test('exhausts the retry budget, then surfaces the failure', () async {
      final inner = _ScriptedAttemptsProvider([
        for (var i = 0; i < 5; i++)
          [const StreamError('down', statusCode: 503,
              retryAfter: Duration(milliseconds: 10))],
      ]);
      final events = await _drain(RetryingProvider(inner, maxRetries: 2)
          .send(system: 's', messages: const [], tools: const []));
      expect(inner.calls, 3, reason: 'initial attempt + 2 retries');
      expect(events.whereType<StreamError>(), isNotEmpty);
    });

    test('cancelling during the backoff never launches the next attempt',
        () async {
      final inner = _ScriptedAttemptsProvider([
        [const StreamError('429', statusCode: 429,
            retryAfter: Duration(seconds: 5))],
        _ok,
      ]);
      final provider = RetryingProvider(inner);
      final sub = provider
          .send(system: 's', messages: const [], tools: const [])
          .listen(null);
      await sub.cancel();
      // Give the parked retry a scheduling beat: it must never fire.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(inner.calls, 1,
          reason: 'the cancelled send forfeited its retry');
    });
  });
}
