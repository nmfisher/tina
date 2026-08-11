// End-to-end test for [SummaryIndex.refresh] — the façade's fleet-driving path
// that [index_command_test] stubs out. Runs the real fleet (orchestrator →
// delegate → summarizer → write_summary) via the shared [fleet_test_harness]
// against a temp git repo, and asserts the sidecar is populated + committed,
// the registry decorator is restored (so an in-process /index doesn't leak),
// and `repartition` forces a re-run even when the index is up to date.

import 'dart:io';

import 'package:tina/platform/environment.dart';
import 'package:tina/summaries/sidecar_repo.dart';
import 'package:tina/summaries/summary_index.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import 'fleet_test_harness.dart';

void main() {
  late Directory tempRoot;
  late Directory project;
  late Directory sidecarRoot;
  late ScriptedFleetProvider provider;

  setUp(() {
    final t = buildTempProject();
    tempRoot = t.tempRoot;
    project = t.project;
    sidecarRoot = t.sidecarRoot;
    provider = ScriptedFleetProvider();
  });

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  SummaryIndex _index(ProviderRegistry registry) => SummaryIndex(
        config: testFleetConfig(registry),
        registry: registry,
        environment: const PlatformEnvironment(),
        projectRoot: project.path,
      );

  SidecarSummaryRepo _repo() =>
      SidecarSummaryRepo(root: sidecarRoot, projectRoot: project);

  test('refresh runs the fleet, writes the sidecar, restores the decorator',
      () async {
    final registry = anthropicRegistry(provider);
    // Sentinel the live session would have set at startup; refresh must leave
    // it intact despite SummaryRunner's buildAppComposition re-setting it.
    final sentinel = (LlmProvider p) => p;
    registry.decorator = sentinel;
    final idx = _index(registry);

    final before = await idx.status();
    expect(before.firstRun, isTrue);
    expect(before.allStale, isTrue);

    final r = await idx.refresh().timeout(const Duration(seconds: 30));
    expect(r.regenerated, greaterThan(0));
    expect(r.regeneratedDirs, contains('lib'));

    // Sidecar file with the summarizer's content + a stamped header.
    final file = File('${sidecarRoot.path}/summaries/lib.md');
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), contains('lib does X'));
    // Manifest tracks lib.
    expect(_repo().loadManifest().dirs['lib'], isNotNull);
    // A sidecar commit was recorded.
    expect(
        git(Directory('${sidecarRoot.path}/summaries'), ['log', '--oneline']),
        contains('summaries @'));

    // The caller's decorator survived the in-process fleet run.
    expect(registry.decorator, same(sentinel));

    // Post-run status is up to date.
    final after = await idx.status();
    expect(after.firstRun, isFalse);
    expect(after.staleCount, 0);
  });

  test('refresh(repartition: true) regenerates even when up to date', () async {
    final registry = anthropicRegistry(provider);
    final idx = _index(registry);

    // Seed an up-to-date manifest so a non-repartition refresh would no-op.
    final seed = _repo();
    seed.init();
    final partition = seed.defaultPartition();
    seed.saveManifest(seed.record(
      manifest: seed.loadManifest(),
      regenerated: partition,
      deleted: const [],
    ));
    expect((await idx.status()).staleCount, 0);

    // repartition clears the manifest → all stale → the fleet runs anyway.
    final r =
        await idx.refresh(repartition: true).timeout(const Duration(seconds: 30));
    expect(r.regenerated, partition.length);
    expect(r.regeneratedDirs, contains('lib'));
    // The file was (re)written.
    expect(File('${sidecarRoot.path}/summaries/lib.md').existsSync(), isTrue);
    expect(
        git(Directory('${sidecarRoot.path}/summaries'), ['log', '--oneline']),
        contains('summaries @'));
  });

  test('refresh(dirs:) regenerates only the requested dirs', () async {
    // A second stale dir so the filter is observable.
    Directory('${project.path}/packages/foo/lib').createSync(recursive: true);
    File('${project.path}/packages/foo/lib/f.dart').writeAsStringSync('// f\n');
    git(project, ['add', '-A']);
    git(project, ['commit', '-m', 'add package']);
    // And make lib stale too.
    File('${project.path}/lib/a.dart').writeAsStringSync('int x = 2;\n');
    git(project, ['add', '-A']);
    git(project, ['commit', '-m', 'bump lib']);

    final registry = anthropicRegistry(provider);
    final idx = _index(registry);
    final before = await idx.status();
    expect(before.staleDirs, containsAll(['lib', 'packages/foo/lib']));

    final r =
        await idx.refresh(dirs: ['lib']).timeout(const Duration(seconds: 30));
    expect(r.regenerated, 1);
    expect(r.regeneratedDirs, ['lib']);

    // Only lib was regenerated; the other stale dirs (packages — whose tree
    // changed when the package was added — and the package lib) stay stale.
    final after = await idx.status();
    expect(after.staleDirs, isNot(contains('lib')));
    expect(after.staleDirs, contains('packages/foo/lib'));
    expect(File('${sidecarRoot.path}/summaries/lib.md').existsSync(), isTrue);
    expect(
        File('${sidecarRoot.path}/summaries/packages__foo__lib.md').existsSync(),
        isFalse);
  });
}
