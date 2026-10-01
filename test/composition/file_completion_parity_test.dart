// Frontend migration parity: compare the legacy and engine2 completion sources.
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina/completion/git_file_provider.dart';
import 'package:tina_tui/tina_tui.dart';

void main() {
  test(
    'engine2 retains the full legacy search domain in a large repository',
    () async {
      final repo = Directory.systemTemp.createTempSync(
        'tina-completion-parity-',
      );
      addTearDown(() => repo.deleteSync(recursive: true));
      expect(
        Process.runSync('git', ['init'], workingDirectory: repo.path).exitCode,
        0,
      );
      final deep = '${List.filled(12, 'nested').join('/')}/final_target.dart';
      final files = [
        for (var i = 0; i < 450; i++) '.tickets/ticket-$i.md',
        'lib/main.dart',
        'packages/code.dart',
        'docs/readme.md',
        'README.md',
        'LICENSE',
        deep,
        '.gitignore',
      ];
      for (final name in [...files, 'ignored.txt']) {
        File('${repo.path}/$name')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('x');
      }
      File('${repo.path}/.gitignore').writeAsStringSync('ignored.txt\n');
      final legacy = GitFileCompletionProvider(
        workingDir: repo.path,
        maxResults: 10000,
      );
      final current = GitFileCompletionSource(workingDir: repo.path);
      expect(
        (await current.complete('')).toSet(),
        (await legacy.complete('')).toSet(),
      );
      expect((await current.complete('')).toSet(), files.toSet());
      for (final query in [
        'final_target',
        'main',
        'code',
        'ticket-449',
        'README',
        'LICENSE',
      ]) {
        expect(
          (await current.complete(query)).toSet(),
          (await legacy.complete(query)).toSet(),
          reason: 'legacy/new parity for $query',
        );
      }
    },
  );
}
