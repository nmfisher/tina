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
    Map<String, double> values, {
    ClassificationInput<TextEvidence>? evidence,
  }) async {
    final executor = JudgmentExecutor(
      service: Service(values),
      budget: JudgmentRequestBudget(),
      identity: 'test',
    );
    return executor.execute(
      ClassificationRequest(languageClassifier, evidence ?? input),
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
        (await evaluate({'no_language': 0.99})).outcome,
        ClassificationOutcome.notApplicable,
      );
      expect(
        (await evaluate({
          'dart': 0.71,
          'no_language': 0.99,
        })).value!.labels.single.value,
        'dart',
      );
      expect(
        (await evaluate({'other': 0.99})).value!.labels.single.value,
        'other',
      );
    },
  );
  test(
    'README and six Python filenames retain both Markdown and Python',
    () async {
      const names = [
        'README.md',
        'render.py',
        'render_cage_manifest.py',
        'render_cage_perspective.py',
        'render_ict_pairs.py',
        'render_multifamily_pairs.py',
        'render_seams.py',
      ];
      final evidence = ClassificationInput([
        for (final name in names)
          SourceUnit(
            'path:$name',
            TextEvidence(
              'repository-relative filename',
              'prediction_model/python/dataset/blender/$name',
            ),
          ),
      ], InputCoverage());
      // Python=0.71 is the live JEV result that the old 0.9 cutoff discarded.
      // Markdown is a separate positive, even though only one input uses it.
      final result = await evaluate({
        'python': 0.71,
        'markdown': 0.8,
      }, evidence: evidence);
      expect(result.value!.labels.map((label) => label.value), [
        'markdown',
        'python',
      ]);
      expect(result.evidence.toSet(), evidence.evidenceIds);
      final request = languageClassifier.prepare(evidence);
      expect(request.questions.keys, containsAll(['markdown', 'python']));
      expect(
        (request.state.value as Map)['inputs']['repository-relative filename'],
        names
            .map((name) => 'prediction_model/python/dataset/blender/$name')
            .toList(),
      );
    },
  );

  test(
    'a tie remains unknown and incomplete input cannot establish absence',
    () async {
      expect(
        (await evaluate({'python': 0.5})).outcome,
        ClassificationOutcome.unknown,
      );
      final incomplete = ClassificationInput(
        input.units,
        InputCoverage(complete: false, gaps: ['Some names were not collected']),
      );
      expect(
        (await evaluate({'no_language': 0.99}, evidence: incomplete)).outcome,
        ClassificationOutcome.unknown,
      );
    },
  );
  test('unknown chunks cannot turn a negative chunk into complete absence', () {
    final merged = mergeLabels([
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
