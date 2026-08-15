import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:tina_index/walker.dart';

String get repoRoot => p.normalize(p.join(Directory.current.path, '..', '..'));

void main() {
  group('DartFileWalker', () {
    test('finds .dart files in tina repo', () async {
      final walker = DartFileWalker(repoRoot: repoRoot);
      final files = await walker.walk();
      expect(files, isNotEmpty);
      expect(files, contains('lib/config.dart'));
      expect(files, contains('lib/session.dart'));
      expect(files.every((f) => f.endsWith('.dart')), isTrue);
    });

    test('excludes .dart_tool and build directories', () async {
      final walker = DartFileWalker(repoRoot: repoRoot);
      final files = await walker.walk();
      expect(files, isNot(anyElement(contains('.dart_tool'))));
      expect(files, isNot(anyElement(contains('build/'))));
    });

    // Regression: git C-quotes non-ASCII paths by default
    // ("na\303\257ve_cache.dart"), which used to make such files fail the
    // .dart filter and silently vanish from the index. Self-contained
    // against a temp git repo so it doesn't depend on this repo's layout.
    test('git listing keeps non-ASCII filenames verbatim', () async {
      final git = await Process.run('git', ['--version']);
      if (git.exitCode != 0) {
        markTestSkipped('git not available');
        return;
      }
      final tmp = await Directory.systemTemp.createTemp('walker_unicode_');
      addTearDown(() => tmp.delete(recursive: true));
      final src = Directory(p.join(tmp.path, 'lib', 'src'))..createSync(recursive: true);
      // Decomposed (NFD) form — what macOS filesystems actually store.
      final name = 'naïve_cache.dart';
      File(p.join(src.path, name)).writeAsStringSync('class NaiveCache {}\n');

      for (final args in [
        ['init', '-q'],
        ['config', 'user.email', 'test@test'],
        ['config', 'user.name', 'test'],
        ['add', '-A'],
        ['commit', '-qm', 'fixture'],
      ]) {
        final res = await Process.run('git', args, workingDirectory: tmp.path);
        expect(res.exitCode, 0, reason: 'git ${args.first} failed: ${res.stderr}');
      }

      final walker = DartFileWalker(repoRoot: tmp.path);
      final files = await walker.walk();
      expect(files, contains('lib/src/$name'));
    });
  });
}
