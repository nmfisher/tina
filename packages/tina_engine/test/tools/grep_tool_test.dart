import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/memory_file_enumerator.dart';
import '../helpers/memory_file_system.dart';
import '../helpers/memory_process_runner.dart';

/// A [ProcessRunner] whose `rg --version` probe succeeds, and whose `rg` search
/// invocations return [searchResult]. Used to drive the ripgrep code path
/// without spawning anything.
MemoryProcessRunner _rgRunner({
  List<String> searchStdout = const [],
  List<String> searchStderr = const [],
  int searchExitCode = 0,
}) {
  MemoryRunningProcess factory(String exe, List<String> args) {
    if (args.contains('--version')) {
      return MemoryRunningProcess(stdoutChunks: ['ripgrep 13.0\n']);
    }
    return MemoryRunningProcess(
      stdoutChunks: searchStdout,
      stderrChunks: searchStderr,
      exitCodeValue: searchExitCode,
    );
  }
  return MemoryProcessRunner(factory);
}

/// A [ProcessRunner] whose every invocation throws — rg is not installed, so
/// GrepTool falls back to the Dart walk.
MemoryProcessRunner _noRgRunner() =>
    MemoryProcessRunner((exe, args) => throw Exception('rg not installed'));

void main() {
  group('GrepTool (ripgrep path)', () {
    test('finds matches with path:line:content', () async {
      final runner = _rgRunner(searchStdout: [
        'a.dart:1:class Foo {}\n',
        'a.dart:3:class Bar extends Foo {}\n',
        'sub/c.dart:1:class Baz {}\n',
      ]);
      final fs = MemoryFileSystem()..directories.add('/repo');
      final res = await GrepTool(
        processRunner: runner,
        fileEnumerator: MemoryFileEnumerator({}),
        fs: fs,
      ).execute({'pattern': 'class ', 'path': '/repo'});
      expect(res.isError, isFalse);
      expect(res.content, contains('a.dart:1:class Foo {}'));
      expect(res.content, contains('a.dart:3:class Bar extends Foo {}'));
      expect(res.content, contains('sub/c.dart:1:class Baz {}'));
    });

    test('truncates at maxResults with a marker (and tolerates the kill exit)',
        () async {
      // Emit 5 matches but cap at 2; grep kills rg at the cap. The fake's
      // exit code is 0, but `truncated` is set in the stdout listener so the
      // exit>1 error branch is skipped regardless.
      final lines = [for (var i = 0; i < 5; i++) 'f.dart:${i + 1}:hit\n'];
      final runner = _rgRunner(searchStdout: lines, searchExitCode: 0);
      final fs = MemoryFileSystem()..directories.add('/repo');
      final res = await GrepTool(
        processRunner: runner,
        fileEnumerator: MemoryFileEnumerator({}),
        fs: fs,
      ).execute({'pattern': 'hit', 'path': '/repo', 'maxResults': 2});
      expect(res.isError, isFalse);
      expect(res.content, contains('f.dart:1:hit'));
      expect(res.content, contains('f.dart:2:hit'));
      expect(res.content, contains('cap of 2 reached'));
    });

    test('truncates an over-long match line', () async {
      // One match whose content alone is 5000 chars; the emitted line must be
      // capped at _maxMatchLineChars with the truncation marker, keeping the
      // `path:line:` prefix.
      final huge = 'x.dart:1:${'a' * 5000}\n';
      final runner = _rgRunner(searchStdout: [huge]);
      final fs = MemoryFileSystem()..directories.add('/repo');
      final res = await GrepTool(
        processRunner: runner,
        fileEnumerator: MemoryFileEnumerator({}),
        fs: fs,
      ).execute({'pattern': 'a', 'path': '/repo'});
      expect(res.isError, isFalse);
      expect(res.content, contains('[line truncated]'));
      // The full emitted match line (sans trailing newline) fits the cap + suffix.
      final matchLine =
          res.content.split('\n').firstWhere((l) => l.startsWith('x.dart:'));
      expect(matchLine.length, lessThanOrEqualTo(1000 + '… [line truncated]'.length));
      expect(matchLine.startsWith('x.dart:1:'), isTrue); // prefix intact
    });

    test('surfaces a non-zero rg error (exit > 1) with stderr', () async {
      final runner = _rgRunner(
        searchStderr: ['regex parse error\n'],
        searchExitCode: 2,
      );
      final fs = MemoryFileSystem()..directories.add('/repo');
      final res = await GrepTool(
        processRunner: runner,
        fileEnumerator: MemoryFileEnumerator({}),
        fs: fs,
      ).execute({'pattern': '(', 'path': '/repo'});
      expect(res.isError, isTrue);
      expect(res.content, contains('ripgrep failed (exit 2)'));
      expect(res.content, contains('regex parse error'));
    });

    test('rg exit 1 (no matches) reports (no matches)', () async {
      final runner = _rgRunner(searchExitCode: 1);
      final fs = MemoryFileSystem()..directories.add('/repo');
      final res = await GrepTool(
        processRunner: runner,
        fileEnumerator: MemoryFileEnumerator({}),
        fs: fs,
      ).execute({'pattern': 'nothing', 'path': '/repo'});
      expect(res.content, equals('(no matches)'));
    });
  });

  group('GrepTool (Dart fallback)', () {
    GrepTool fallbackTool({
      required FileEnumerator fileEnumerator,
      required MemoryFileSystem fs,
    }) =>
        GrepTool(
          processRunner: _noRgRunner(),
          fileEnumerator: fileEnumerator,
          fs: fs,
        );

    test('finds matches across files with line numbers', () async {
      final fe = MemoryFileEnumerator({
        '/repo': ['a.dart', 'b.txt', 'sub/c.dart'],
      });
      final fs = MemoryFileSystem({
        '/repo/a.dart': 'class Foo {}\nfinal x = 1;\nclass Bar extends Foo {}\n',
        '/repo/b.txt': 'foo\nFoo\nbar\n',
        '/repo/sub/c.dart': 'class Baz {}\n',
      })
        ..directories.add('/repo')
        ..directories.add('/repo/sub');
      final res = await fallbackTool(fileEnumerator: fe, fs: fs)
          .execute({'pattern': 'class ', 'path': '/repo'});
      expect(res.isError, isFalse);
      expect(res.content, contains('a.dart:1:class Foo {}'));
      expect(res.content, contains('a.dart:3:class Bar extends Foo {}'));
      expect(res.content, contains('sub/c.dart:1:class Baz {}'));
    });

    test('glob filter restricts which files are searched', () async {
      final fe = MemoryFileEnumerator({'/repo': ['a.dart', 'b.txt']});
      final fs = MemoryFileSystem({
        '/repo/a.dart': 'foo\n',
        '/repo/b.txt': 'foo\n',
      })..directories.add('/repo');
      final res = await fallbackTool(fileEnumerator: fe, fs: fs).execute({
        'pattern': 'foo',
        'path': '/repo',
        'glob': '*.txt',
      });
      expect(res.content, contains('b.txt'));
      expect(res.content, isNot(contains('a.dart')));
    });

    test('caseInsensitive controls matching', () async {
      final fe = MemoryFileEnumerator({'/repo': ['b.txt']});
      final fs = MemoryFileSystem({'/repo/b.txt': 'foo\nFoo\nbar\n'})
        ..directories.add('/repo');
      final res = await fallbackTool(fileEnumerator: fe, fs: fs).execute({
        'pattern': 'Foo',
        'path': '/repo',
        'glob': '*.txt',
      });
      // Case-sensitive on "Foo" against "foo\nFoo\nbar" → just line 2.
      expect(res.content, contains('b.txt:2:Foo'));
      expect(res.content, isNot(contains('b.txt:1:foo')));
    });

    test('maxResults caps output with a marker', () async {
      final fe = MemoryFileEnumerator({'/repo': ['a.txt']});
      final content = List.generate(5, (i) => 'match$i').join('\n');
      final fs = MemoryFileSystem({'/repo/a.txt': content})
        ..directories.add('/repo');
      final res = await fallbackTool(fileEnumerator: fe, fs: fs).execute({
        'pattern': 'match',
        'path': '/repo',
        'maxResults': 2,
      });
      expect(res.content, contains('cap of 2 reached'));
    });

    test('cancelSignal aborts the walk before any match is emitted', () async {
      // A blocking enumerator: enumerate() doesn't resolve until [gate]
      // completes, so the cancel signal is observed before the for-loop runs.
      final gate = Completer<void>();
      final fe = _BlockingEnumerator(
        gate.future,
        const ['/repo/a.txt', '/repo/b.txt'],
      );
      final fs = MemoryFileSystem({
        '/repo/a.txt': 'match\n',
        '/repo/b.txt': 'match\n',
      })..directories.add('/repo');

      final cancel = Completer<void>();
      final future = fallbackTool(fileEnumerator: fe, fs: fs).execute(
        {'pattern': 'match', 'path': '/repo'},
        cancelSignal: cancel.future,
      );
      cancel.complete();
      gate.complete();
      final res = await future;
      expect(res.content, isNot(contains('a.txt')));
      expect(res.content, isNot(contains('b.txt')));
    });

    test('truncates an over-long match line', () async {
      final fe = MemoryFileEnumerator({'/repo': ['a.txt']});
      final fs = MemoryFileSystem({
        '/repo/a.txt': '${'a' * 5000}\n',
      })..directories.add('/repo');
      final res = await fallbackTool(fileEnumerator: fe, fs: fs)
          .execute({'pattern': 'a', 'path': '/repo'});
      expect(res.isError, isFalse);
      expect(res.content, contains('[line truncated]'));
      final matchLine =
          res.content.split('\n').firstWhere((l) => l.startsWith('a.txt:'));
      expect(matchLine.length, lessThanOrEqualTo(1000 + '… [line truncated]'.length));
      expect(matchLine.startsWith('a.txt:1:'), isTrue); // prefix intact
    });

    test('invalid regex yields a humanized error', () async {
      final fe = MemoryFileEnumerator({'/repo': const []});
      final fs = MemoryFileSystem()..directories.add('/repo');
      final res = await fallbackTool(fileEnumerator: fe, fs: fs)
          .execute({'pattern': '(unclosed', 'path': '/repo'});
      expect(res.isError, isTrue);
      expect(res.content, contains('invalid regex'));
    });
  });

  group('GrepTool validation', () {
    test('rejects an empty pattern', () async {
      final res = await GrepTool().execute({'pattern': ''});
      expect(res.isError, isTrue);
      expect(res.content, contains('pattern is required'));
    });

    test('rejects a missing path', () async {
      final res = await GrepTool()
          .execute({'pattern': 'x', 'path': '/no/such/dir-tina-grep'});
      expect(res.isError, isTrue);
      expect(res.content, contains('path does not exist'));
    });
  });
}

/// A [FileEnumerator] whose [enumerate] awaits [gate] before returning [files],
/// so a test can race cancellation against enumeration.
class _BlockingEnumerator implements FileEnumerator {
  final Future<void> gate;
  final List<String> files;
  _BlockingEnumerator(this.gate, this.files);

  @override
  Future<List<String>> enumerate(String root) async {
    await gate;
    return files;
  }
}
