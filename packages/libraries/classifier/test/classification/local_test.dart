import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  test(
    'local rules share persistence and invalidate when their spec changes',
    () async {
      final source = MemorySource(numberContract, {
        'items': [2, 3],
      });
      final store = MemoryStore();
      var calls = 0;
      ClassificationTask<int, int> task(int factor) => ClassificationTask(
        key: 'items',
        request: SourceRequest('items'),
        source: source,
        plan: SingleRequestPlan(
          LocalClassifier(
            id: 'sum',
            agentType: 'local_sum',
            instructions:
                'Sum the inputs and multiply by the configured factor.',
            input: numberContract,
            output: numberContract,
            spec: {'factor': factor},
            classify: (input) {
              calls++;
              return ClassificationResult(
                outcome: ClassificationOutcome.classified,
                value:
                    input.units.fold<int>(0, (sum, u) => sum + u.value) *
                    factor,
                evidence: input.units.map((u) => u.id),
                explanation: 'Sum',
              );
            },
          ),
        ),
      );
      Future<ClassificationRecord<int>> run(int factor) =>
          ClassificationOrchestrator(
            store: store,
            executor: const LocalExecutor(),
            budget: smallBudget(
              1,
            ), // Local execution consumes no model context.
          ).run((session) => session.classify(task(factor)));
      final first = await run(1);
      expect(first.result.value, 5);
      expect((await run(1)).id, first.id);
      expect(calls, 1);
      expect((await run(2)).result.value, 10);
      expect(calls, 2);
    },
  );

  test(
    'local execution rejects model definitions and honours cancellation',
    () async {
      final input = ClassificationInput([
        SourceUnit('one', 1),
      ], InputCoverage());
      const executor = LocalExecutor();
      expect(
        () =>
            executor.estimate(ClassificationRequest(numberDefinition(), input)),
        throwsArgumentError,
      );
      final stop = JudgmentCancellation()..cancel();
      await expectLater(
        executor.execute(
          ClassificationRequest(
            LocalClassifier<int, int>(
              id: 'cancelled',
              agentType: 'test',
              instructions: 'Do nothing',
              input: numberContract,
              output: numberContract,
              spec: const {},
              classify: (_) => throw StateError('must not execute'),
            ),
            input,
          ),
          stop,
          maxInputTokens: 1,
          maxOutputTokens: 1,
        ),
        throwsA(
          isA<JudgmentException>().having(
            (e) => e.failure,
            'failure',
            JudgmentFailure.cancelled,
          ),
        ),
      );
    },
  );
}
