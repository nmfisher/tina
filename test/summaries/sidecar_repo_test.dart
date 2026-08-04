// Tests for [SidecarSummaryRepo]: the git-plumbing + manifest + staleness layer
// for the per-directory summary sidecar. These build a real temp git repo (so
// rev-parse HEAD:<dir> resolves) and a temp sidecar, then assert init,
// manifest round-trip, and the three staleness cases (modified / deleted / new).

import 'dart:io';

import 'package:tina/summaries/sidecar_repo.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempRoot;
  late Directory project;
  late Directory sidecarRoot;
  late SidecarSummaryRepo repo;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('tina-sidecar-');
    project = Directory('${tempRoot.path}/project')..createSync();
    sidecarRoot = Directory('${tempRoot.path}/.tina')..createSync();
    // A committed project with two top-level dirs + a package.
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

    repo = SidecarSummaryRepo(root: sidecarRoot, projectRoot: project);
  });

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('init creates the sidecar dir and git-inits it (idempotent)', () {
    repo.init();
    expect(Directory('${sidecarRoot.path}/summaries').existsSync(), isTrue);
    expect(_isGitRepo('${sidecarRoot.path}/summaries'), isTrue);
    // Second init is a no-op.
    repo.init();
    expect(_isGitRepo('${sidecarRoot.path}/summaries'), isTrue);
  });

  test('manifest round-trips through json', () {
    final manifest = SummaryManifest(dirs: {
      'lib': DirSummary(commit: 'abc', tree: 'def', file: 'lib.md'),
    });
    repo.saveManifest(manifest);
    final loaded = repo.loadManifest();
    expect(loaded.dirs.keys, contains('lib'));
    expect(loaded.dirs['lib']!.commit, 'abc');
    expect(loaded.dirs['lib']!.tree, 'def');
    expect(loaded.dirs['lib']!.file, 'lib.md');
  });

  test('loadManifest returns empty when no manifest exists', () {
    expect(repo.loadManifest().dirs, isEmpty);
  });

  test('defaultPartition lists top-level dirs + packages/*/lib', () {
    final partition = repo.defaultPartition();
    expect(partition, containsAll(['lib', 'test', 'packages/tina_index/lib']));
    // Sorted.
    expect(partition, equals(partition..sort()));
    // Hidden dirs skipped.
    Directory('${project.path}/.hidden')..createSync();
    expect(repo.defaultPartition(), isNot(contains('.hidden')));
  });

  test('staleness: every dir is stale on the first run', () {
    repo.init();
    final stale = repo.staleDirs(repo.defaultPartition(), SummaryManifest.empty());
    expect(stale.toRegenerate, containsAll(['lib', 'test', 'packages/tina_index/lib']));
    expect(stale.deleted, isEmpty);
  });

  test('staleness: an unchanged dir is not stale after recording', () {
    repo.init();
    final partition = repo.defaultPartition();
    final stale1 = repo.staleDirs(partition, SummaryManifest.empty());
    final recorded = repo.record(
      manifest: SummaryManifest.empty(),
      regenerated: stale1.toRegenerate,
      deleted: const [],
    );
    // Now none are stale — the recorded trees match.
    final stale2 = repo.staleDirs(partition, recorded);
    expect(stale2.toRegenerate, isEmpty);
  });

  test('staleness: a modified dir becomes stale again', () {
    repo.init();
    final partition = repo.defaultPartition();
    final stale1 = repo.staleDirs(partition, SummaryManifest.empty());
    final recorded = repo.record(
      manifest: SummaryManifest.empty(),
      regenerated: stale1.toRegenerate,
      deleted: const [],
    );
    // Change lib and commit.
    File('${project.path}/lib/a.dart').writeAsStringSync('int x = 2;\n');
    _git(project, ['add', '-A']);
    _git(project, ['commit', '-m', 'change lib']);
    final stale2 = repo.staleDirs(partition, recorded);
    expect(stale2.toRegenerate, contains('lib'));
    expect(stale2.toRegenerate, isNot(contains('test')));
  });

  test('staleness: a deleted dir is reported in deleted', () {
    repo.init();
    final partition = repo.defaultPartition();
    final stale1 = repo.staleDirs(partition, SummaryManifest.empty());
    final recorded = repo.record(
      manifest: SummaryManifest.empty(),
      regenerated: stale1.toRegenerate,
      deleted: const [],
    );
    // Remove the test dir and commit.
    Directory('${project.path}/test').deleteSync(recursive: true);
    _git(project, ['add', '-A']);
    _git(project, ['commit', '-m', 'remove test']);
    final stale2 = repo.staleDirs(partition, recorded);
    expect(stale2.deleted, contains('test'));
  });

  test('staleness: a new dir not in the manifest is stale', () {
    repo.init();
    Directory('${project.path}/docs')..createSync();
    File('${project.path}/docs/README.md').writeAsStringSync('# docs\n');
    _git(project, ['add', '-A']);
    _git(project, ['commit', '-m', 'add docs']);
    final stale = repo.staleDirs(repo.defaultPartition(), SummaryManifest.empty());
    expect(stale.toRegenerate, contains('docs'));
  });

  test('commit writes a git commit to the sidecar with a descriptive message',
      () {
    repo.init();
    // Stage a summary file directly.
    File('${sidecarRoot.path}/summaries/lib.md')
        .writeAsStringSync('# lib\n');
    repo.commit(regenerated: const ['lib'], deleted: const [], commitSha: _head(project));
    final log = _git(Directory('${sidecarRoot.path}/summaries'), ['log', '--oneline']);
    expect(log, contains('summaries @'));
    expect(log, contains('1 regenerated'));
  });

  test('commit removes deleted summary files before committing', () {
    repo.init();
    File('${sidecarRoot.path}/summaries/lib.md')
        .writeAsStringSync('# lib\n');
    File('${sidecarRoot.path}/summaries/test.md')
        .writeAsStringSync('# test\n');
    _git(Directory('${sidecarRoot.path}/summaries'), ['add', '-A']);
    _git(Directory('${sidecarRoot.path}/summaries'), ['commit', '-m', 'seed']);
    repo.commit(
      regenerated: const [],
      deleted: const ['test'],
      commitSha: _head(project),
    );
    expect(File('${sidecarRoot.path}/summaries/test.md').existsSync(), isFalse);
    expect(File('${sidecarRoot.path}/summaries/lib.md').existsSync(), isTrue);
  });

  test('commit is a no-op when nothing is staged', () {
    repo.init();
    // A freshly-init'd sidecar with no staged changes: commit() must not mint
    // a commit. Assert via the ref resolution (HEAD has no commit) rather than
    // `log`, which fails on a commit-less repo.
    repo.commit(regenerated: const [], deleted: const [], commitSha: _head(project));
    final rev = Process.runSync(
      'git',
      ['-C', '${sidecarRoot.path}/summaries', 'rev-parse', 'HEAD'],
      runInShell: false,
    );
    expect(rev.exitCode, isNot(0),
        reason: 'a no-op commit must not create a commit object');
  });
}

String _head(Directory dir) => _git(dir, ['rev-parse', 'HEAD']);

String _git(Directory dir, List<String> args) {
  final env = Map<String, String>.from(Platform.environment)
    ..['GIT_AUTHOR_NAME'] = 'Test'
    ..['GIT_AUTHOR_EMAIL'] = 'test@example.com'
    ..['GIT_COMMITTER_NAME'] = 'Test'
    ..['GIT_COMMITTER_EMAIL'] = 'test@example.com';
  final result = Process.runSync(
    'git',
    ['-C', dir.path, ...args],
    environment: env,
    runInShell: false,
  );
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(" ")} failed in ${dir.path}: '
        '${result.stderr}');
  }
  return (result.stdout as String).trim();
}

bool _isGitRepo(String path) {
  final result = Process.runSync(
    'git',
    ['-C', path, 'rev-parse', '--is-inside-work-tree'],
    runInShell: false,
  );
  return result.exitCode == 0;
}
