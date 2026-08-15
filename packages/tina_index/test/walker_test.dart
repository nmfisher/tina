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
    // .dart filter and silently vanish from the index — and git on macOS
    // precomposes to NFC by default (core.precomposeunicode), which loses
    // the on-disk byte form. The walker disables both. Self-contained
    // against a temp git repo so it doesn't depend on this repo's layout.
    //
    // A filename in either Unicode normalization form must survive the
    // walk byte-exact (the walker configures precomposeunicode=false, so
    // git returns whatever form is stored) AND stay usable: the returned
    // relative path must resolve to a real file. NFC normalization in
    // the walker would pass the membership check on APFS but break opens
    // on normalization-sensitive filesystems like exFAT.
    for (final entry in {
      // Explicit escapes so the two forms don't depend on how this
      // source file happens to be encoded.
      'NFC (single codepoint)': 'na\u00efve_cache.dart',
      'NFD (i + combining diaeresis)': 'nai\u0308ve_cache.dart',
    }.entries) {
      test('round-trips ${entry.key} filenames', () async {
        final git = await Process.run('git', ['--version']);
        if (git.exitCode != 0) {
          markTestSkipped('git not available');
          return;
        }
        final name = entry.value;
        final tmp = await Directory.systemTemp.createTemp('walker_norm_');
        addTearDown(() => tmp.delete(recursive: true));
        final src = Directory(p.join(tmp.path, 'lib', 'src'))
          ..createSync(recursive: true);
        File(p.join(src.path, name)).writeAsStringSync('class NaiveCache {}\n');

        for (final args in [
          ['init', '-q'],
          ['config', 'user.email', 'test@test'],
          ['config', 'user.name', 'test'],
          ['add', '-A'],
          ['commit', '-qm', 'fixture'],
        ]) {
          final res =
              await Process.run('git', args, workingDirectory: tmp.path);
          expect(res.exitCode, 0,
              reason: 'git ${args.first} failed: ${res.stderr}');
        }

        final walker = DartFileWalker(repoRoot: tmp.path);
        final files = await walker.walk();
        final expected = 'lib/src/$name';
        expect(files, contains(expected),
            reason: 'expected byte-exact $expected, got $files');
        for (final rel in files) {
          final abs = p.join(tmp.path, rel);
          expect(File(abs).existsSync(), isTrue,
              reason: 'walked path does not resolve to a file: $rel');
        }
      });
    }
  });
}
