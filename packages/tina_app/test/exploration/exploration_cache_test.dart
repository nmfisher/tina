import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'helpers.dart';

ExplorationWorkflow cached(
  Source source,
  Judge judge,
  ExplorationCache cache,
) => ExplorationWorkflow(
  source: source,
  runner: workflow(source, judge).runner,
  cache: cache,
  cacheEndpoint: 'endpoint',
);

void main() {
  test(
    'disk records survive recreation; concurrent writes are atomic; corruption misses',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'tina-exploration-cache-',
      );
      addTearDown(() => dir.delete(recursive: true));
      expect((await Process.run('git', ['init', '-q', dir.path])).exitCode, 0);
      final cache = FileExplorationCache(dir.path);
      final source = Source([const ProjectEvidence('a.dart', 'code')]);
      await cached(
        source,
        Judge(),
        cache,
      ).run('cancel?', mode: ExplorationMode.verify);
      final judge = Judge();
      final result = await cached(
        source,
        judge,
        FileExplorationCache(dir.path),
      ).run('cancel?', mode: ExplorationMode.verify);
      expect(result.answerCacheHit, isTrue);
      final status = await Process.run('git', [
        'status',
        '--porcelain',
      ], workingDirectory: dir.path);
      expect(status.exitCode, 0);
      expect(status.stdout, isEmpty); // Cache supplies its own ignore rule.

      expect(judge.requests, isEmpty);
      final key = evidenceHash('concurrent');
      await Future.wait(
        List.generate(
          8,
          (i) => cache.write(key, {'value': i, 'padding': 'x' * 1000}),
        ),
      );
      final read = await cache.read(key);
      expect(read!['value'], inInclusiveRange(0, 7));
      await File(
        p.join(dir.path, '.tina', 'exploration', '$key.json'),
      ).writeAsString('{');
      expect(await cache.read(key), isNull);
      expect(
        await FileExplorationCache(dir.path, maxRecordBytes: 1).read(key),
        isNull,
      );
    },
  );

  test('disk cache does not follow a symlinked storage directory', () async {
    if (Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('tina-cache-link-');
    addTearDown(() => dir.delete(recursive: true));
    final root = Directory(p.join(dir.path, 'repo'))..createSync();
    final outside = Directory(p.join(dir.path, 'outside'))..createSync();
    await Link(p.join(root.path, '.tina')).create(outside.path);
    final cache = FileExplorationCache(root.path);
    final key = evidenceHash('key');
    await cache.write(key, {'value': 1});
    expect(await cache.read(key), isNull);
    expect(outside.listSync(), isEmpty);
  });
}
