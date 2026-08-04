import 'dart:convert';

import 'package:test/test.dart';

import '../helpers/memory_process_runner.dart';

void main() {
  group('MemoryProcessRunner', () {
    test('run() joins stdout/stderr and returns the exit code', () async {
      final runner = MemoryProcessRunner.always(MemoryRunningProcess(
        stdoutChunks: ['hello\n'],
        stderrChunks: ['oops\n'],
        exitCodeValue: 3,
      ));
      final r = await runner.run('rg', ['--version']);
      expect(r.exitCode, 3);
      expect(r.stdout, 'hello\n');
      expect(r.stderr, 'oops\n');
      expect(runner.runs.single.executable, 'rg');
      expect(runner.runs.single.arguments, ['--version']);
      expect(runner.starts, isEmpty);
    });

    test('start() streams chunks in order then completes exitCode', () async {
      final runner = MemoryProcessRunner.always(MemoryRunningProcess(
        stdoutChunks: ['one\n', 'two\n'],
        exitCodeValue: 0,
      ));
      final p = await runner.start('/bin/sh', ['-c', 'x']);
      final out = await p.stdout.transform(utf8.decoder).join();
      expect(out, 'one\ntwo\n');
      expect(await p.exitCode, 0);
      expect(runner.starts.single.arguments, ['-c', 'x']);
    });

    test('the factory sees executable + argv, letting run/start differ', () async {
      MemoryRunningProcess factory(String exe, List<String> a) {
        if (a.contains('--version')) {
          return MemoryRunningProcess(
              stdoutChunks: ['ripgrep 13.0\n'], exitCodeValue: 0);
        }
        return MemoryRunningProcess(stdoutChunks: ['a.dart:1:hit\n']);
      }
      final runner = MemoryProcessRunner(factory);
      final ver = await runner.run('rg', ['--version']);
      expect(ver.stdout, contains('ripgrep'));
      final p = await runner.start('rg', ['pattern', '.']);
      final out = await p.stdout.transform(utf8.decoder).join();
      expect(out, 'a.dart:1:hit\n');
    });
  });

  group('MemoryRunningProcess cancellation', () {
    test('a hanging process does not complete until kill()', () async {
      final proc = MemoryRunningProcess(
          hangUntilKilled: true, exitCodeValue: 143);
      final runner = MemoryProcessRunner.always(proc);
      final p = await runner.start('sleep', ['30']);

      // Subscribe before kill so the close is observable.
      final drainFuture = p.stdout.drain<void>();
      var completed = false;
      p.exitCode.then((_) => completed = true);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(completed, isFalse);

      expect(p.kill(), isTrue);
      expect(proc.killed, isTrue);
      expect(await p.exitCode, 143);
      await drainFuture; // streams closed by kill
    });

    test('kill() before natural completion short-circuits remaining output',
        () async {
      final proc = MemoryRunningProcess(
        stdoutChunks: ['first\n', 'second\n', 'third\n'],
        exitCodeValue: 0,
      );
      // Kill synchronously, before _pump's scheduled microtask runs.
      proc.kill();
      expect(proc.killed, isTrue);
      expect(await proc.exitCode, 0);
      // _pump ran but was a no-op (already closed); no chunks were emitted.
      expect(await proc.stdout.isEmpty, isTrue);
    });
  });
}
