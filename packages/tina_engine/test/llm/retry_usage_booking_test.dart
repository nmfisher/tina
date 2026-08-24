// #46 regression tests: failed transport attempts become budget-visible.
// Covers the booking invariant (measured error usage beats the body-size
// estimate, never both), per-attempt booking through the retry ladder
// including a turn that dies mid-ladder with no MessageComplete, pooled
// member attribution, and the metering funnel routing estimates into their
// own ledger counter.
import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

const _noTools = <ToolSchema>[];

/// A scriptable provider whose first N sends fail with a given [StreamError]
/// before any content; subsequent sends complete normally.
class _FailFirstProvider extends LlmProvider {
  final int failTimes;
  final StreamError Function() errorFactory;
  final TokenUsage? successUsage;
  int _sends = 0;
  final List<({String system, List<Message> messages})> calls = [];

  _FailFirstProvider(
    this.failTimes, {
    required this.errorFactory,
    this.successUsage,
  }) : super('fail-first');

  @override
  String get model => 'fail-first';
  @override
  set model(String v) {}

  @override
  void close() {}

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    calls.add((system: system, messages: messages));
    if (_sends++ < failTimes) {
      yield errorFactory();
      return;
    }
    yield const TextDelta('ok');
    yield MessageComplete(
      content: const [TextBlock('ok')],
      stopReason: 'end_turn',
      usage: successUsage,
    );
  }
}

Future<({List<StreamEvent> events, Object? error})> _drain(
    Stream<StreamEvent> stream) async {
  final events = <StreamEvent>[];
  Object? error;
  final done = Completer<void>();
  final sub = stream.listen(
    (event) {
      if (event is StreamError) {
        error ??= event.error;
      } else {
        events.add(event);
      }
    },
    onError: (Object e) {
      error = e;
      if (!done.isCompleted) done.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );
  await done.future;
  await sub.cancel();
  return (events: events, error: error);
}

Message _msg(String text) => Message(
      role: Role.user,
      content: [TextBlock(text)],
    );

void main() {
  group('#46 failed-attempt spend', () {
    test(
        'measured error usage is booked once, never also as an estimate '
        '(measured beats estimated)', () async {
      final ledger = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      final inner = _FailFirstProvider(
        1,
        // 429 carrying a provider-reported usage block — really-billed tokens.
        errorFactory: () => const StreamError(
          'rate limited',
          statusCode: 429,
          transient: true,
          usage: TokenUsage(inputTokens: 500, outputTokens: 20),
        ),
        successUsage: const TokenUsage(inputTokens: 100, outputTokens: 10),
      );
      final metered = MeteringProvider(inner, ledger);
      // Meters install themselves on the static Wire slot; close them on
      // teardown so they don't leak into later tests' funnel assertions.
      addTearDown(metered.close);
      final provider = RetryingProvider(metered, maxRetries: 3);

      final result = await _drain(provider.send(
        system: 'sys',
        messages: [_msg('hello')],
        tools: _noTools,
      ));

      expect(result.error, isNull);
      // The measured 520 from the error body + the successful attempt's 110.
      expect(ledger.totalTokens, 630);
      // Measured beats estimated: NO estimate may be booked for that attempt.
      expect(ledger.totalEstimatedTokens, 0);
    });

    test(
        'an estimate is booked per failed attempt when the error carries no '
        'usage, and counts toward caps (turn dies mid-ladder)', () async {
      final ledger = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      final inner = _FailFirstProvider(
        99, // never succeeds: every send fails before content
        errorFactory: () =>
            const StreamError('connection reset', statusCode: 502),
      );
      final metered = MeteringProvider(inner, ledger);
      addTearDown(metered.close);
      final provider = RetryingProvider(metered, maxRetries: 2);

      final result = await _drain(provider.send(
        system: 'sys',
        messages: [_msg('hello')],
        tools: _noTools,
      ));

      // The ladder died mid-flight: no MessageComplete anywhere.
      expect(result.error, isNotNull);

      // Three attempts went out (1 initial + 2 retries); each swallowed
      // failure booked its body-size estimate into the estimated counter.
      expect(ledger.totalEstimatedTokens, greaterThan(0));
      expect(inner.calls, hasLength(3));
      // Nothing masquerades as measured.
      expect(ledger.totalTokens, 0);
    });

    test('pooled member rotation books each swallowed attempt', () async {
      final ledger = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      final failing = _FailFirstProvider(
        1,
        errorFactory: () => const StreamError('boom', statusCode: 503),
      );
      final healthy = _FailFirstProvider(
        0,
        errorFactory: () => const StreamError('never'),
        successUsage: const TokenUsage(inputTokens: 40, outputTokens: 5),
      );
      final pool = PooledProvider([failing, healthy]);
      final metered = MeteringProvider(pool, ledger);
      addTearDown(metered.close);

      final result = await _drain(metered.send(
        system: 'sys',
        messages: [_msg('hello')],
        tools: _noTools,
      ));

      expect(result.error, isNull);
      // The healthy member's completion was metered normally.
      expect(ledger.totalTokens, 45);
      // The failed member's attempt was booked as an estimate of its re-sent
      // body (its error carried no usage).
      expect(ledger.totalEstimatedTokens, greaterThan(0));
    });

    test(
        'the funnel survives an ephemeral metering close() '
        '(LRU live-tracking keeps the hook alive for remaining meters)',
        () async {
      final ledger = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      // Two meters over one shared session ledger — the ephemeral-runner
      // shape. The FIRST one closing must not kill the funnel.
      final ephemeral = MeteringProvider(
          _FailFirstProvider(0,
              errorFactory: () => StreamError('never'),
              successUsage:
                  const TokenUsage(inputTokens: 1, outputTokens: 1)),
          ledger);
      final session = MeteringProvider(
          _FailFirstProvider(0,
              errorFactory: () => StreamError('never'),
              successUsage:
                  const TokenUsage(inputTokens: 7, outputTokens: 3)),
          ledger);

      ephemeral.close();

      final result = await _drain(session.send(
        system: 's',
        messages: const [],
        tools: _noTools,
      ));
      expect(result.error, isNull);
      expect(ledger.totalTokens, 10,
          reason: 'session meter must still book after the ephemeral close');

      session.close();
      // The session was the last live meter; now the hook clears.
      expect(Wire.onAttemptUsage, isNull,
          reason: 'last meter out nulls the hook');
    });
  });

  group('#46 (c) retried-spend notice', () {
    test('fires once per 10% band and escalates, not per attempt', () {
      final ledger = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      final notices = <String>[];
      ledger.onRetriedSpendNotice = notices.add;

      // A measured success baseline: 10,000 tokens of real spend.
      ledger.record(const TokenUsage(inputTokens: 9000, outputTokens: 1000));

      // Below the absolute floor (1,000 retried tokens): silent, even though
      // the ratio would already be ~5%.
      ledger.recordRetried(
          const TokenUsage(inputTokens: 500, outputTokens: 0), estimated: true);
      expect(notices, isEmpty);

      // Crosses the floor but still under 10%: silent.
      ledger.recordRetried(
          const TokenUsage(inputTokens: 600, outputTokens: 0), estimated: true);
      expect(notices, isEmpty);

      // ~11.5% of the grand total: fires ONCE.
      ledger.recordRetried(
          const TokenUsage(inputTokens: 200, outputTokens: 0), estimated: true);
      expect(notices, hasLength(1));
      expect(notices.single, contains('[retries]'));
      expect(notices.single, contains('1300 tokens'));
      expect(notices.single, contains('1300 estimated'));

      // More retried spend inside the same band, and plain success spend
      // diluting the ratio: still silent (once per band, not per attempt).
      ledger.recordRetried(
          const TokenUsage(inputTokens: 50, outputTokens: 0), estimated: true);
      ledger.record(const TokenUsage(inputTokens: 1000, outputTokens: 0));
      expect(notices, hasLength(1));

      // Crossing the NEXT band (~23%): fires again.
      ledger.recordRetried(
          const TokenUsage(inputTokens: 2000, outputTokens: 0), estimated: true);
      expect(notices, hasLength(2));
      expect(notices.last, contains('3350 tokens'));
    });

    test('no sink installed: bookkeeping still works, nothing throws', () {
      final ledger = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      ledger.recordRetried(
          const TokenUsage(inputTokens: 5000, outputTokens: 0),
          estimated: true);
      expect(ledger.retriedTokens, 5000);
      expect(ledger.totalEstimatedTokens, 5000);
    });

    test('retried tallies accumulate through the metering funnel '
        '(measured and estimated)', () async {
      final ledger = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      // One attempt fails with a 429 carrying usage; the retry succeeds.
      final inner = _FailFirstProvider(
        1,
        errorFactory: () => const StreamError(
          'rate limited',
          statusCode: 429,
          transient: true,
          usage: TokenUsage(inputTokens: 500, outputTokens: 20),
        ),
        successUsage: const TokenUsage(inputTokens: 100, outputTokens: 10),
      );
      final metered = MeteringProvider(inner, ledger);
      addTearDown(metered.close);
      final provider = RetryingProvider(metered, maxRetries: 3);

      final result = await _drain(provider.send(
        system: 'sys',
        messages: [_msg('hello')],
        tools: _noTools,
      ));
      expect(result.error, isNull);

      // The failed attempt's MEASURED usage is retried spend; the success is
      // not. 520 retried + 110 plain.
      expect(ledger.retriedTokens, 520);
      expect(ledger.retriedMeasured, 520);
      expect(ledger.retriedEstimated, 0);
      expect(ledger.totalTokens, 630);
    });
  });
}
