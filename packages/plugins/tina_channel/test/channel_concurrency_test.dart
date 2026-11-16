import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_channel/tina_channel_sqlite.dart';

/// Phase 2's core property, rescope-prescribed: two REAL dart
/// processes open one SESSION's chat database — a main agent and a
/// subagent share the room — interleave writes, and each reads the
/// other's messages: no corruption, no lost writes. The writers are
/// [concurrency_writer.dart] subprocesses, not mocks; the test process
/// only sets the stage and audits the log afterwards.
void main() {
  late Directory dir;
  late String db;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tina_channel_conc');
    db = '${dir.path}/channel.db';
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // WAL sidecars can linger briefly; not a failure.
    }
  });

  test('two processes interleave writes and both see each other',
      () async {
    const count = 25;
    final packageRoot = Directory.current.path;
    Future<Process> start(String mine, String other) => Process.start(
        Platform.resolvedExecutable,
        ['run', 'test/concurrency_writer.dart', db, mine, other, '$count'],
        workingDirectory: packageRoot);

    // Started together: their inserts interleave through WAL.
    Future<(int, String, String)> run(String mine, String other) async {
      final process = await start(mine, other);
      final out = process.stdout.transform(systemEncoding.decoder).join();
      final err = process.stderr.transform(systemEncoding.decoder).join();
      final code = await process.exitCode;
      return (code, await out, await err);
    }

    final results =
        await Future.wait([run('agent-a', 'agent-b'), run('agent-b', 'agent-a')]);

    for (final (code, out, err) in results) {
      expect(code, 0, reason: 'writer failed:\n$out$err');
      expect(out, contains('SUMMARY'));
      expect(out, contains('sawOther='));
    }

    // Audit the shared log through a third connection.
    final store = SqliteChannelStore.open(db);
    addTearDown(store.close);
    final messages = store.read('#stress', limit: 200);
    expect(messages.length, 2 * count + 2); // posts + two join announces

    // Every row survived, attributed: 25 messages + 1 status each.
    for (final name in ['agent-a', 'agent-b']) {
      expect(messages.where((m) => m.sender == name && m.type == ChannelMessageType.message).length, count);
      expect(
          messages.where((m) => m.sender == name && m.type == ChannelMessageType.status).length, 1);
    }

    // Rowids are unique and strictly increasing in read order — no
    // corruption, no duplicated inserts.
    final ids = messages.map((m) => m.id).toList();
    expect(ids.toSet().length, ids.length);
    for (var i = 1; i < ids.length; i++) {
      expect(ids[i], greaterThan(ids[i - 1]));
    }

    // Presence rows from both processes coexist.
    final members = store.members('#stress').map((m) => m.name).toList();
    expect(members, containsAll(['agent-a', 'agent-b']));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
