import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_rewind/tina_rewind.dart';

final class _Terminal implements Terminal {
  final lines = <String>[];
  @override
  void writeln([String? line]) => lines.add(line ?? '');
  @override
  Future<String> ask(String prompt) async => '';
}

void main() {
  test('rewind points list user turns and compaction boundaries', () async {
    final loop = AgentLoop(
      provider: ScriptedProvider([
        scriptedReply('a1'),
        scriptedReply('a2'),
        scriptedReply('a3'),
      ]),
      plugins: [],
    );
    await loop.runTurn(const Input('first', id: 't1'));
    await loop.runTurn(const Input('second', id: 't2'));
    await loop.runTurn(const Input('third message', id: 't3'));
    loop.compact(0, 1, '[earlier conversation summarized]\nfirst and a1');

    final points = enumerateRewindPoints(loop.log);
    expect(points.map((p) => p.kind).toList(), [
      'user',
      'user',
      'user',
      'compaction',
    ]);
    expect(points.map((p) => p.toSeq).toList(), [0, 5, 10, 15]);
    expect(points.map((p) => p.label).toList(), [
      'first',
      'second',
      'third message',
      '[earlier conversation summarized] first and a1',
    ]);
    expect(rewindHeadOf(loop.log), 15);
  });

  test('labels flatten whitespace and clip at ~80 characters', () {
    final points = enumerateRewindPoints([
      const TurnStartedEntry(turnId: 't1').withSeq(0),
      const InputRecordedEntry(turnId: 't1', text: 'a\n  b   c').withSeq(1),
      const TurnEndedEntry(
        turnId: 't1',
        reason: TurnStopReason.complete,
      ).withSeq(2),
    ]);
    expect(points.single.label, 'a b c');
  });

  test('/rewind 2 takes back the last two user messages', () async {
    final terminal = _Terminal();
    final plugin = RewindPlugin(terminal: terminal);
    final loop = AgentLoop(
      provider: ScriptedProvider([
        scriptedReply('a1'),
        scriptedReply('a2'),
        scriptedReply('a3'),
      ]),
      plugins: [plugin],
    );
    plugin.mountOn(loop);
    await loop.runTurn(const Input('first', id: 't1'));
    await loop.runTurn(const Input('second', id: 't2'));
    await loop.runTurn(const Input('third message', id: 't3'));

    final rewind = plugin.commands.firstWhere(
      (command) => command.name == 'rewind',
    );
    await rewind.handler('2');

    // Turn 2 and 3 never happened: the derive is turn 1 alone.
    final view = loop.derive();
    expect(
      view.messages.map((m) => (m.content.single as TextBlock).text).toList(),
      ['first', 'a1'],
    );
    // The scope notice names the filesystem limit.
    expect(
      terminal.lines.last,
      contains('Filesystem effects of earlier tool calls are not undone'),
    );
    // Rewound-away turns are no longer offered as points.
    expect(enumerateRewindPoints(loop.log).map((p) => p.label).toList(), [
      'first',
    ]);
    expect(rewindHeadOf(loop.log), 4);
    plugin.closeSession();
  });

  test(
    '/rewind with no argument lists the points and the current position',
    () async {
      final terminal = _Terminal();
      final plugin = RewindPlugin(terminal: terminal);
      final loop = AgentLoop(
        provider: ScriptedProvider([scriptedReply('a1'), scriptedReply('a2')]),
        plugins: [plugin],
      );
      plugin.mountOn(loop);
      await loop.runTurn(const Input('first', id: 't1'));
      await loop.runTurn(const Input('second', id: 't2'));

      final rewind = plugin.commands.firstWhere(
        (command) => command.name == 'rewind',
      );
      await rewind.handler('');

      expect(terminal.lines.first, contains('current position: after entry 9'));
      expect(terminal.lines.join('\n'), contains('first'));
      expect(terminal.lines.join('\n'), contains('second'));
      expect(loop.log.whereType<RewoundEntry>(), isEmpty);
      plugin.closeSession();
    },
  );

  test('rewindTo refuses a stale head and out-of-range positions', () async {
    final terminal = _Terminal();
    final plugin = RewindPlugin(terminal: terminal);
    final loop = AgentLoop(
      provider: ScriptedProvider([scriptedReply('a1')]),
      plugins: [plugin],
    );
    plugin.mountOn(loop);
    await loop.runTurn(const Input('first', id: 't1'));

    expect(
      () => plugin.rewindTo(toSeq: 0, expectedHead: 3),
      throwsStateError,
    ); // conversation moved
    plugin.rewindTo(toSeq: 0, expectedHead: rewindHeadOf(loop.log));
    expect(loop.derive().messages, isEmpty);
    plugin.closeSession();
  });
}
