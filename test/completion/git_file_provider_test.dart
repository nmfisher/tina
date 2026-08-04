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
  });
}
