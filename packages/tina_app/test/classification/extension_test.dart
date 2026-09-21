import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';
import 'package:test/test.dart';
import 'package:tina_app/src/classification/extension_classifier.dart';
import 'package:tina_app/src/classification/project_classifiers.dart';

Future<ClassificationResult<ProjectLabels>> classify(List<String> names) =>
    const LocalExecutor().execute(
      ClassificationRequest(
        extensionClassifier(),
        ClassificationInput([
          for (final name in names)
            SourceUnit(
              'path:$name',
              TextEvidence('repository-relative filename', name),
            ),
        ], InputCoverage()),
      ),
      JudgmentCancellation(),
      maxInputTokens: 1,
      maxOutputTokens: 1,
    );

void main() {
  test(
    'one Markdown and six Python files produce two labels with precise evidence',
    () async {
      const python = [
        'render.py',
        'render_cage_manifest.py',
        'render_cage_perspective.py',
        'render_ict_pairs.py',
        'render_multifamily_pairs.py',
        'render_seams.py',
      ];
      final result = await classify(['README.md', ...python]);
      expect(result.value!.labels.map((l) => l.value), ['markdown', 'python']);
      expect(result.value!.labels.first.evidence, ['path:README.md']);
      expect(
        result.value!.labels.last.evidence,
        unorderedEquals(python.map((p) => 'path:$p')),
      );
    },
  );

  test(
    'uses the final extension, with exact-case overrides and lowercase fallback',
    () async {
      final result = await classify([
        'src/app.PY',
        'src/app.c',
        'src/app.C',
        'types.d.ts',
        'docs.py/image.bin',
      ]);
      expect(result.value!.labels.map((l) => l.value), [
        'c',
        'cpp',
        'python',
        'typescript',
      ]);
      expect(result.evidence, isNot(contains('path:docs.py/image.bin')));
    },
  );

  test('unmapped, ambiguous and extensionless names stay unknown', () async {
    final result = await classify([
      'Makefile',
      '.py',
      'file.',
      'module.h',
      'module.m',
      'asset.bin',
    ]);
    expect(result.outcome, ClassificationOutcome.unknown);
    expect(result.evidence, isEmpty);
  });

  test(
    'rule tables are immutable, versioned in identity and do not accept content inputs',
    () {
      final rules = {'.py': 'python'};
      final classifier = extensionClassifier(extensions: rules);
      final before = canonicalFingerprint(classifier.identity);
      rules['.py'] = 'other';
      expect(canonicalFingerprint(classifier.identity), before);
      expect(
        canonicalFingerprint(extensionClassifier(extensions: rules).identity),
        isNot(before),
      );
      expect(
        () => classifier.classify(
          ClassificationInput([
            SourceUnit('content', TextEvidence('file content', 'main.py')),
          ], InputCoverage()),
        ),
        throwsArgumentError,
      );
    },
  );
}
