// Persistence through the assembly: a store path persists, a session id
// resumes, and listSessions lists what the store holds. The scripted
// provider plays the model; a temp store file holds the entries. (Was
// tina_cli's shell_store_test; the shell read-loop is gone, the assembly
// it fed is here.)
//
// Run: dart test
library;

import 'package:tina_persistence/tina_persistence.dart';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

/// A captured writer: every line the assembly said, joined.
final class CapturedWriter implements AssemblyWriter {
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
    ws = await Directory.systemTemp.createTemp('tina_tui_store_');
    dbPath = '${ws.path}/sessions.db';
  });
  tearDown(() {
    ws.deleteSync(recursive: true);
  });

  test('a stored session round-trips: send, close, list, resume, continue',
      () async {
    // --- session one: one turn, then the assembly closes the link.
    final writer1 = CapturedWriter();
    final provider1 = ScriptedProvider([scriptedReply('first answer')]);
    final assembly1 = TuiAssembly.start(
      writer: writer1,
      providerFactory: (_) => provider1,
      options: AssemblyOptions(
        configPath: '/nonexistent/tina/config',
        workingDirectory: ws.path,
        storePath: dbPath,
      ),
    );
    await assembly1.host.send('first question');
    expect(provider1.callCount, 1);
    final firstLog = assembly1.host.session.loop.log;
    expect(firstLog.whereType<TurnEndedEntry>().single.reason,
        TurnStopReason.complete);
    assembly1.host.close();

    // --- list: the store shows the one session.
    final listWriter = CapturedWriter();
    listSessions(writer: listWriter, storePath: dbPath);
    expect(listWriter.lines.single, contains('entries'));

    // --- session two: resume, the history is the seeded context.
    final writer2 = CapturedWriter();
    final provider2 = ScriptedProvider([scriptedReply('second answer')]);
    final assembly2 = TuiAssembly.start(
      writer: writer2,
      providerFactory: (_) => provider2,
      options: AssemblyOptions(
        configPath: '/nonexistent/tina/config',
        workingDirectory: ws.path,
        storePath: dbPath,
        sessionId: assembly1.host.session.id,
      ),
    );
    // The greet line reports the resume.
    expect(writer2.text, isNot(contains('resumed')),
        reason: 'greet runs later; nothing printed at start');

    expect(
      assembly2.host.session.loop.log.length,
      firstLog.length,
      reason: 'the loop was seeded from the store',
    );
    await assembly2.host.send('second question');
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
    final all = store.readEntries(assembly1.host.session.id);
    expect(store.checkGaps(assembly1.host.session.id), isEmpty);
    for (var i = 0; i < all.length; i++) {
      expect(all[i].seq, i, reason: 'row $i');
    }
    expect(
      jsonEncode([for (final e in all.take(firstLog.length)) e.toJson()]),
      jsonEncode([for (final e in firstLog) e.toJson()]),
    );
    expect(all.length, greaterThan(firstLog.length));
    store.close();
    assembly2.host.close();
  });

  test('the assembly reports a resumed session through configNote and the log',
      () async {
    final w1 = CapturedWriter();
    final assembly1 = TuiAssembly.start(
      writer: w1,
      providerFactory: (_) => ScriptedProvider([scriptedReply('a')]),
      options: AssemblyOptions(
        configPath: '/nonexistent/tina/config',
        workingDirectory: ws.path,
        storePath: dbPath,
      ),
    );
    await assembly1.host.send('q');
    assembly1.host.close();

    final w2 = CapturedWriter();
    final assembly2 = TuiAssembly.start(
      writer: w2,
      providerFactory: (_) => ScriptedProvider([scriptedReply('b')]),
      options: AssemblyOptions(
        configPath: '/nonexistent/tina/config',
        workingDirectory: ws.path,
        storePath: dbPath,
        sessionId: assembly1.host.session.id,
      ),
    );
    // Nothing prints at start — a full-screen front end owns its own
    // banner. The resume is visible as the seeded log the front end
    // renders, never as a line the assembly wrote.
    expect(w2.text, isEmpty,
        reason: 'the assembly prints nothing on its own');
    expect(assembly2.host.session.loop.log.length,
        assembly1.host.session.loop.log.length,
        reason: 'the loop was seeded from the store');
    assembly2.host.close();
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
