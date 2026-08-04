// Tests for [WriteSummaryTool]: the sidecar summary capture seam.
//
// These exercise real `git` (rev-parse HEAD / HEAD:<dir>), so they build a
// real temp repo, commit a directory into it, and point the tool at a temp
// sidecar root. The header must carry the real commit + tree hash, the slug
// must flatten nested dirs, and a crafted dir must not escape the sidecar.

import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempRoot;
  late Directory project;
  late Directory sidecar;
  late WriteSummaryTool tool;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('tina-writesummary-');
    project = Directory('${tempRoot.path}/project')..createSync();
    sidecar = Directory('${tempRoot.path}/sidecar/summaries')
      ..createSync(recursive: true);
    // A committed directory so rev-parse HEAD:<dir> resolves.
    Directory('${project.path}/lib')..createSync();
    File('${project.path}/lib/a.dart').writeAsStringSync('int x = 1;\n');
    _git(project, ['init']);
    _git(project, ['add', '-A']);
    _git(project, ['commit', '-m', 'init']);
    // The tool runs git with -C <projectRoot>, so no cwd mutation is needed —
    // the test is isolated from the process's working directory.
    tool = WriteSummaryTool(sidecarRoot: sidecar, projectRoot: project.path);
  });

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('writes a summary file with a stamped commit + tree header', () async {
    final res = await tool.execute({
      'dir': 'lib',
      'content': '# lib\n\nThis is the lib directory.',
    });
    expect(res.isError, isFalse, reason: res.content);

    final file = File('${sidecar.path}/lib.md');
    expect(file.existsSync(), isTrue);
    final text = file.readAsStringSync();
    final head = _git(project, ['rev-parse', 'HEAD']);
    final tree = _git(project, ['rev-parse', 'HEAD:lib']);
    expect(text, startsWith('<!-- tina-summary dir="lib" commit="$head" '
        'tree="$tree" generated="'));
    expect(text, contains('# lib\n\nThis is the lib directory.'));
  });

  test('slugs nested dirs to a flat filename with __ separators', () async {
    Directory('${project.path}/packages/tina_index/lib')
        .createSync(recursive: true);
    File('${project.path}/packages/tina_index/lib/x.dart')
        .writeAsStringSync('// x\n');
    _git(project, ['add', '-A']);
    _git(project, ['commit', '-m', 'add package']);

    final res = await tool.execute({
      'dir': 'packages/tina_index/lib',
      'content': 'package summary',
    });
    expect(res.isError, isFalse, reason: res.content);

    expect(File('${sidecar.path}/packages__tina_index__lib.md')
        .existsSync(), isTrue);
  });

  test('refuses a dir that escapes the sidecar via ..', () async {
    final res = await tool.execute({
      'dir': '../../etc',
      'content': 'escape attempt',
    });
    // The slug flattens every '/' to '__' so the filename can't traverse, and
    // git itself rejects HEAD:<dir> for a path outside the repo. Either guard
    // refusing is correct — the guarantee is: it errors and writes nothing.
    expect(res.isError, isTrue);
    expect(sidecar.listSync(), isEmpty);
  });

  test('errors when dir is missing or content absent', () async {
    expect((await tool.execute({'content': 'x'})).isError, isTrue);
    expect((await tool.execute({'dir': ''})).isError, isTrue);
    expect((await tool.execute({'dir': 'lib'})).isError, isTrue);
  });

  test('errors when no sidecar root is configured', () async {
    final unconfigured = WriteSummaryTool();
    final res = await unconfigured
        .execute({'dir': 'lib', 'content': 'x'});
    expect(res.isError, isTrue);
    expect(res.content, contains('not configured'));
  });

  test('reports an error when git rev-parse fails for an unknown dir',
      () async {
    final res = await tool.execute({
      'dir': 'does/not/exist',
      'content': 'x',
    });
    expect(res.isError, isTrue);
  });
}

String _git(Directory dir, List<String> args) {
  // Author the commits so git doesn't refuse on a test machine with no
  // user.name / user.email configured.
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
