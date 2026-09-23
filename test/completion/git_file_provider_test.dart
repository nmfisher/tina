import 'dart:io';

import 'package:tina/completion/git_file_provider.dart';
import 'package:test/test.dart';

/// Creates a throwaway git repo under the system temp dir, seeds it with a few
/// known files, and returns its path. The provider enumerates via
/// `git ls-files`, so the repo only needs `git init` — no commit or configured
/// identity is required (untracked files surface via `--others`). Isolating the
/// test from the host repo makes it deterministic in any clone (it previously
/// relied on `Directory.current` and tripped on extension-less files like a
/// top-level LICENSE).
String _seededRepo() {
  final dir = Directory.systemTemp.createTempSync('git_file_provider_');
  Process.runSync('git', ['init'], workingDirectory: dir.path);
  File('${dir.path}/README.md').writeAsStringSync('# readme\n');
  Directory('${dir.path}/src').createSync();
  File('${dir.path}/src/main.dart').writeAsStringSync('// main\n');
  File('${dir.path}/src/util.dart').writeAsStringSync('// util\n');
  File('${dir.path}/pubspec.yaml').writeAsStringSync('name: fixt\n');
  return dir.path;
}

void main() {
  late String repo;
  setUp(() => repo = _seededRepo());
  tearDown(() => Directory(repo).deleteSync(recursive: true));

  group('GitFileCompletionProvider', () {
    test('prewarm populates cache from git repo', () async {
      final provider = GitFileCompletionProvider(workingDir: repo);
      await provider.prewarm();

      final results = await provider.complete('');
      expect(results, isNotEmpty);
      // All results should be file paths (contain / or end in an extension).
      expect(results.every((r) => r.contains('.') || r.contains('/')), isTrue);
    });

    test('prewarm calls onFile with increasing counts', () async {
      final provider = GitFileCompletionProvider(workingDir: repo);
      final counts = <int>[];
      await provider.prewarm(onFile: counts.add);

      expect(counts, isNotEmpty);
      // Counts should be strictly increasing: 1, 2, 3, ...
      for (var i = 1; i < counts.length; i++) {
        expect(counts[i], greaterThan(counts[i - 1]));
      }
    });

    test('prewarm is a no-op when cache exists', () async {
      final provider = GitFileCompletionProvider(workingDir: repo);
      await provider.prewarm();
      final firstResults = await provider.complete('');

      var called = false;
      await provider.prewarm(onFile: (_) => called = true);
      expect(called, isFalse);

      final secondResults = await provider.complete('');
      expect(secondResults, equals(firstResults));
    });

    test('stale cache re-runs the listing (moved files show up)', () async {
      var now = DateTime(2026, 1, 1, 12);
      final provider =
          GitFileCompletionProvider(workingDir: repo, clock: () => now);
      final first = await provider.complete('');
      expect(first, contains('README.md'));

      // Move a file after the first listing.
      Directory('${repo}/moved').createSync();
      File('${repo}/src/util.dart').renameSync('${repo}/moved/util.dart');

      // Within the TTL: still the old tree.
      now = now.add(const Duration(seconds: 1));
      final cached = await provider.complete('');
      expect(cached, contains('src/util.dart'));
      expect(cached, isNot(contains('moved/util.dart')));

      // Past the TTL: the picker sees the current tree.
      now = now.add(const Duration(seconds: 4));
      final fresh = await provider.complete('');
      expect(fresh, isNot(contains('src/util.dart')));
      expect(fresh, contains('moved/util.dart'));
    });

    test('concurrent queries share one re-enumeration', () async {
      var now = DateTime(2026, 1, 1, 12);
      final provider =
          GitFileCompletionProvider(workingDir: repo, clock: () => now);
      await provider.complete('');

      // Two keystrokes firing while a re-enumeration is in flight both get
      // the new listing, not a second concurrent git run.
      now = now.add(const Duration(seconds: 5));
      final a = provider.complete('');
      now = now.add(const Duration(seconds: 5));
      final b = provider.complete('');
      final results = await Future.wait([a, b]);
      expect(results[0], results[1]);
      expect(results[0], contains('src/util.dart'));
    });
  });
}
