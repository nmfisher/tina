// Live check (phase 4): fill a channel through the real CLI surface
// (in-process runCli, exactly what the tests drive), compact it, show
// reads return digest + recent only while the database retains the
// full history; then --clear. Transcript for the ticket.
import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:tina/tina.dart';
import 'package:tina_channel/tina_channel_sqlite.dart';

Future<void> main() async {
  final workspace = Directory.systemTemp.createTempSync('tina-phase4-live-');
  Directory('${workspace.path}/.tina/channels').createSync(recursive: true);
  final db = '${workspace.path}/.tina/channels/live.db';
  Future<int> cli(List<String> args) =>
      runCli(['channel', ...args, '--db', db, '--cwd', workspace.path]);

  print('== fill #work with 30 messages via the CLI');
  for (var i = 1; i <= 30; i++) {
    final code = await cli(['say', '#work', 'message $i', '--as', 'nick']);
    if (code != 0) throw StateError('say failed ($code)');
  }

  print('== tina channel compact #work --keep 10');
  print('exit=${await cli(['compact', '#work', '--keep', '10'])}');

  final store = SqliteChannelStore.open(db);
  final view = store.read('#work', limit: 100);
  print('== view: ${view.length} rows '
      '(want 11: 10 kept + digest); point=${store.compactionPoint('#work')}');
  print('   digest: ${view.last.text}');
  print('   first kept: ${view.first.text}; last kept: '
      '${view[view.length - 2].text}');

  final raw = sqlite3.sqlite3.open(db);
  final rows = raw
      .select('SELECT COUNT(*) AS n FROM messages WHERE channel = ?', ['#work'])
      .single['n'] as int;
  print('== database rows: $rows (want 31 — the audit log kept everything)');

  print('== --clear');
  print('exit=${await cli(['compact', '#work', '--clear'])}');
  print('== view after clear: '
      '${store.read('#work', limit: 10).length} rows (want 0)');
  await cli(['say', '#work', 'room continues', '--as', 'nick']);
  print('== post-clear life: ${store.read('#work').single.text}');

  store.close();
  raw.close();
  workspace.deleteSync(recursive: true);
}
