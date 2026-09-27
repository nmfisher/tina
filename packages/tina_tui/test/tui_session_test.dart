// The TUI session: the shell's assembly, the TUI's terminal in the slot.
// A plugin-registered command is found and dispatched with no TUI code
// naming it; the mode command flips the boundary's mode; a turn runs
// through the host and its lines land in the conversation.
//
// Run: dart test
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_services/tina_services.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:tina_tui/tina_tui.dart';

/// A provider that plays one scripted turn: echoes the input as the
/// reply. Records what it was asked, so tests can assert the turn ran.
class _EchoProvider implements LlmProvider {
  final List<Request> requests = [];
  @override
  String get model => 'scripted';
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    requests.add(Request(
        systemPrompt: system,
        messages: List.of(messages),
        tools: List.of(tools)));
    yield const TextDelta('echo');
    yield const MessageComplete(
        content: [TextBlock('echo')], stopReason: 'end_turn');
  }

  @override
  void close() {}
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tina_tui_session_');
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  TuiSession session(ProviderFactory factory, {TuiTerminal? terminal}) =>
      TuiSession.start(
        providerFactory: factory,
        workingDirectory: tmp.path,
        terminal: terminal,
      );

  test('the locator holds the TUI terminal before anything reads it', () {
    final tui = TuiTerminal();
    final s = session((model) => _EchoProvider(), terminal: tui);
    expect(identical(s.services.get<Terminal>(), tui), isTrue);
    expect(s.services.get<Commands>(), isNotNull);
    expect(identical(s.terminal, tui), isTrue);
    s.close();
  });

  test('a command registered by a plugin is published, listed, dispatched',
      () {
    final s = session((model) => _EchoProvider());
    // `/mode` exists because ModeCommandPlugin published it — no TUI
    // source names it; the list is whatever the registry holds.
    expect(s.commands['mode'], isNotNull);
    expect(commandListRows(s.commands).join('\n'), contains('/mode — '));
    // Dispatch through the pure decision; the handler runs.
    final d = dispatchLine(s.commands, '/mode') as RunCommand;
    d.run();
    expect(s.terminal.lines.last.text, 'mode: normal');
    s.close();
  });

  test('the mode command flips the boundary the same way it does anywhere',
      () {
    final s = session((model) => _EchoProvider());
    (dispatchLine(s.commands, '/mode read-only') as RunCommand)
        .run(); // handlers run through the decision
    final control = s.services.get<ModeControl>();
    expect(control.mode, PermissionMode.readOnly);
    expect(s.terminal.lines.last.text, 'mode: read-only');
    s.close();
  });

  test('an unknown /word is reported through the terminal, never a turn',
      () async {
    final s = session((model) => _EchoProvider());
    await s.runLine('/definitely-not-a-command');
    expect(s.terminal.lines.last.text,
        'unknown command: /definitely-not-a-command');
    expect(s.host.session.turns, isEmpty, reason: 'no turn was run');
    s.close();
  });

  test('a plain line runs one host turn; the reply lands in the view',
      () async {
    final s = session((model) => _EchoProvider());
    await s.runLine('hello tina');
    expect(s.host.session.turns, hasLength(1));
    expect(s.terminal.lines.any((l) => l.text == 'echo'), isTrue,
        reason: 'the reply is in the conversation');
    // The user's words are the input the loop recorded.
    final inputs = s.host.session.loop.log
        .whereType<InputRecordedEntry>()
        .toList(growable: false);
    expect(inputs.single.text, 'hello tina');
    s.close();
  });

  test('an empty line runs nothing at all', () async {
    final s = session((model) => _EchoProvider());
    await s.runLine('   ');
    expect(s.host.session.turns, isEmpty);
    expect(s.terminal.lines, isEmpty);
    s.close();
  });

  test('close resolves a pending ask with the empty answer', () async {
    final s = session((model) => _EchoProvider());
    final pending = s.terminal.ask('still there?');
    s.close();
    expect(await pending, '');
  });
}
