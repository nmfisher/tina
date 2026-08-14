// Tests for [SummaryIndex] — the in-app façade over the summary sidecar.
// These focus on [SummaryIndex.status], the pure-git staleness probe (no LLM,
// no [Config]/[ProviderRegistry] needed), against a real temp git repo. The
// fleet-driving [refresh] path is covered end-to-end by `summary_runner_test`.

import 'dart:io';

import 'package:tina/summaries/allocations_store.dart';
import 'package:tina/summaries/sidecar_repo.dart';
import 'package:tina/summaries/summary_index.dart';
import 'package:tina_engine/tina_engine.dart' show summarySlug;
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

  // Seed the sidecar the way a fleet run would: write each dir's summary file
  // (so record()'s honesty guard records it), then record + save the manifest.
  void seedIndex(SidecarSummaryRepo repo, List<String> partition) {
    repo.init();
    for (final dir in partition) {
      File('${project.path}/.tina/summaries/${summarySlug(dir)}.md')
          .writeAsStringSync('# $dir\n');
    }
    repo.saveManifest(repo.record(
      manifest: repo.loadManifest(),
      regenerated: partition,
      deleted: const [],
    ));
  }

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
    seedIndex(idx.repoForTest(), idx.repoForTest().defaultPartition());

    final s = await idx.status();
    expect(s.firstRun, isFalse);
    expect(s.staleCount, 0);
    expect(s.allStale, isFalse);
    expect(s.deletedDirs, isEmpty);
  });

  test('status: the allocated layout IS the partition once any exists',
      () async {
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
    // The default top-level dirs are NOT in the partition once the main
    // agent's layout exists.
    expect(s.totalDirs, 1);
    expect(s.staleDirs, ['lib/src']);
    expect(s.staleCount, s.totalDirs); // first run: all stale
    expect(s.hasAllocations, isTrue);
  });

  test('status: no allocations → default partition, hasAllocations false',
      () async {
    final s = await _index().status();
    expect(s.hasAllocations, isFalse);
    expect(s.totalDirs, 4); // lib, test, packages, packages/tina_index/lib.
  });

  test('status detects a partially-stale repo (only one changed dir)', () async {
    // Index everything first.
    final idx = _index();
    seedIndex(idx.repoForTest(), idx.repoForTest().defaultPartition());

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
    seedIndex(idx.repoForTest(), idx.repoForTest().defaultPartition());

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
