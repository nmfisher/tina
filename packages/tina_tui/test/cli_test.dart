import 'dart:io';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:test/test.dart';
import 'package:tina_tui/tina_tui.dart';

void main() {
  test('legacy import CLI is offline, dry-run is read-only, and output resumes',
      () async {
    final dir = Directory.systemTemp.createTempSync('tina-import-cli-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final source = File('${dir.path}/old.jsonl')
      ..writeAsStringSync(
          '{"role":"user","content":[{"type":"text","text":"hello"}]}\n');
    final target = '${dir.path}/new/store.db';
    final args = [
      '--cwd',
      dir.path,
      '--store',
      target,
      '--import-sessions',
      source.path
    ];
    expect(await runCli([...args, '--dry-run']), 0);
    expect(Directory('${dir.path}/new').existsSync(), false);
    expect(await runCli(args), 0);
    expect(await runCli(args), 0);
    final store = SessionStore.open(target);
    expect(store.list().single.id, 'legacy:old:old');
    store.close();
    expect(await runCli([...args, '--resume', 'x']), 64);
    expect(await runCli(['--dry-run']), 64);
  });
  test('informational flags need neither config nor a provider', () async {
    expect(await runCli(['--help']), 0);
    expect(await runCli(['--version'], version: '1.2.3'), 0);
    for (final shell in ['bash', 'zsh', 'fish']) {
      expect(shellCompletion(shell), contains('tina')); // shell-specific script
    }
  });
  test('incomplete, unknown and conflicting CLI flags fail before startup',
      () async {
    expect(await runCli(['--config']), 64);
    expect(await runCli(['--unknown']), 64);
    expect(await runCli(['--sessions', '--resume', 'id']), 64);
    expect(await runCli(['--completion', 'unsupported']), 64);
  });
  test(
      'missing config in a pipe gives setup instructions without creating a store',
      () async {
    final dir = Directory.systemTemp.createTempSync('tina-cli-');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(await runCli(['--config', '${dir.path}/config', '--cwd', dir.path]),
        78);
    expect(dir.listSync(), isEmpty);
  });
}
