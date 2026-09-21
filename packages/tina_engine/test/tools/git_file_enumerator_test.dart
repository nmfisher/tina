import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/memory_process_runner.dart';

class ByteProcess implements RunningProcess {
  final List<List<int>> chunks;
  bool killed = false;
  ByteProcess(this.chunks);
  @override
  Stream<List<int>> get stdout => Stream.fromIterable(chunks);
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<int> get exitCode async => 0;
  @override
  int get pid => 0;
  @override
  bool kill({bool force = false}) => killed = true;
}

class DelayedRunner extends MemoryProcessRunner {
  final started = Completer<void>();
  final pending = Completer<RunningProcess>();
  DelayedRunner() : super((_, __) => throw StateError('unexpected run'));
  @override
  Future<RunningProcess> start(String executable, List<String> arguments,
      {String? workingDirectory, Map<String, String>? environment}) {
    started.complete();
    return pending.future;
  }
}

void main() {
  test('NUL paths survive byte boundaries, Unicode, newlines and duplicates',
      () async {
    final paths = ['naïve.dart', 'line\nbreak.dart', 'space name.dart'];
    final bytes = utf8.encode([...paths, paths.first, ''].join('\x00'));
    final process = ByteProcess([
      for (final b in bytes) [b]
    ]);
    final runner = DelayedRunner()..pending.complete(process);
    final result =
        await GitFileEnumerator(processes: runner).enumerate('/repo');
    expect(result.status, GitListingStatus.completed);
    expect(result.paths, paths);
    expect(process.killed, isTrue);
  });

  test('malformed UTF-8 filenames are skipped with a bounded diagnostic',
      () async {
    final process = ByteProcess([
      [255, 0, 255, 0],
      utf8.encode('a.dart\x00')
    ]);
    final runner = DelayedRunner()..pending.complete(process);
    final result =
        await GitFileEnumerator(processes: runner).enumerate('/repo');
    expect(result.paths, ['a.dart']);
    expect(result.gaps, ['Non-UTF8 filename skipped.']);
  });

  test(
      'path and output limits retain partial results and terminate the process',
      () async {
    for (final limits in [(1, 100, 100), (10, 8, 100), (10, 100, 2)]) {
      final process =
          MemoryRunningProcess(stdoutChunks: ['a.dart\x00b.dart\x00']);
      final result = await GitFileEnumerator(
        processes: MemoryProcessRunner.always(process),
        maxFiles: limits.$1,
        maxOutputBytes: limits.$2,
        maxPathBytes: limits.$3,
      ).enumerate('/repo');
      expect(result.status, GitListingStatus.truncated);
      expect(result.paths.length, lessThanOrEqualTo(1));
      expect(result.gaps.single, contains('capped'));
      expect(process.killed, isTrue);
    }
  });

  test('exactly maxFiles is complete and an unterminated path is a failure',
      () async {
    for (final entry in [
      ('a.dart\x00', GitListingStatus.completed),
      ('a.dart', GitListingStatus.failed)
    ]) {
      final result = await GitFileEnumerator(
        processes: MemoryProcessRunner.always(
            MemoryRunningProcess(stdoutChunks: [entry.$1])),
        maxFiles: 1,
      ).enumerate('/repo');
      expect(result.status, entry.$2);
    }
  });

  test('pre-cancelled enumeration starts no process', () async {
    final runner =
        MemoryProcessRunner((_, __) => throw StateError('must not start'));
    final result = await GitFileEnumerator(processes: runner)
        .enumerate('/repo', cancelSignal: Future.value());
    expect(result.status, GitListingStatus.cancelled);
    expect(runner.starts, isEmpty);
  });

  test('cancellation returns during startup and kills a late process',
      () async {
    final runner = DelayedRunner();
    final cancel = Completer<void>();
    final pending = GitFileEnumerator(processes: runner)
        .enumerate('/repo', cancelSignal: cancel.future);
    await runner.started.future;
    cancel.complete();
    expect((await pending).status, GitListingStatus.cancelled);
    final process = MemoryRunningProcess(hangUntilKilled: true);
    runner.pending.complete(process);
    await Future<void>.delayed(Duration.zero);
    expect(process.killed, isTrue);
  });

  test('deadline bounds a stalled stream even if kill does not settle exit',
      () async {
    final process =
        MemoryRunningProcess(hangUntilKilled: true, killCompletesExit: false);
    final result = await GitFileEnumerator(
      processes: MemoryProcessRunner.always(process),
      timeout: const Duration(milliseconds: 10),
    ).enumerate('/repo');
    expect(result.status, GitListingStatus.timedOut);
    expect(process.killed, isTrue);
  });

  test('real Git paths are relative to the requested subtree and honor ignores',
      () async {
    final dir = await Directory.systemTemp.createTemp('git-enumerate-');
    addTearDown(() => dir.delete(recursive: true));
    expect((await Process.run('git', ['init', '-q', dir.path])).exitCode, 0);
    final sub = await Directory('${dir.path}/sub').create();
    await File('${dir.path}/outer.dart').writeAsString('');
    await File('${dir.path}/.gitignore').writeAsString('ignored.dart\n');
    for (final name in ['naïve.dart', 'line\nbreak.dart', 'ignored.dart']) {
      await File('${sub.path}/$name').writeAsString('');
    }
    final result = await GitFileEnumerator(processes: const IoProcessRunner())
        .enumerate(sub.path);
    expect(result.status, GitListingStatus.completed);
    expect(result.paths.toSet(), {'naïve.dart', 'line\nbreak.dart'});
  });
}
