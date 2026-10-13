import 'package:test/test.dart';
import 'package:tina/session.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

void main() {
  test('terminal notices reach independent connection attachments', () async {
    final terminal = SessionTerminal();
    addTearDown(terminal.closeInput);
    final host = Host.start(
      HostConfig(
        workingDirectory: '.',
        providerFactory: (_) => ScriptedProvider([]),
        notices: terminal.notices,
      ),
    );
    addTearDown(host.shutdown);
    final connection = host.connect();
    addTearDown(connection.close);
    final first = connection.attach(), second = connection.attach();
    terminal.writeln('one');
    final update = await first.next();
    expect(
      first.notices(snapshot: update!.snapshot).entries.single.text,
      'one',
    );
    first.close();
    terminal.writeln('two');
    final latest = connection.attach().initial;
    expect(second.notices(snapshot: latest).entries.map((n) => n.text), [
      'one',
      'two',
    ]);
    expect(await first.next(), isNull);
  });

  test('legacy asks use identified requests, answered out of order', () async {
    final terminal = SessionTerminal();
    final client = terminal.questions.connect();
    addTearDown(terminal.closeInput);
    addTearDown(client.close);
    final first = terminal.ask('first?'), second = terminal.ask('second?');
    final pending = client.pending;
    expect(pending.map((q) => q.prompt), ['first?', 'second?']);
    expect(
      terminal.notices.retained,
      isEmpty,
      reason:
          'questions have their own channel and are not replayed as notices',
    );
    expect(client.answer(pending.last.id, 'two'), isTrue);
    expect(client.answer(pending.first.id, 'one'), isTrue);
    expect(await first, 'one');
    expect(await second, 'two');
    expect(client.answer(pending.first.id, 'stale'), isFalse);
  });

  test(
    'shutdown settles pending and future legacy asks without an answer',
    () async {
      final terminal = SessionTerminal();
      final first = terminal.ask('first?'), second = terminal.ask('second?');
      terminal.closeInput();
      terminal.closeInput();
      expect(await first, '');
      expect(await second, '');
      expect(await terminal.ask('closed?'), '');
    },
  );

  test('headless legacy asks return without waiting for input', () async {
    final terminal = SessionTerminal(
      questions: SessionQuestions(interactive: false),
    );
    addTearDown(terminal.closeInput);
    expect(await terminal.ask('unattended?'), '');
  });
}
