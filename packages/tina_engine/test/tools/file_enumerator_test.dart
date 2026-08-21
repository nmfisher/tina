import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/memory_file_enumerator.dart';
import '../helpers/memory_process_runner.dart';

void main() {
  group('fileGlobMatch', () {
    test('* matches within a single segment', () {
      expect(fileGlobMatch('*.dart', 'foo.dart'), isTrue);
      expect(fileGlobMatch('*.dart', 'dir/foo.dart'), isFalse);
    });

    test('? matches exactly one non-slash char', () {
      expect(fileGlobMatch('foo?', 'fooa'), isTrue);
      expect(fileGlobMatch('foo?', 'foo'), isFalse);
      expect(fileGlobMatch('foo?', 'foo/a'), isFalse);
    });

    test('** alone matches any chars including slashes', () {
      expect(fileGlobMatch('lib/**', 'lib/a'), isTrue);
      expect(fileGlobMatch('lib/**', 'lib/a/b/c.dart'), isTrue);
      expect(fileGlobMatch('lib/**', 'src/a'), isFalse);
    });

    test('**/ matches zero or more dir components', () {
      expect(fileGlobMatch('**/*.dart', 'foo.dart'), isTrue);
      expect(fileGlobMatch('**/*.dart', 'dir/foo.dart'), isTrue);
      expect(fileGlobMatch('**/*.dart', 'a/b/foo.dart'), isTrue);
    });

    test('lib/**/*.dart matches direct and nested files', () {
      expect(fileGlobMatch('lib/**/*.dart', 'lib/foo.dart'), isTrue);
      expect(fileGlobMatch('lib/**/*.dart', 'lib/sub/foo.dart'), isTrue);
      expect(fileGlobMatch('lib/**/*.dart', 'src/foo.dart'), isFalse);
    });

    test('regex metachars in pattern are escaped, not interpreted', () {
      expect(fileGlobMatch('foo.bar', 'foo.bar'), isTrue);
      expect(fileGlobMatch('foo.bar', 'fooXbar'), isFalse);
    });
  });

  group('MemoryFileEnumerator', () {
    test('returns the seeded list for a known root, empty for unknown', () async {
      final e = MemoryFileEnumerator({'/r': ['a.dart', 'b.txt']});
      expect(await e.enumerate('/r'), ['a.dart', 'b.txt']);
      expect(await e.enumerate('/other'), isEmpty);
    });

    test('.always returns the same list for any root', () async {
      final e = MemoryFileEnumerator.always(['x.dart']);
      expect(await e.enumerate('/anything'), ['x.dart']);
    });
  });

  group('RepoFileEnumerator', () {
    test('returns git ls-files output when git exits 0', () async {
      final runner = MemoryProcessRunner.always(MemoryRunningProcess(
        stdoutChunks: ['lib/a.dart\n', 'test/b.dart\n'],
        exitCodeValue: 0,
      ));
      final e = RepoFileEnumerator(
          processRunner: runner, fallback: MemoryFileEnumerator({}));
      expect(await e.enumerate('/repo'), ['lib/a.dart', 'test/b.dart']);
      expect(runner.runs.single.executable, 'git');
      expect(runner.runs.single.arguments,
          ['ls-files', '--cached', '--others', '--exclude-standard']);
    });

    test('git succeeding with no files returns empty (does NOT fall back)',
        () async {
      final runner = MemoryProcessRunner.always(
          MemoryRunningProcess(exitCodeValue: 0)); // empty stdout
      final fallback = MemoryFileEnumerator({'/repo': ['should-not-appear']});
      final e = RepoFileEnumerator(processRunner: runner, fallback: fallback);
      expect(await e.enumerate('/repo'), isEmpty);
    });

    test('falls back to walk when git exits non-zero', () async {
      final runner = MemoryProcessRunner.always(
          MemoryRunningProcess(exitCodeValue: 128));
      final fallback = MemoryFileEnumerator({'/repo': ['walked.dart']});
      final e = RepoFileEnumerator(processRunner: runner, fallback: fallback);
      expect(await e.enumerate('/repo'), ['walked.dart']);
    });

    test('falls back to walk when git is unavailable (throws)', () async {
      final runner = MemoryProcessRunner(
          (_, __) => throw Exception('git not found'));
      final fallback = MemoryFileEnumerator({'/repo': ['walked.dart']});
      final e = RepoFileEnumerator(processRunner: runner, fallback: fallback);
      expect(await e.enumerate('/repo'), ['walked.dart']);
    });

    test('file root with git unavailable returns the file, no git run',
        () async {
      final tmp = Directory.systemTemp.createTempSync('tina_walk_');
      try {
        final file = File('${tmp.path}/only.dart')..writeAsStringSync('');
        final runner = MemoryProcessRunner(
            (_, __) => throw Exception('git not found'));
        final e = RepoFileEnumerator(
            processRunner: runner, fallback: const WalkFileEnumerator());
        expect(await e.enumerate(file.path), ['only.dart']);
        expect(runner.runs, isEmpty);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });

  group('WalkFileEnumerator', () {
    test('walks the tree and skips well-known build dirs', () async {
      final tmp = Directory.systemTemp.createTempSync('tina_walk_');
      try {
        File('${tmp.path}/a.dart').writeAsStringSync('');
        Directory('${tmp.path}/node_modules').createSync();
        File('${tmp.path}/node_modules/dep.js').writeAsStringSync('');
        Directory('${tmp.path}/sub').createSync();
        File('${tmp.path}/sub/b.dart').writeAsStringSync('');

        final files = await WalkFileEnumerator().enumerate(tmp.path);
        expect(files, containsAll(['a.dart', 'sub/b.dart']));
        expect(files, isNot(contains('node_modules/dep.js')));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('file root returns just that file, no exception or warning',
        () async {
      final tmp = Directory.systemTemp.createTempSync('tina_walk_');
      try {
        final file = File('${tmp.path}/single.dart')..writeAsStringSync('');
        final files = await WalkFileEnumerator().enumerate(file.path);
        expect(files, ['single.dart']);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}
