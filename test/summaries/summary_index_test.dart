// Tests for [SummaryIndex] — the in-app façade over the summary sidecar.
// These focus on [SummaryIndex.status], the pure-git staleness probe (no LLM,
// no [Config]/[ProviderRegistry] needed), against a real temp git repo. The
// fleet-driving [refresh] path is covered end-to-end by `summary_runner_test`.

import 'dart:io';

import 'package:tina/summaries/allocations_store.dart';
import 'package:tina/summaries/summary_index.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempRoot;
  late Directory project;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('tina-summary-index-');
    project = Directory('${tempRoot.path}/project')..createSync();
    // A committed project with two top-level dirs + a package lib.
    Directory('${project.path}/lib')..createSync();
    File('${project.path}/lib/a.dart').writeAsStringSync('int x = 1;\n');
    Directory('${project.path}/test')..createSync();
    File('${project.path}/test/t.dart').writeAsStringSync('// t\n');
    Directory('${project.path}/packages/tina_index/lib')
        .createSync(recursive: true);
    File('${project.path}/packages/tina_index/lib/i.dart')
        .writeAsStringSync('// i\n');
    _git(project, ['init']);
    _git(project, ['add', '-A']);
    _git(project, ['commit', '-m', 'init']);
  });

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  // No config/registry — status() is the pure-git probe.
  SummaryIndex _index() => SummaryIndex(projectRoot: project.path);

  test('status on a first run: every dir stale, firstRun true, headSha set',
      () async {
    final s = await _index().status();
    expect(s.firstRun, isTrue);
    // lib, test, packages (top-level), packages/tina_index/lib.
    expect(s.totalDirs, 4);
    expect(s.staleCount, s.totalDirs); // nothing indexed yet → all stale
    expect(s.allStale, isTrue);
    expect(s.headSha, isNotNull);
    expect(s.deletedDirs, isEmpty);
  });

  test('status reflects a recorded manifest as up-to-date', () async {
    // Seed the sidecar with a manifest recording the current tree hashes, as
    // SummaryRunner.record would after a run.
    final idx = _index();
    final repo = idx.repoForTest();
    repo.init();
    final partition = repo.defaultPartition();
    final manifest = repo.record(
      manifest: repo.loadManifest(),
      regenerated: partition,
      deleted: const [],
    );
    repo.saveManifest(manifest);

    final s = await idx.status();
    expect(s.firstRun, isFalse);
    expect(s.staleCount, 0);
    expect(s.allStale, isFalse);
    expect(s.deletedDirs, isEmpty);
  });

  test('status includes allocated regions in the partition', () async {
    Directory('${project.path}/lib/src').createSync();
    File('${project.path}/lib/src/s.dart').writeAsStringSync('// s\n');
    _git(project, ['add', '-A']);
    _git(project, ['commit', '-m', 'add lib/src']);

    final idx = SummaryIndex(
      projectRoot: project.path,
      allocations: AllocationsStore.forProject(project.path),
    );
    idx.allocations!.set(dir: 'lib/src', model: 'fast/fast-model');

    final s = await idx.status();
    // lib, test, packages, packages/tina_index/lib + the allocated lib/src.
    expect(s.totalDirs, 5);
    expect(s.staleDirs, contains('lib/src'));
    expect(s.staleCount, s.totalDirs); // first run: all stale
  });

  test('status detects a partially-stale repo (only one changed dir)', () async {
    // Index everything first.
    final idx = _index();
    final repo = idx.repoForTest();
    repo.init();
    final partition = repo.defaultPartition();
    repo.saveManifest(repo.record(
      manifest: repo.loadManifest(),
      regenerated: partition,
      deleted: const [],
    ));

    // Modify only `lib`, commit. `test` + the package lib stay unchanged.
    File('${project.path}/lib/a.dart').writeAsStringSync('int x = 2;\n');
    _git(project, ['add', '-A']);
    _git(project, ['commit', '-m', 'bump lib']);

    final s = await idx.status();
    expect(s.firstRun, isFalse);
    expect(s.staleCount, 1);
    expect(s.staleDirs, contains('lib'));
    expect(s.allStale, isFalse);
  });

  test('status detects a deleted dir as stale+deleted after a removal commit',
      () async {
    final idx = _index();
    final repo = idx.repoForTest();
    repo.init();
    final partition = repo.defaultPartition();
    repo.saveManifest(repo.record(
      manifest: repo.loadManifest(),
      regenerated: partition,
      deleted: const [],
    ));

    // Remove the `test` dir from the main repo and commit.
    Directory('${project.path}/test').deleteSync(recursive: true);
    _git(project, ['add', '-A']);
    _git(project, ['commit', '-m', 'drop test']);

    final s = await idx.status();
    expect(s.deletedDirs, contains('test'));
    // A deleted dir is reported in `deleted`, not `staleDirs` (no tree to
    // regenerate against).
    expect(s.staleDirs, isNot(contains('test')));
  });
}

void _git(Directory dir, List<String> args) {
  final result = Process.runSync(
    'git',
    ['-C', dir.path, ...args],
    runInShell: false,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      'git',
      args,
      (result.stderr as String).trim(),
    );
  }
}
