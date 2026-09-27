// The TUI session wrapper: the assembly's wiring with the TUI terminal
// in the slot. A scripted provider drives a full turn; the dispatch
// refuses an unknown /word through the terminal, never as a turn; /quit
// flags the loop to stop; /mode flips the assembly's mode service — the
// mode enum never appears in this package's logic.
//
// Run: dart test
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tools/tina_tools.dart'
    show ModeCommandPlugin, ModeControl;
import 'package:tina_tui/tina_tui.dart';

void main() {
  late Directory ws;
  late TuiSession tui;
  setUp(() async {
    ws = await Directory.systemTemp.createTemp('tina_tui_session_');
    tui = TuiSession.start(
      providerFactory: (_) => ScriptedProvider([scriptedReply('echo reply')]),
      workingDirectory: ws.path,
    );
  });
  tearDown(() {
    tui.close();
    ws.deleteSync(recursive: true);
  });

  test('a full turn through the assembly\u2019s host, echoed to the terminal',
      () async {
    await tui.runLine('hello');
    expect(tui.host.session.lastReply, 'echo reply');
    expect(tui.terminal.lines.map((l) => l.text).join("\n"), contains('echo reply'));
    expect(tui.host.session.loop.log.length, greaterThanOrEqualTo(3),
        reason: 'input, response, stop — the same log a headless run keeps');
  });

  test('an unknown /word is refused through the terminal, no turn', () async {
    await tui.runLine('/frobnicate');
    expect(tui.terminal.lines.map((l) => l.text).join("\n"), contains('unknown command: /frobnicate'));
    expect(tui.host.session.loop.log, isEmpty,
        reason: 'the refusal is not a turn');
  });

  test('/quit flags the loop to stop', () async {
    expect(await tui.runLine('/quit'), isTrue);
    expect(tui.assembly.quitRequested, isTrue);
  });

  test('an empty line is no turn and no output', () async {
    final before = tui.host.session.loop.log.length;
    await tui.runLine('   ');
    expect(tui.host.session.loop.log.length, before);
    expect(tui.terminal.lines.map((l) => l.text).join("\n"), isEmpty);
  });

  test('/mode flips the assembly\u2019s mode service by word', () async {
    await tui.runLine('/mode read-only');
    expect(
        ModeCommandPlugin.wordFor(tui.services.get<ModeControl>().mode),
        'read-only');
    expect(tui.terminal.lines.map((l) => l.text).join("\n"), contains('mode: read-only'));
    // And back, by the same word.
    await tui.runLine('/mode normal');
    expect(ModeCommandPlugin.wordFor(tui.services.get<ModeControl>().mode),
        'normal');
  });

  test('a handed-in terminal is used; a default one is built otherwise',
      () {
    final handed = TuiTerminal();
    final t = TuiSession.start(
      providerFactory: (_) => ScriptedProvider(const []),
      workingDirectory: ws.path,
      terminal: handed,
    );
    expect(t.terminal, same(handed));
    t.close();

    final fresh = TuiSession.start(
      providerFactory: (_) => ScriptedProvider(const []),
      workingDirectory: ws.path,
    );
    expect(fresh.terminal, isNot(same(handed)));
    fresh.close();
  });
}
