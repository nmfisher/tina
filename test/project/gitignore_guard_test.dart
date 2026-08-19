import 'dart:io';

import 'package:tina/project/gitignore_guard.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tina_gitignore_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('gitRepoRootFor', () {
    test('finds the repo root from a nested directory', () async {
      final root = Directory(p.join(tmp.path, 'repo'))..createSync();
      Directory(p.join(root.path, '.git')).createSync();
      final nested =
          Directory(p.join(root.path, 'a', 'b'))..createSync(recursive: true);
      expect(gitRepoRootFor(nested.path), root.path);
    });

    test('returns null outside a git repo', () {
      expect(gitRepoRootFor(tmp.path), isNull);
    });

    test('treats a .git file (worktree) as a repo root', () async {
      final root = Directory(p.join(tmp.path, 'worktree'))..createSync();
      File(p.join(root.path, '.git')).writeAsStringSync(
          'gitdir: /elsewhere/.git/worktrees/wt');
      expect(gitRepoRootFor(root.path), root.path);
    });
  });

  group('gitignoreCoversTina', () {
    test('matches the common ignore patterns', () {
      for (final line in [
        '.tina',
        '.tina/',
        '/.tina/',
        '**/.tina',
        '**/.tina/',
        'subdir/.tina',
      ]) {
        expect(gitignoreCoversTina([line]), isTrue, reason: line);
      }
    });

    test('ignores comments, blanks, negations, and other paths', () {
      expect(gitignoreCoversTina(['# .tina', '', '!.tina', 'build/', 'tina']),
          isFalse);
    });

    test('does not match lookalikes', () {
      expect(gitignoreCoversTina(['.tinax', '.tina-sessions']), isFalse);
    });
  });

  group('gitignoreCoversTinaAt', () {
    test('false when no .gitignore exists', () {
      final root = Directory(p.join(tmp.path, 'repo'))..createSync();
      expect(gitignoreCoversTinaAt(root.path), isFalse);
    });

    test('reads and checks the repo .gitignore', () {
      final root = Directory(p.join(tmp.path, 'repo'))..createSync();
      File(p.join(root.path, '.gitignore')).writeAsStringSync('build/\n');
      expect(gitignoreCoversTinaAt(root.path), isFalse);
      File(p.join(root.path, '.gitignore')).writeAsStringSync('.tina/\n');
      expect(gitignoreCoversTinaAt(root.path), isTrue);
    });
  });

  group('addTinaToGitignore', () {
    test('creates a missing .gitignore', () {
      final f = File(p.join(tmp.path, '.gitignore'));
      addTinaToGitignore(f);
      expect(f.readAsStringSync(), '.tina/\n');
    });

    test('appends after a properly terminated file', () {
      final f = File(p.join(tmp.path, '.gitignore'))
        ..writeAsStringSync('build/\n');
      addTinaToGitignore(f);
      expect(f.readAsStringSync(), 'build/\n.tina/\n');
    });

    test('inserts a newline when the file lacks a trailing one', () {
      final f = File(p.join(tmp.path, '.gitignore'))..writeAsStringSync('build/');
      addTinaToGitignore(f);
      expect(f.readAsStringSync(), 'build/\n.tina/\n');
    });
  });

  group('GitignoreAskStore', () {
    test('round-trips declined repo roots', () {
      final root = Directory(p.join(tmp.path, 'repo'))..createSync();
      final store = GitignoreAskStore(
          File(p.join(tmp.path, 'gitignore_declined.json')));
      expect(store.isDeclined(root.path), isFalse);
      store.setDeclined(root.path, true);
      expect(store.isDeclined(root.path), isTrue);
      store.setDeclined(root.path, false);
      expect(store.isDeclined(root.path), isFalse);
    });

    test('a corrupt file is an empty set', () {
      final f = File(p.join(tmp.path, 'gitignore_declined.json'))
        ..writeAsStringSync('not json');
      expect(GitignoreAskStore(f).isDeclined(tmp.path), isFalse);
    });
  });
}
