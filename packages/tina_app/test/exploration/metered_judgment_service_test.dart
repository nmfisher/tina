import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

final request = JudgmentRequest(
  state: 'evidence',
  questions: [NoulQuestion('yes', instructions: null)],
);
JudgmentResult answer(Map<String, int> usage) => JudgmentResult.fromJson({
  'model': 'jev-latest',
  'answers': {
    'yes': {'type': 'noul', 'noul': 0.9},
  },
  'usage': usage,
}, request: request);

class Service implements JudgmentService {
  int calls = 0;
  Future<JudgmentResult> Function(JudgmentCancellation?) respond;
  Service(this.respond);
  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest request, {
    JudgmentCancellation? cancellation,
  }) {
    calls++;
    return respond(cancellation);
  }
}

void main() {
  late SpendLedger ledger;
  late JudgmentRequestBudget budget;
  late Service inner;
  MeteredJudgmentService metered({PauseGate? gate}) => MeteredJudgmentService(
    inner: inner,
    ledger: ledger,
    budget: budget,
    outputTokenAllowance: 100,
    pauseGate: gate,
  );
  setUp(() {
    ledger = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
    budget = JudgmentRequestBudget();
    inner = Service(
      (_) async => answer({'input_tokens': 20, 'output_tokens': 5}),
    );
  });

  test(
    'measured usage trips the shared ledger and blocks further dispatch',
    () async {
      ledger.updateLimits(maxGlobalTokens: 24, requestsPerMinute: 0);
      final service = metered();
      final result = await service.evaluate(request);
      expect(result.usage.inputTokens, 20);
      expect(ledger.totalTokens, 25);
      expect(ledger.totalEstimatedTokens, 0);
      expect(ledger.tripped, isTrue);
      await expectLater(
        service.evaluate(request),
        throwsA(
          isA<JudgmentException>().having(
            (e) => e.failure,
            'failure',
            JudgmentFailure.budgetExceeded,
          ),
        ),
      );
      expect(inner.calls, 1);
    },
  );

  test(
    'partial counters retain known spend and estimate only unknown counters',
    () async {
      inner.respond = (_) async => answer({'input_tokens': 20});
      final result = await metered().evaluate(request);
      expect(result.usage.outputTokens, isNull);
      expect(ledger.totalTokens, 20);
      expect(ledger.totalEstimatedTokens, 100);
      inner.respond = (_) async => answer({'output_tokens': 5});
      await metered().evaluate(request);
      expect(ledger.totalTokens, 25);
      expect(ledger.totalEstimatedTokens, 100 + budget.estimate(request));
    },
  );

  test(
    'unknown usage and failed attempts count as estimates without retries',
    () async {
      inner.respond = (_) async => answer({});
      await metered().evaluate(request);
      expect(ledger.totalTokens, 0);
      expect(ledger.totalEstimatedTokens, budget.estimate(request) + 100);
      inner.respond = (_) async =>
          throw const JudgmentException(JudgmentFailure.unavailable);
      await expectLater(
        metered().evaluate(request),
        throwsA(isA<JudgmentException>()),
      );
      expect(inner.calls, 2);
      expect(ledger.totalEstimatedTokens, 2 * (budget.estimate(request) + 100));
    },
  );

  test(
    'closure before dispatch is free; closure during an attempt is estimated',
    () async {
      inner.respond = (_) async => throw const JudgmentException(
        JudgmentFailure.closed,
        attempted: false,
      );
      await expectLater(
        metered().evaluate(request),
        throwsA(isA<JudgmentException>()),
      );
      expect(ledger.grandTotalTokens, 0);
      inner.respond = (_) async =>
          throw const JudgmentException(JudgmentFailure.closed);
      await expectLater(
        metered().evaluate(request),
        throwsA(isA<JudgmentException>()),
      );
      expect(ledger.totalTokens, 0);
      expect(ledger.totalEstimatedTokens, budget.estimate(request) + 100);
    },
  );

  test('pre-cancellation and rejected inputs spend nothing', () async {
    await expectLater(
      metered().evaluate(
        request,
        cancellation: JudgmentCancellation()..cancel(),
      ),
      throwsA(isA<JudgmentException>()),
    );
    budget = JudgmentRequestBudget(maxInputTokens: 2, overheadTokens: 0);
    await expectLater(
      metered().evaluate(request),
      throwsA(isA<JudgmentException>()),
    );
    expect(inner.calls, 0);
    expect(ledger.grandTotalTokens, 0);
  });

  test(
    'RPM waits share chat slots and cancel without dispatch or spend',
    () async {
      ledger.updateLimits(maxGlobalTokens: 0, requestsPerMinute: 1);
      await ledger.acquireRequestSlot();
      final cancellation = JudgmentCancellation();
      final result = metered().evaluate(request, cancellation: cancellation);
      final assertion = expectLater(
        result,
        throwsA(
          isA<JudgmentException>().having(
            (e) => e.failure,
            'failure',
            JudgmentFailure.cancelled,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(inner.calls, 0);
      cancellation.cancel();
      await assertion;
      expect(ledger.grandTotalTokens, 0);
    },
  );

  test('ledger is checked again after waiting for a shared RPM slot', () async {
    var now = DateTime.utc(2026);
    ledger = SpendLedger(
      maxGlobalTokens: 10,
      requestsPerMinute: 1,
      now: () => now,
    );
    await ledger.acquireRequestSlot();
    final result = metered().evaluate(request);
    final assertion = expectLater(
      result,
      throwsA(
        isA<JudgmentException>().having(
          (e) => e.failure,
          'failure',
          JudgmentFailure.budgetExceeded,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    ledger.record(const TokenUsage(inputTokens: 11, outputTokens: 0));
    now = now.add(const Duration(minutes: 1));
    await assertion;
    expect(inner.calls, 0);
  });

  test('pause gate resumes or cancels before spending', () async {
    final gate = PauseGate()..requestPause('test');
    addTearDown(gate.dispose);
    final pending = metered(gate: gate).evaluate(request);
    await Future<void>.delayed(Duration.zero);
    expect(inner.calls, 0);
    gate.resume(continueDecision: true);
    await pending;
    expect(inner.calls, 1);
    gate.requestPause('again');
    final cancellation = JudgmentCancellation();
    final cancelled = metered(
      gate: gate,
    ).evaluate(request, cancellation: cancellation);
    final assertion = expectLater(cancelled, throwsA(isA<JudgmentException>()));
    cancellation.cancel();
    await assertion;
    expect(inner.calls, 1);
  });
}
