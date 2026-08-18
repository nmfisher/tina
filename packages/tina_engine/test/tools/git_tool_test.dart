import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/memory_process_runner.dart';

void main() {
  group('GitTool read-only guard (scripted runner)', () {
    // A fresh runner per call site below — every test in this group asserts
    // the tool REFUSES to invoke it for disallowed forms, so each test needs
    // its own invocation log.
    (GitTool, MemoryProcessRunner) makeTool() {
      // Factory form (not .always): a fresh process per invocation, so a
      // multi-call test doesn't hit "Stream has already been listened to".
      final runner = MemoryProcessRunner(
        (executable, arguments) =>
            MemoryRunningProcess(stdoutChunks: ['should not run']),
      );
      return (GitTool(processRunner: runner), runner);
    }

    Future<ToolResult> run(String args) async {
      final (tool, _) = makeTool();
      return tool.execute({'args': args});
    }

    test('read-only subcommands pass through to git', () async {
      final (tool, runner) = makeTool();
      for (final args in [
        'status',
        'log --oneline -5',
        'diff HEAD~1',
        'show HEAD:pubspec.yaml',
        'rev-parse HEAD',
        'blame lib/a.dart',
        'ls-files',
        'reflog',
        'describe',
        'shortlog -s',
      ]) {
        final res = await tool.execute({'args': args});
        expect(res.isError, isFalse, reason: args);
      }
      expect(runner.runs.length, 10);
    });

    test('listing forms of branch/tag/remote are allowed', () async {
      for (final args in [
        'branch',
        'branch -a',
        'branch -vv',
        'branch --list feat*',
        'tag',
        'tag -l',
        'tag --list v*',
        'remote',
        'remote -v',
        'remote get-url origin',
      ]) {
        final res = await run(args);
        expect(res.isError, isFalse, reason: args);
      }
    });

    test('mutating git operations are rejected before any process runs',
        () async {
      final (tool, runner) = makeTool();
      for (final args in [
        'commit -m x',
        'add .',
        'push',
        'pull',
        'checkout -b new-branch',
        'reset --hard',
        'config user.name Bob',
        'init',
        'clean -fd',
        'stash',
        'clone https://example.com/repo',
      ]) {
        final res = await tool.execute({'args': args});
        expect(res.isError, isTrue, reason: args);
        expect(res.content, contains('not allowed'), reason: args);
      }
      expect(runner.runs, isEmpty);
    });

    test('mutating forms of branch/tag/remote are rejected', () async {
      final (tool, runner) = makeTool();
      for (final args in [
        'branch -D feature',
        'branch -d feature',
        'branch -m renamed',
        'branch new-branch',
        'tag -d v1.0',
        'tag v2.0',
        'tag -a v2.0',
        'remote add origin https://example.com',
        'remote remove origin',
        'remote set-url origin https://example.com',
        'remote rename origin upstream',
      ]) {
        final res = await tool.execute({'args': args});
        expect(res.isError, isTrue, reason: args);
      }
      expect(runner.runs, isEmpty);
    });

    test('--output is rejected even on read-only subcommands', () async {
      final (tool, runner) = makeTool();
      for (final args in [
        'log --output /tmp/evil.txt',
        'log --output=/tmp/evil.txt',
        'diff --output /tmp/evil.txt',
      ]) {
        final res = await tool.execute({'args': args});
        expect(res.isError, isTrue, reason: args);
        expect(res.content, contains('--output'), reason: args);
      }
      expect(runner.runs, isEmpty);
    });

    test('rejects empty args', () async {
      final res = await run('  ');
      expect(res.isError, isTrue);
      expect(res.content, contains('args is required'));
    });

    test('non-zero exit surfaces stderr', () async {
      final failing = MemoryProcessRunner.always(MemoryRunningProcess(
        stderrChunks: ['fatal: not a git repository'],
        exitCodeValue: 128,
      ));
      final res =
          await GitTool(processRunner: failing).execute({'args': 'status'});
      expect(res.isError, isTrue);
      expect(res.content, contains('not a git repository'));
    });
  });

  group('GitTool against a real repo', () {
    late Directory repo;

    setUp(() {
      repo = Directory.systemTemp.createTempSync('tina_git_');
      // Minimal real repo with one commit on a known branch.
      Process.runSync('git', ['-C', repo.path, 'init', '-b', 'main']);
      Process.runSync(
          'git', ['-C', repo.path, 'config', 'user.email', 't@t.dev']);
      Process.runSync('git', ['-C', repo.path, 'config', 'user.name', 'T']);
      File('${repo.path}/a.txt').writeAsStringSync('hello');
      Process.runSync('git', ['-C', repo.path, 'add', '.']);
      Process.runSync(
          'git', ['-C', repo.path, 'commit', '-m', 'first commit']);
    });

    tearDown(() {
      repo.deleteSync(recursive: true);
    });

    GitTool buildTool() => GitTool(
        processRunner: const IoProcessRunner(), workingDirectory: repo.path);

    test('log and status return real output', () async {
      final tool = buildTool();
      final log = await tool.execute({'args': 'log --oneline'});
      expect(log.isError, isFalse);
      expect(log.content, contains('first commit'));
      final status = await tool.execute({'args': 'status --porcelain'});
      expect(status.isError, isFalse);
      expect(status.content, contains('(no output)'));
    });

    test('a mutation attempt leaves the repo untouched', () async {
      final tool = buildTool();
      final res = await tool.execute({'args': 'branch -D main'});
      expect(res.isError, isTrue);
      final branches = await tool.execute({'args': 'branch'});
      expect(branches.content, contains('* main'));
    });
  });
}
