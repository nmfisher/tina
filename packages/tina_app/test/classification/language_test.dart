import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';
import 'package:test/test.dart';
import 'package:tina_app/src/classification/project_classifiers.dart';

class Service implements JudgmentService {
  final Map<String, double> probabilities;
  final requests = <JudgmentRequest>[];
  int active = 0;
  int peak = 0;
  Service(this.probabilities);
  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest request, {
    JudgmentCancellation? cancellation,
  }) async {
    requests.add(request);
    active++;
    if (active > peak) peak = active;
    await Future<void>.delayed(Duration.zero);
    active--;
    return JudgmentResult.fromJson({
      'model': 'jev-test',
      'usage': {},
      'answers': {
        for (final key in request.questions.keys)
          key: {'type': 'noul', 'noul': probabilities[key] ?? 0.01},
      },
    }, request: request);
  }
}

void main() {
  final input = ClassificationInput([
    SourceUnit('one', TextEvidence('names', 'main.dart')),
  ], InputCoverage());
  Future<ClassificationResult<ProjectLabels>> evaluate(
    Map<String, double> values,
  ) async {
    final executor = JudgmentExecutor(
      service: Service(values),
      budget: JudgmentRequestBudget(),
      identity: 'test',
    );
    return executor.execute(
      ClassificationRequest(languageClassifier, input),
      JudgmentCancellation(),
      maxInputTokens: 24000,
      maxOutputTokens: 1024,
    );
  }

  test(
    'multiple model-supported languages survive without choosing one winner',
    () async {
      final result = await evaluate({'dart': 0.99, 'python': 0.98});
      expect(result.value!.labels.map((l) => l.value), ['dart', 'python']);
      expect(result.evidence, ['one']);
    },
  );
  test(
    'filename extensions do not assign languages when the model is uncertain',
    () async {
      expect(
        (await evaluate({'dart': 0.5})).outcome,
        ClassificationOutcome.unknown,
      );
      expect(
        (await evaluate({'non_code': 0.99})).outcome,
        ClassificationOutcome.notApplicable,
      );
      expect(
        (await evaluate({'dart': 0.99, 'non_code': 0.99})).outcome,
        ClassificationOutcome.unknown,
      );
      expect(
        (await evaluate({'other': 0.99})).value!.labels.single.value,
        'other',
      );
    },
  );
  test('unknown chunks cannot turn a negative chunk into complete absence', () {
    final merged = mergeLanguages([
      ClassificationResult(
        outcome: ClassificationOutcome.notApplicable,
        explanation: 'Data',
      ),
      ClassificationResult(
        outcome: ClassificationOutcome.unknown,
        explanation: 'Uncertain',
      ),
    ], InputCoverage());
    expect(merged.outcome, ClassificationOutcome.unknown);
  });
}
