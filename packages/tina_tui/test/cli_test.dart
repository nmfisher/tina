import 'dart:io';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:test/test.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:tina_tui/src/session_selection.dart';
import 'package:tina_core/tina_core.dart';

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
    expect(await runCli(['--no-sandbox', '--help']), 0);
    expect(await runCli(['--version'], version: '1.2.3'), 0);
    for (final shell in ['bash', 'zsh', 'fish']) {
      expect(shellCompletion(shell), contains('tina')); // shell-specific script
      expect(shellCompletion(shell), contains('no-sandbox'));
    }
  });
  test('incomplete, unknown and conflicting CLI flags fail before startup',
      () async {
    expect(await runCli(['--config']), 64);
    expect(await runCli(['--backend']), 64);
    expect(await runCli(['--backend', 'unknown']), 64);
    expect(await runCli(['--backend', 'notcurses', '--help']), 0);
    expect(await runCli(['--unknown']), 64);
    expect(await runCli(['--sessions', '--resume', 'id']), 64);
    expect(await runCli(['--continue', '--resume']), 64);
    expect(await runCli(['-c', '--configure']), 64);
    expect(await runCli(['--resume', '--import-sessions', 'x']), 64);
    expect(await runCli(['--completion', 'unsupported']), 64);
  });
  test('resume and continue do not create absent history', () async {
    final dir = Directory.systemTemp.createTempSync('tina-resume-cli-');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final flag in ['--resume', '--continue', '-c']) {
      expect(await runCli([flag, '--cwd', dir.path]), 66);
      expect(dir.listSync(), isEmpty);
    }
    final path = '${dir.path}/empty.db';
    SessionStore.open(path).close();
    expect(await runCli(['--resume', '--store', path]), 66);
    expect(await runCli(['--continue', '--store', path]), 66);
  });
  test('session selection orders by latest append and excludes children', () {
    final dir = Directory.systemTemp.createTempSync('tina-resume-order-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/sessions.db';
    final store = SessionStore.open(path);
    store.createSession('older');
    store.createSession('newer');
    store.append('older', [
      InputRecordedEntry(turnId: 't', text: 'resumed', at: 'now').withSeq(0)
    ]);
    store.createSession('child', details: SessionDetails(depth: 1));
    store.close();
    expect(resumableSessions(path).map((s) => s.id), ['older', 'newer']);
    final reopened = SessionStore.open(path);
    reopened.updateDetails('newer', SessionDetails(tokensSpent: 3));
    reopened.close();
    expect(resumableSessions(path).first.id, 'newer');
  });
  test('picker accepts a numbered choice, retries invalid input and cancels',
      () {
    final sessions = [
      StoredSession(id: 'one', registryKey: 1, entries: 2, title: 'a\x1b[2J'),
      StoredSession(id: 'two', registryKey: 4, entries: 3),
    ];
    final output = <String>[];
    final answers = ['0', '3', 'wrong', ' 2 '].iterator;
    expect(
        pickSession(sessions, readLine: () {
          answers.moveNext();
          return answers.current;
        }, writeLine: output.add),
        'two');
    expect(output.join('\n'), contains('Enter a number from 1 to 2.'));
    expect(output.join('\n'), isNot(contains('\x1b')));
    for (final answer in <String?>['', 'q', null]) {
      expect(pickSession(sessions, readLine: () => answer, writeLine: (_) {}),
          isNull);
    }
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
