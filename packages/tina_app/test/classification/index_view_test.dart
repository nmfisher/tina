import 'dart:io';

import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';
import 'package:test/test.dart';
import 'package:tina_app/classification.dart';
import 'package:tina_engine/tina_engine.dart';

class UnknownExecutor implements ClassificationExecutor {
  int calls = 0;
  @override
  Object get configuration => 'test';
  @override
  int estimate<I, O>(ClassificationRequest<I, O> request) => 1;
  @override
  Future<ClassificationResult<O>> execute<I, O>(
    ClassificationRequest<I, O> request,
    JudgmentCancellation cancellation, {
    required int maxInputTokens,
    required int maxOutputTokens,
  }) async {
    calls++;
    return ClassificationResult(
      outcome: ClassificationOutcome.unknown,
      explanation: 'Test evidence is inconclusive.',
    );
  }
}

void main() {
  late Directory root;
  late FileClassificationStore store;
  late RepositoryEvidenceReader reader;
  late UnknownExecutor executor;
  Future<void> write(String path, String contents) async {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  RepositoryTextSource source() => RepositoryTextSource(
    reader: reader,
    projection: RepositoryProjection.filenames,
  );
  Future<void> build() async {
    final report =
        await ClassificationOrchestrator(
          store: store,
          executor: LocalExecutor(fallback: executor),
        ).run(
          (session) => classifyProject(
            session,
            source(),
            local: SingleRequestPlan(extensionClassifier()),
            detailsSource: RepositoryTextSource(
              reader: reader,
              selectedOnly: true,
              contentNames: const ['Dockerfile'],
            ),
          ),
        );
    expect(report.failures, isEmpty);
  }

  Future<IndexView> view([JudgmentCancellation? cancellation]) => readIndex(
    store: store,
    source: source(),
    cancellation: cancellation ?? JudgmentCancellation(),
  );
  IndexState state(IndexView view, String path, [String kind = 'language']) =>
      view.directories[path]!.results[kind]!.state;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('index-view-');
    await Process.run('git', ['init', '-q', root.path]);
    store = FileClassificationStore(root.path);
    executor = UnknownExecutor();
    reader = RepositoryEvidenceReader(
      root: root.path,
      sandbox: SandboxedFileSystem(
        const IoFileSystem(),
        projectRoot: root.path,
        tinaDir: Directory('${root.path}/.tina'),
      ),
    );
    await write('docs/readme.md', 'hello');
    await write('src/main.py', 'print(1)');
    await write('src/Dockerfile', 'FROM python');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'browsing saved labels and evidence is read-only and makes no classifier calls',
    () async {
      await build();
      final before = await store.readManifest();
      final calls = executor.calls;
      final result = await view();
      expect(result.warning, isNull);
      expect(result.directories['.']!.children, ['docs', 'src']);
      for (final kind in indexKinds) {
        expect(state(result, '.', kind), IndexState.current);
      }
      expect(
        result.directories['docs']!.results['language']!.labels,
        'markdown',
      );
      expect(result.directories['src']!.details, contains('path:src/main.py'));
      expect(
        result.directories['src']!.details,
        contains('Local classifier and source'),
      );
      expect(executor.calls, calls);
      expect(await store.readManifest(), before);
    },
  );

  test(
    'filename and content changes invalidate only affected branches and ancestors',
    () async {
      await build();
      await write('src/Dockerfile', 'FROM alpine');
      var result = await view();
      expect(state(result, 'src'), IndexState.current);
      expect(state(result, 'src', 'tooling'), IndexState.stale);
      expect(state(result, '.', 'tooling'), IndexState.stale);
      expect(state(result, 'docs', 'tooling'), IndexState.current);
      await write('src/extra.dart', 'void main() {}');
      result = await view();
      expect(state(result, 'src'), IndexState.stale);
      expect(state(result, '.'), IndexState.stale);
      expect(state(result, 'docs'), IndexState.current);
    },
  );

  test(
    'new and deleted directories remain distinguishable from saved results',
    () async {
      await build();
      await Directory('${root.path}/docs').delete(recursive: true);
      await write('test/new.py', '');
      final result = await view();
      expect(result.directories['docs']!.removed, isTrue);
      expect(state(result, 'docs'), IndexState.stale);
      expect(state(result, 'test'), IndexState.missing);
      expect(state(result, '.'), isNot(IndexState.current));
    },
  );

  test(
    'partial and corrupt checkpoints do not hide healthy siblings',
    () async {
      await build();
      final manifest = (await store.readManifest())!;
      final ids = manifest['records'] as Map;
      ids.remove('task:src::language');
      final corrupt = ids['task:docs::tooling'];
      await File('${store.root}/records/$corrupt.json').writeAsString('{}');
      await store.writeManifest(manifest);
      final result = await view();
      expect(state(result, 'src'), IndexState.incomplete);
      expect(
        result.directories['src']!.results['language']!.labels,
        contains('python'),
      );
      expect(state(result, 'docs'), IndexState.current);
      expect(state(result, 'docs', 'tooling'), IndexState.incomplete);
      expect(state(result, '.'), IndexState.incomplete);
    },
  );

  test(
    'empty index creates no storage, and cancellation stops the reader',
    () async {
      final result = await view();
      expect(result.warning, contains('No saved index'));
      expect(state(result, 'src'), IndexState.missing);
      expect(await Directory(store.root).exists(), isFalse);
      await expectLater(
        view(JudgmentCancellation()..cancel()),
        throwsStateError,
      );
    },
  );
}
