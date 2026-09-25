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
      final provider = GitFileCompletionProvider(
        workingDir: repo,
        clock: () => now,
      );
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

    test(
      'non-git workspace: walk fallback lists files and TTL refreshes it',
      () async {
        // A plain directory with no .git — git ls-files fails, the provider
        // falls back to a filesystem walk.
        final dir = Directory.systemTemp.createTempSync('git_file_nogit_');
        try {
          File('${dir.path}/notes.txt').writeAsStringSync('x');
          Directory('${dir.path}/docs').createSync();
          File('${dir.path}/docs/readme.md').writeAsStringSync('x');

          var now = DateTime(2026, 1, 1, 12);
          final provider = GitFileCompletionProvider(
            workingDir: dir.path,
            clock: () => now,
          );
          final first = await provider.complete('');
          expect(first, containsAll(['notes.txt', 'docs/readme.md']));

          // Move something; within TTL nothing changes.
          File(
            '${dir.path}/notes.txt',
          ).renameSync('${dir.path}/docs/notes.txt');
          now = now.add(const Duration(seconds: 1));
          final cached = await provider.complete('');
          expect(cached, contains('notes.txt'));

          // Past TTL the walk re-runs and sees the move.
          now = now.add(const Duration(seconds: 4));
          final fresh = await provider.complete('');
          expect(fresh, isNot(contains('notes.txt')));
          expect(fresh, contains('docs/notes.txt'));
        } finally {
          dir.deleteSync(recursive: true);
        }
      },
    );

    test(
      'non-git workspace: walk skips well-known build directories',
      () async {
        final dir = Directory.systemTemp.createTempSync('git_file_nogit_');
        try {
          File('${dir.path}/app.dart').writeAsStringSync('x');
          Directory('${dir.path}/node_modules').createSync();
          File('${dir.path}/node_modules/pkg.js').writeAsStringSync('x');
          Directory('${dir.path}/build').createSync();
          File('${dir.path}/build/out.js').writeAsStringSync('x');

          final provider = GitFileCompletionProvider(workingDir: dir.path);
          final files = await provider.complete('');
          expect(files, contains('app.dart'));
          expect(files, isNot(contains('node_modules/pkg.js')));
          expect(files, isNot(contains('build/out.js')));
        } finally {
          dir.deleteSync(recursive: true);
        }
      },
    );

    test('concurrent queries share one re-enumeration', () async {
      var now = DateTime(2026, 1, 1, 12);
      final provider = GitFileCompletionProvider(
        workingDir: repo,
        clock: () => now,
      );
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

    test('empty query page spreads across top-level directories', () async {
      // Reproduces the bare-`@` bug: raw git order groups by directory, so a
      // repo whose first tracked entries are hundreds of dotfiles served a
      // page of nothing but dotfiles. One file per top-level dir per round
      // keeps every directory reachable within the first 50.
      final dir = Directory.systemTemp.createTempSync('git_file_spread_');
      Process.runSync('git', ['init'], workingDirectory: dir.path);
      try {
        for (var i = 0; i < 120; i++) {
          File('${dir.path}/.tickets/tin-$i.md')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('x');
        }
        for (final top in ['lib', 'packages', 'docs']) {
          File('${dir.path}/$top/file.dart')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('x');
        }
        File('${dir.path}/README.md').writeAsStringSync('x');

        final provider = GitFileCompletionProvider(workingDir: dir.path);
        final page = await provider.complete('');

        expect(page.length, provider.maxResults);
        final tops = page
            .map((f) => f.contains('/') ? f.split('/').first : '')
            .toSet();
        expect(tops, containsAll(['.tickets', 'lib', 'packages', 'docs', '']));
        // Source dirs outrank the dot-dir, so the first .tickets entry lands
        // after every seeded source file (docs, lib, packages in alpha order).
        final libPos = page.indexOf('lib/file.dart');
        expect(libPos, inInclusiveRange(0, 2));
        expect(
          page.indexWhere((f) => f.startsWith('.tickets/')),
          greaterThan(libPos),
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('deep files are reachable via the empty-query page', () async {
      // Nested paths bucket under their top-level dir, so a page slot is
      // shared by the whole subtree — 51 files under one top-level dir would
      // otherwise swallow a slot without showing anything deep.
      final dir = Directory.systemTemp.createTempSync('git_file_deep_');
      Process.runSync('git', ['init'], workingDirectory: dir.path);
      try {
        for (var i = 0; i < 51; i++) {
          File('${dir.path}/pkg/sub/leaf$i.dart')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('x');
        }
        File('${dir.path}/src/root.dart')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('x');

        final provider = GitFileCompletionProvider(workingDir: dir.path);
        final page = await provider.complete('');
        // Both buckets take a slot in round 0, so pkg fills 49 of the 50
        // page slots and 2 of its 51 files are cut. Which leaves are cut
        // depends on enumeration order, so only the count is asserted.
        expect(page, contains('src/root.dart'));
        final pkgOnPage = page.where((f) => f.startsWith('pkg/')).toSet();
        expect(pkgOnPage.length, provider.maxResults - 1);
        final allLeaves = {for (var i = 0; i < 51; i++) 'pkg/sub/leaf$i.dart'};
        expect(allLeaves.difference(pkgOnPage).length, 2);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('filtered query still searches the full tree', () async {
      // Ordering only applies to the empty-query page; a fuzzy query must
      // rank every file regardless of which directory it lives in.
      final dir = Directory.systemTemp.createTempSync('git_file_filter_');
      Process.runSync('git', ['init'], workingDirectory: dir.path);
      try {
        for (var i = 0; i < 120; i++) {
          File('${dir.path}/.tickets/tin-$i.md')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('x');
        }
        File('${dir.path}/lib/zzz_unique_target.dart')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('x');

        final provider = GitFileCompletionProvider(workingDir: dir.path);
        final hits = await provider.complete('unique_target');
        expect(hits, contains('lib/zzz_unique_target.dart'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}
