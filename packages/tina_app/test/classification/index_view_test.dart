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
  late SqliteClassificationStore store;
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

  Future<IndexView> view() => readIndex(store: store);
  IndexState state(IndexView view, String path, [String kind = 'language']) =>
      view.directories[path]!.results[kind]!.state;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('index-view-');
    await Process.run('git', ['init', '-q', root.path]);
    store = await SqliteClassificationStore.open(root.path, create: true);
    executor = UnknownExecutor();
    reader = RepositoryEvidenceReader(
      root: root.path,
      sandbox: SandboxedFileSystem(
        const IoFileSystem(),
        workspaceRoot: root.path,
        tinaDir: Directory('${root.path}/.tina'),
      ),
    );
    await write('docs/readme.md', 'hello');
    await write('src/main.py', 'print(1)');
    await write('src/Dockerfile', 'FROM python');
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test(
    'opening queries saved summaries without scanning the repository or loading details',
    () async {
      await build();
      final calls = executor.calls;
      await Directory('${root.path}/.git').delete(recursive: true);
      final before = await store.readManifest();
      final result = await view();
      expect(result.warning, isNull);
      expect(result.directories.keys, unorderedEquals(['.', 'docs', 'src']));
      expect(state(result, '.'), IndexState.saved);
      expect(
        result.directories['docs']!.results['language']!.labels,
        'markdown',
      );
      expect(result.directories['src']!.results['language']!.record, isNull);
      final details = await result.loadDetails('src');
      expect(details.details, contains('path:src/main.py'));
      expect(details.details, contains('Local classifier and source'));
      expect(executor.calls, calls);
      expect(await store.readManifest(), before);
    },
  );

  test(
    'view shows saved results after edits; explicit status checks freshness',
    () async {
      await build();
      await write('src/extra.dart', 'void main() {}');
      final result = await view();
      expect(state(result, 'src'), IndexState.saved);
      expect(
        result.directories['src']!.results['language']!.labels,
        isNot(contains('dart')),
      );
      final report =
          await ClassificationOrchestrator(
            store: store,
            executor: LocalExecutor(fallback: executor),
          ).run(
            (session) => classifyProject(
              session,
              source(),
              local: SingleRequestPlan(extensionClassifier()),
            ),
            restoreOnly: true,
          );
      expect(report.failures.keys, contains('src::language'));
    },
  );

  test('partial checkpoints remain visible without a merged result', () async {
    await build();
    await store.withWriter(() async {
      final manifest = (await store.readManifest())!;
      (manifest['records'] as Map).remove('task:src::language');
      await store.writeManifest(manifest);
    });
    final result = await view();
    expect(state(result, 'src'), IndexState.incomplete);
    expect(
      result.directories['src']!.results['language']!.labels,
      contains('python'),
    );
    expect(state(result, 'docs'), IndexState.saved);
  });

  test(
    'large trees page by direct children and load grandchildren only on expansion',
    () async {
      await build();
      await store.withWriter(() async {
        final manifest = (await store.readManifest())!;
        final refs = manifest['records'] as Map;
        final id = refs['task:src::language'];
        for (var i = 0; i < 10000; i++) {
          refs['task:wide/dir${i.toString().padLeft(5, '0')}/leaf::language'] =
              id;
        }
        await store.writeManifest(manifest);
      });
      final clock = Stopwatch()..start();
      final fresh = await SqliteClassificationStore.open(root.path);
      addTearDown(fresh.close);
      final result = await readIndex(store: fresh);
      clock.stop();
      print(
        'SQLite fresh connection + index open, 20,004 nodes: ${clock.elapsedMilliseconds} ms',
      );
      expect(
        result.directories.keys,
        unorderedEquals(['.', 'docs', 'src', 'wide']),
      );
      await result.loadChildren('wide');
      expect(result.directories['wide']!.children, hasLength(100));
      expect(result.directories['wide']!.hasMore, isTrue);
      expect(result.directories, hasLength(104));
      final first = result.directories['wide']!.children.first;
      await result.loadChildren(first);
      expect(result.directories[first]!.children, ['$first/leaf']);
      await result.loadChildren('wide');
      expect(result.directories['wide']!.children, hasLength(200));
    },
  );
}
