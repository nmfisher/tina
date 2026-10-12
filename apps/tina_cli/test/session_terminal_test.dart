import 'package:test/test.dart';
import 'package:tina/session.dart';
import 'package:tina_host/tina_host.dart';

void main() {
  test(
    'terminal records notices and notifies independently disposable listeners',
    () {
      final terminal = SessionTerminal();
      addTearDown(terminal.closeInput);
      final lines = <String>[];
      final detach = terminal.listenLines(lines.add);
      terminal.writeln('one');
      detach();
      terminal.writeln('two');
      expect(lines, ['one']);
      expect(terminal.lines.map((line) => line.text), ['one', 'two']);
    },
  );

  test('legacy asks use identified requests, answered out of order', () async {
    final terminal = SessionTerminal();
    final client = terminal.questions.connect();
    addTearDown(terminal.closeInput);
    addTearDown(client.close);
    final first = terminal.ask('first?'), second = terminal.ask('second?');
    final pending = client.pending;
    expect(pending.map((q) => q.prompt), ['first?', 'second?']);
    expect(terminal.lines.map((line) => line.text), ['first?', 'second?']);
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
