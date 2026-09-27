// Persistence through the shell: --store persists, --resume seeds, and
// --sessions lists what the store holds. The scripted provider plays the
// model; a temp store file holds the entries.
//
// Run: dart test
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_cli/tina_cli.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

/// A captured writer: every line the shell said, joined.
final class CapturedWriter implements ShellWriter {
  final StringBuffer buf = StringBuffer();

  @override
  void writeln([String? line]) => buf.writeln(line ?? '');

  String get text => buf.toString();

  List<String> get lines =>
      const LineSplitter().convert(text.trimRight());
}

void main() {
  late Directory ws;
  late String dbPath;
  setUp(() async {
    ws = await Directory.systemTemp.createTemp('tina_cli_store_');
    dbPath = '${ws.path}/sessions.db';
  });
  tearDown(() {
    ws.deleteSync(recursive: true);
  });

  test('a stored session round-trips: send, close, list, resume, continue',
      () async {
    // --- session one: one turn, then the shell closes the link.
    final writer1 = CapturedWriter();
    final provider1 = ScriptedProvider([scriptedReply('first answer')]);
    final shell1 = Shell.start(
      writer: writer1,
      providerFactory: (_) => provider1,
      options: ShellOptions(
        configPath: '/nonexistent/tina/config',
        workingDirectory: ws.path,
        storePath: dbPath,
      ),
    );
    expect(await shell1.handle('first question'), isTrue);
    expect(provider1.callCount, 1);
    final firstLog = shell1.host.session.loop.log;
    expect(firstLog.whereType<TurnEndedEntry>().single.reason,
        TurnStopReason.complete);
    shell1.host.close();

    // --- list: the store shows the one session.
    final listWriter = CapturedWriter();
    listSessions(writer: listWriter, storePath: dbPath);
    expect(listWriter.lines.single, contains('entries'));

    // --- session two: resume, the history is the seeded context.
    final writer2 = CapturedWriter();
    final provider2 = ScriptedProvider([scriptedReply('second answer')]);
    final shell2 = Shell.start(
      writer: writer2,
      providerFactory: (_) => provider2,
      options: ShellOptions(
        configPath: '/nonexistent/tina/config',
        workingDirectory: ws.path,
        storePath: dbPath,
        sessionId: shell1.host.session.id,
      ),
    );
    // The greet line reports the resume.
    expect(writer2.text, isNot(contains('resumed')),
        reason: 'greet runs later; nothing printed at start');

    expect(
      shell2.host.session.loop.log.length,
      firstLog.length,
      reason: 'the loop was seeded from the store',
    );
    await shell2.handle('second question');
    expect(provider2.callCount, 1);
    // The request carried the whole derived conversation.
    final request = provider2.requests.single;
    expect(request.messages.length, 3);
    expect((request.messages[0].content.single as TextBlock).text,
        'first question');
    expect((request.messages[1].content.single as TextBlock).text,
        'first answer');
    expect((request.messages[2].content.single as TextBlock).text,
        'second question');

    // The store now holds both turns, gapless, old entries untouched.
    final store = SessionStore.open(dbPath);
    final all = store.readEntries(shell1.host.session.id);
    expect(store.checkGaps(shell1.host.session.id), isEmpty);
    for (var i = 0; i < all.length; i++) {
      expect(all[i].seq, i, reason: 'row $i');
    }
    expect(
      jsonEncode([for (final e in all.take(firstLog.length)) e.toJson()]),
      jsonEncode([for (final e in firstLog) e.toJson()]),
    );
    expect(all.length, greaterThan(firstLog.length));
    store.close();
    shell2.host.close();
  });

  test('greet reports the resume', () async {
    final w1 = CapturedWriter();
    final shell1 = Shell.start(
      writer: w1,
      providerFactory: (_) => ScriptedProvider([scriptedReply('a')]),
      options: ShellOptions(
        configPath: '/nonexistent/tina/config',
        workingDirectory: ws.path,
        storePath: dbPath,
      ),
    );
    await shell1.handle('q');
    shell1.host.close();

    final w2 = CapturedWriter();
    final shell2 = Shell.start(
      writer: w2,
      providerFactory: (_) => ScriptedProvider([scriptedReply('b')]),
      options: ShellOptions(
        configPath: '/nonexistent/tina/config',
        workingDirectory: ws.path,
        storePath: dbPath,
        sessionId: shell1.host.session.id,
      ),
    );
    shell2.greet();
    expect(
        w2.lines.any((l) => l.contains('resumed:') && l.contains('log entries')),
        isTrue,
        reason: w2.text);
    shell2.host.close();
  });

  test('listSessions on an empty store says so', () {
    SessionStore.open(dbPath).close();
    final w = CapturedWriter();
    listSessions(writer: w, storePath: dbPath);
    expect(w.lines.single, contains('no sessions'));
  });

  test('listSessions on a missing store throws (the entry point reports it)',
      () {
    expect(() => listSessions(
        writer: CapturedWriter(), storePath: '${ws.path}/nope.db'),
        throwsA(isA<SessionStoreException>()));
  });
}
