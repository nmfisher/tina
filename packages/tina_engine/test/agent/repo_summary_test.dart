import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('repoSummaryBlock', () {
    late Directory repo;

    setUp(() {
      repo = Directory.systemTemp.createTempSync('tina_reposummary_');
      Process.runSync('git', ['-C', repo.path, 'init', '-b', 'main']);
      Process.runSync(
          'git', ['-C', repo.path, 'config', 'user.email', 't@t.dev']);
      Process.runSync('git', ['-C', repo.path, 'config', 'user.name', 'T']);
    });

    tearDown(() {
      repo.deleteSync(recursive: true);
    });

    void commit(String name, String message) {
      File('${repo.path}/$name').writeAsStringSync('content of $name');
      Process.runSync('git', ['-C', repo.path, 'add', '.']);
      Process.runSync(
          'git', ['-C', repo.path, 'commit', '-m', message]);
    }

    test('null for a non-repo directory', () {
      final plain = Directory.systemTemp.createTempSync('tina_reposummary_no_');
      addTearDown(() => plain.deleteSync(recursive: true));
      expect(repoSummaryBlock(plain.path), isNull);
    });

    test('degrades gracefully for a repo with no commits', () {
      final block = repoSummaryBlock(repo.path);
      expect(block, isNotNull);
      expect(block, contains('no commits yet'));
      expect(block, contains('branch: main'));
    });

    test('carries branch, HEAD, status, recent commits, and the tree',
        () async {
      for (var i = 1; i <= 6; i++) {
        commit('f$i.txt', 'commit $i');
      }
      Directory('${repo.path}/lib/src')..createSync(recursive: true);
      File('${repo.path}/lib/src/a.dart').writeAsStringSync('class A {}');
      Directory('${repo.path}/.git/objects').createSync(recursive: true);
      File('${repo.path}/dirty.txt').writeAsStringSync('uncommitted');
      final block = repoSummaryBlock(repo.path)!;

      expect(block, startsWith('<repo>'));
      expect(block, contains('branch: main @'));
      expect(block, contains('(commit 6)'));
      // 5-commit cap: the sixth-oldest subject drops out.
      expect(block, contains('commit 5'));
      expect(block, isNot(contains('commit 1)')));
      expect(block, contains('status:'));
      expect(block, contains('tree:'));
      expect(block, contains('lib/'));
      expect(block, contains('</repo>'));
    });

    test('clean worktree omits the status line', () {
      commit('a.txt', 'only commit');
      final block = repoSummaryBlock(repo.path)!;
      expect(block, isNot(contains('status:')));
    });

    test('the tree skips dot dirs and build output', () {
      Directory('${repo.path}/build/sub').createSync(recursive: true);
      Directory('${repo.path}/lib').createSync();
      File('${repo.path}/build/x.txt').writeAsStringSync('');
      File('${repo.path}/lib/a.dart').writeAsStringSync('');
      commit('a.txt', 'init');
      final block = repoSummaryBlock(repo.path)!;
      expect(block, contains('lib/'));
      expect(block, isNot(contains('build/')));
    });

    test('marks package directories', () {
      Directory('${repo.path}/packages/thing').createSync(recursive: true);
      File('${repo.path}/packages/thing/pubspec.yaml').writeAsStringSync('name: thing');
      commit('a.txt', 'init');
      final block = repoSummaryBlock(repo.path)!;
      // The pubspec.yaml itself is the directory's one direct file.
      expect(block, contains('packages/thing/  (1 file [package])'));
    });
  });
}
