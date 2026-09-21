import 'dart:async';

import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';
import 'package:test/test.dart';

import 'helpers.dart';

class Service implements JudgmentService {
  final requests = <JudgmentRequest>[];
  bool fail = false;
  int active = 0;
  int peak = 0;
  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest request, {
    JudgmentCancellation? cancellation,
  }) async {
    requests.add(request);
    active++;
    if (active > peak) peak = active;
    try {
      await Future<void>.delayed(Duration.zero);
      if (fail &&
          (request.state.value as List).any((v) => '$v'.endsWith('3'))) {
        throw StateError('service failed');
      }
      return JudgmentResult.fromJson({
        'model': 'test',
        'usage': {},
        'answers': {
          'relevant': {'type': 'noul', 'noul': 0.99},
        },
      }, request: request);
    } finally {
      active--;
    }
  }
}

JudgmentClassifier<String, int> definition({
  double threshold = 0.9,
}) => JudgmentClassifier(
  id: 'relevance',
  agentType: 'relevance',
  instructions: 'Judge relevance.',
  input: stringContract,
  output: numberContract,
  spec: {'threshold': threshold},
  prepare: (input) => JudgmentRequest(
    state: input.units.map((u) => u.value).toList(),
    questions: [NoulQuestion('relevant', instructions: 'Are these relevant?')],
  ),
  decode: (request, result, input) => ClassificationResult(
    outcome: ClassificationOutcome.classified,
    value:
        result.answer(request.questions['relevant']! as NoulQuestion).noul >=
            threshold
        ? input.units.length
        : 0,
    evidence: input.units.map((u) => u.id),
    explanation: 'Relevant observations',
  ),
);

void main() {
  final values = [for (var i = 0; i < 8; i++) '${'x' * 100}$i'];
  ClassificationInput<String> input(int length) => ClassificationInput([
    for (var i = 0; i < length; i++) SourceUnit('entry:$i', values[i]),
  ], InputCoverage());
  final limit = JudgmentRequestBudget().estimate(
    definition().prepare(input(2)),
  );
  late Service service;
  late MemoryStore store;
  late MemorySource<String> source;
  late JudgmentRequestBudget budget;
  late JudgmentExecutor executor;
  setUp(() {
    service = Service();
    store = MemoryStore();
    source = MemorySource(stringContract, {'items': values});
    budget = JudgmentRequestBudget(maxInputTokens: limit);
    executor = JudgmentExecutor(
      service: service,
      budget: budget,
      identity: 'test',
    );
  });
  ClassificationTask<String, int> task({double threshold = 0.9}) =>
      ClassificationTask(
        key: 'items',
        request: SourceRequest('items'),
        source: source,
        plan: ReducedClassificationPlan(
          classifier: definition(threshold: threshold),
          reduction: 'sum-v1',
          reduce: (results, coverage) => ClassificationResult(
            outcome: ClassificationOutcome.classified,
            value: results.fold<int>(0, (total, r) => total + r.value!),
            evidence: results.expand((r) => r.evidence),
            explanation: 'Sum',
          ),
        ),
      );
  ClassificationOrchestrator runner() => ClassificationOrchestrator(
    store: store,
    executor: executor,
    budget: smallBudget(limit),
    concurrency: 2,
  );

  test(
    'complete judgment requests are bounded and reduced without model merges',
    () async {
      final first = await runner().run((s) => s.classify(task()));
      expect(first.result.value, 8);
      expect(first.result.evidence.toSet(), input(8).evidenceIds);
      expect(service.requests, hasLength(4));
      expect(service.peak, 2);
      for (final request in service.requests) {
        expect(budget.estimate(request), lessThanOrEqualTo(limit));
        expect(request.state.value, hasLength(2));
      }
      await runner().run((s) async {
        expect((await s.classify(task())).id, first.id);
        expect(s.restored, 1);
      });
      expect(service.requests, hasLength(4));
      await runner().run((s) => s.classify(task(threshold: 0.95)));
      expect(service.requests, hasLength(8));
    },
  );

  test(
    'successful chunks survive a failed chunk and are reused on retry',
    () async {
      service.fail = true;
      await expectLater(
        runner().run((s) => s.classify(task())),
        throwsStateError,
      );
      expect(service.requests, hasLength(4));
      service.fail = false;
      await runner().run((s) async {
        expect((await s.classify(task())).result.value, 8);
        expect(s.reusedRequests, 3);
        expect(s.executed, 1);
      });
      expect(service.requests, hasLength(5));
    },
  );

  test(
    'oversized and cancelled requests fail before calling the service',
    () async {
      final request = ClassificationRequest(definition(), input(3));
      await expectLater(
        executor.execute(
          request,
          JudgmentCancellation(),
          maxInputTokens: limit,
          maxOutputTokens: 20,
        ),
        throwsA(
          isA<JudgmentException>().having(
            (e) => e.failure,
            'failure',
            JudgmentFailure.requestTooLarge,
          ),
        ),
      );
      final stop = JudgmentCancellation()..cancel();
      await expectLater(
        executor.execute(
          ClassificationRequest(definition(), input(1)),
          stop,
          maxInputTokens: limit,
          maxOutputTokens: 20,
        ),
        throwsA(
          isA<JudgmentException>().having(
            (e) => e.failure,
            'failure',
            JudgmentFailure.cancelled,
          ),
        ),
      );
      expect(service.requests, isEmpty);
    },
  );
}
