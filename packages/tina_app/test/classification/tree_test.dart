import 'dart:io';

import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';
import 'package:test/test.dart';
import 'package:tina_app/src/classification/file_classification_store.dart';
import 'package:tina_app/src/classification/project_classification_workflow.dart';
import 'package:tina_app/src/classification/repository_classification_source.dart';
import 'package:tina_app/src/classification/repository_text_source.dart';
import 'package:tina_engine/tina_engine.dart';

/// Deliberately reads explicit test markers, not filename extensions. Only the
/// executor supplies language decisions; discovery and reduction cannot guess.
class LanguageExecutor implements ClassificationExecutor {
  final calls = <List<String>>[];
  @override
  Object get configuration => 'test-language-agent';
  @override
  int estimate<I, O>(ClassificationRequest<I, O> request) =>
      conservativeTokenEstimate(request.toJson());
  @override
  Future<ClassificationResult<O>> execute<I, O>(
    ClassificationRequest<I, O> request,
    JudgmentCancellation cancellation, {
    required int maxInputTokens,
    required int maxOutputTokens,
  }) async {
    expect(request.definition.agentType, 'language_classifier');
    final units = request.input.units;
    calls.add(units.map((u) => u.id).toList());
    final files = units.where((u) => u.id.startsWith('file:')).toList();
    return ClassificationResult.fromJson({
      'outcome': files.isEmpty ? 'unknown' : 'classified',
      'value': files.isEmpty
          ? null
          : {
              'labels': [
                for (final unit in files)
                  {
                    'value': (unit.value as TextEvidence).text.trim(),
                    'evidence': [unit.id],
                  },
              ],
            },
      'evidence': files.map((u) => u.id).toList(),
      'explanation': 'Language supplied by the test classifier.',
    }, request.definition.output);
  }
}

void main() {
  late Directory root;
  late LanguageExecutor executor;
  Future<void> write(String path, String content) async {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  RepositoryTextSource source() => RepositoryTextSource(
    reader: RepositoryEvidenceReader(
      root: root.path,
      sandbox: SandboxedFileSystem(
        const IoFileSystem(),
        projectRoot: root.path,
        tinaDir: Directory('${root.path}/.tina'),
      ),
    ),
    contentNames: const [],
    contentSuffixes: const ['.txt'],
  );
  Future<ProjectClassificationReport> run({bool restore = false}) =>
      ClassificationOrchestrator(
        store: FileClassificationStore(root.path),
        executor: executor,
      ).run(
        (session) => classifyProject(session, source()),
        restoreOnly: restore,
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('language-tree-');
    await Process.run('git', ['init', '-q', root.path]);
    executor = LanguageExecutor();
    await write('docs/user/code.txt', 'dart');
    await write('docs/dev/code.txt', 'python');
    await write('src/code.txt', 'dart');
    await write('test/code.txt', 'python');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'index classifies only languages, merges upward, and restores from disk',
    () async {
      final first = await run();
      expect(first.failures, isEmpty);
      expect(
        first.records.keys,
        unorderedEquals([
          '.::language',
          'docs::language',
          'docs/user::language',
          'docs/dev::language',
          'src::language',
          'test::language',
        ]),
      );
      expect(
        first.records['docs::language']!.result.value!.labels.map(
          (l) => l.value,
        ),
        ['dart', 'python'],
      );
      expect(first.executed, 4);
      executor.calls.clear();
      final restored = await run(restore: true);
      expect(restored.failures, isEmpty);
      expect(restored.executed, 0);
      expect(executor.calls, isEmpty);
      expect(
        restored.records['.::language']!.id,
        first.records['.::language']!.id,
      );

      await write('docs/user/code.txt', 'rust');
      final next = await run();
      expect(next.failures, isEmpty);
      expect(executor.calls, [
        ['path:docs/user/code.txt', 'file:docs/user/code.txt'],
      ]);
      expect(
        next.records['docs/dev::language']!.id,
        first.records['docs/dev::language']!.id,
      );
      expect(
        next.records['docs::language']!.result.value!.labels.map(
          (l) => l.value,
        ),
        ['python', 'rust'],
      );
      expect(
        next.records['.::language']!.result.value!.labels.map((l) => l.value),
        ['dart', 'python', 'rust'],
      );
    },
  );

  test(
    'same language output preserves ancestors; parent files and deleted nodes are handled',
    () async {
      final before = await run();
      executor.calls.clear();
      await write('docs/user/code.txt', 'dart\n');
      final same = await run();
      expect(same.failures, isEmpty);
      expect(executor.calls, hasLength(1));
      expect(
        same.records['.::language']!.id,
        before.records['.::language']!.id,
      );
      await write('docs/code.txt', 'ruby');
      await File('${root.path}/docs/dev/code.txt').delete();
      final next = await run();
      expect(next.failures, isEmpty);
      expect(
        next.records['docs::language']!.result.value!.labels.map(
          (l) => l.value,
        ),
        ['dart', 'ruby'],
      );
      final manifest =
          (await FileClassificationStore(root.path).readManifest())!['records']
              as Map;
      expect(manifest.keys, isNot(contains('task:docs/dev::language')));
      expect(manifest.keys, contains('task:docs::language::local'));
    },
  );

  test(
    'incomplete input stays visible in parent coverage and old non-language tasks are retired',
    () async {
      await run();
      final store = FileClassificationStore(root.path);
      await store.withWriter(() async {
        final manifest = (await store.readManifest())!;
        final pointers = manifest['records'] as Map;
        pointers['task:.::framework'] = pointers['task:.::language'];
        await store.writeManifest(manifest);
      });
      await write('docs/user/code.txt', 'x' * (128 * 1024 + 1));
      final report = await run();
      expect(report.records['.::language']!.coverage.complete, isFalse);
      expect(
        report.failures.keys,
        containsAll(['docs/user::language', 'docs::language', '.::language']),
      );
      final manifest = (await store.readManifest())!['records'] as Map;
      expect(manifest.keys, isNot(contains('task:.::framework')));
    },
  );
}
